# Fertigkeiten und Statuseffekte aus der Editor-Datenbank (skill.sql.2013_11_7, MySQL-Dump "skilldev"
# der v260-Server-Quellen) -> Server/skill_templates.json und Server/state_templates.json
# Aufruf: python3 skill_templates.py <skill.sql.2013_11_7> <Ausgabe-Ordner Server/>
# Der Dump enthält die Tabellen, aus denen wskill/gen (Generator.java, SkillStub.java, StateFilter.java)
# den C++-Code der Skill-Bibliothek erzeugt hat. Werte sind Formeln (Text, siehe game/server/skill_expr.gd),
# verschachtelte Felder Java-Serialisierung (AttackWay, ProcedureVO, SkillStateParam, StateEffect).
# Zuordnung wie der Generator:
#   talentN -> tN-1 (GetTalentN), Prozeduren -> State1.. (GetTime = continuetime, Calculate = computeResult,
#   BreakProb = asynchronousTerminate, StopProb = bypassCondition, Cancel = kequxiao, Quit = quitCondition),
#   stateparam 1-4 / 9-14 -> Ziel (StateAttack), 5-8 / 15-20 -> selbst (BlessMe); data[j] -> j-te Wirkung
#   des Effekts (Effekte ohne Wirkungsart werden übersprungen wie RegisterStub), timeparam ms, succeedparam %.
#   Radius je approach (GetRadius), Angriffsweite (GetAttackdistance) wie SkillStub.java.
import sys, os, re, json, struct

SELF_SLOTS = set(range(5, 9)) | set(range(15, 21))
# Rollen mit lernbaren Klassenfertigkeiten (Tabelle role: 1-16 Rasse/Klasse) und 48 allgemein (120 Stadtportal)
ROLES = set(range(1, 17)) | {48}

ESC = {ord('0'): b'\0', ord('n'): b'\n', ord('r'): b'\r', ord('t'): b'\t', ord('Z'): b'\x1a', ord('b'): b'\b'}


def table(dump, name):
	"""Spaltennamen und Zeilen (Text als bytes, Zahlen / NULL als str / None) einer Tabelle."""
	i = dump.find(b"CREATE TABLE `%s`" % name.encode())
	j = dump.find(b"PRIMARY KEY", i)
	cols = [c.decode() for c in re.findall(rb"^\s+`(\w+)`", dump[i:j], re.M)]
	rows = []
	pat = b"INSERT INTO `%s` VALUES " % name.encode()
	pos = 0
	other = re.compile(rb"[^,)]*")
	while True:
		i = dump.find(pat, pos)
		if i < 0:
			break
		p = i + len(pat)
		while True:
			p += 1  # (
			row = []
			while True:
				if dump[p] == 0x27:
					p += 1
					buf = bytearray()
					while True:
						ch = dump[p]
						if ch == 0x5c:
							buf += ESC.get(dump[p + 1], bytes([dump[p + 1]]))
							p += 2
						elif ch == 0x27:
							p += 1
							break
						else:
							buf.append(ch)
							p += 1
					row.append(bytes(buf))
				else:
					m = other.match(dump, p)
					p = m.end()
					v = m.group(0).decode()
					row.append(None if v == 'NULL' else v)
				if dump[p] == 0x2c:
					p += 1
					continue
				p += 1  # )
				break
			rows.append(dict(zip(cols, row)))
			if dump[p] == 0x2c:
				p += 1
				continue
			break
		pos = p
	return cols, rows


END = object()  # TC_ENDBLOCKDATA
BLOCK = object()  # TC_BLOCKDATA (Größe der Listen, nicht gebraucht)


class JavaReader:
	"""Java-Objektserialisierung (Stream-Protokoll 5), soweit die VOs des Editors sie nutzen."""
	def __init__(self, b):
		self.b = b
		self.p = 4
		self.handles = []

	def u1(self):
		self.p += 1
		return self.b[self.p - 1]

	def unpack(self, fmt, n):
		self.p += n
		return struct.unpack(fmt, self.b[self.p - n:self.p])[0]

	def utf(self, n):
		self.p += n
		return self.b[self.p - n:self.p].decode('utf-8', 'replace')

	def content(self):
		tc = self.u1()
		if tc == 0x70:  # TC_NULL
			return None
		if tc == 0x71:  # TC_REFERENCE
			return self.handles[self.unpack('>i', 4) - 0x7e0000]
		if tc == 0x74:  # TC_STRING
			v = self.utf(self.unpack('>H', 2))
			self.handles.append(v)
			return v
		if tc == 0x7c:  # TC_LONGSTRING
			v = self.utf(self.unpack('>q', 8))
			self.handles.append(v)
			return v
		if tc == 0x72:  # TC_CLASSDESC
			self.p -= 1
			return self.classdesc()
		if tc == 0x73:  # TC_OBJECT
			return self.obj()
		if tc == 0x77:  # TC_BLOCKDATA
			n = self.u1()
			self.p += n
			return BLOCK
		if tc == 0x78:  # TC_ENDBLOCKDATA
			return END
		raise ValueError('Java-Typ %x an %d' % (tc, self.p))

	def classdesc(self):
		tc = self.u1()
		if tc == 0x70:
			return None
		if tc == 0x71:
			return self.handles[self.unpack('>i', 4) - 0x7e0000]
		name = self.utf(self.unpack('>H', 2))
		self.p += 8  # serialVersionUID
		h = len(self.handles)
		self.handles.append(None)
		flags = self.u1()
		fields = []
		for _ in range(self.unpack('>H', 2)):
			t = chr(self.u1())
			fn = self.utf(self.unpack('>H', 2))
			if t in 'L[':
				self.content()  # Typname
			fields.append((t, fn))
		while self.content() is not END:  # Klassen-Anmerkungen
			pass
		cd = {'name': name, 'flags': flags, 'fields': fields, 'super': self.classdesc()}
		self.handles[h] = cd
		return cd

	def obj(self):
		cd = self.classdesc()
		h = len(self.handles)
		o = {}
		self.handles.append(o)
		chain = []
		while cd:
			chain.append(cd)
			cd = cd['super']
		items = []
		for c in reversed(chain):
			for t, fn in c['fields']:
				if t in 'L[':
					o[fn] = self.content()
				elif t == 'I':
					o[fn] = self.unpack('>i', 4)
				elif t == 'J':
					o[fn] = self.unpack('>q', 8)
				elif t == 'Z':
					o[fn] = bool(self.u1())
				else:
					raise ValueError('Feldtyp ' + t)
			if c['flags'] & 0x01:  # eigenes writeObject (ArrayList / LinkedList: Größe + Elemente)
				while True:
					v = self.content()
					if v is END:
						break
					if v is not BLOCK:
						items.append(v)
		if chain and chain[0]['name'] in ('java.util.ArrayList', 'java.util.LinkedList'):
			self.handles[h] = items
			return items
		return o


def java(b):
	if not isinstance(b, bytes) or len(b) < 5 or b[:2] != b'\xac\xed':
		return None
	return JavaReader(b).content()


def text(v):
	if v is None:
		return ''
	if isinstance(v, bytes):
		return v.decode('utf-8', 'replace').strip()
	return str(v).strip()


def num(v, default=0):
	t = text(v)
	try:
		return int(t)
	except ValueError:
		try:
			return float(t)
		except ValueError:
			return default


def bits(s):
	"""Bitfolge des Editors (Zeichen 0 = Bit 0) -> Zahl (Helper.bin2num(reverseString(s)))."""
	s = text(s)
	return int(s[::-1], 2) if s and set(s) <= {'0', '1'} else 0


def skill_entry(s, roles):
	aw = java(s['attackway']) or {}
	approach = num(aw.get('approach'), -1)
	radius = text(aw.get('radious01'))
	if approach in (1, 6):
		radius = text(aw.get('radious00'))
	elif approach in (4, 7, 13):
		radius = text(aw.get('radious02'))
	attack_dist = text(aw.get('attackdistance01'))
	if approach == 9:
		attack_dist = text(aw.get('radious01'))
	elif approach == 13:
		attack_dist = text(aw.get('radious00'))
	procs = []
	for p in java(s['skillprocedure']) or []:
		if not text(p.get('name')):
			continue
		procs.append({'time': text(p.get('continuetime')), 'calc': text(p.get('computeResult')),
			'break': text(p.get('asynchronousTerminate')), 'stop': text(p.get('bypassCondition')),
			'cancel': text(p.get('kequxiao')), 'quit': text(p.get('quitCondition'))})
	actions = {}
	last = None
	for i, a in enumerate(java(s['actions']) or []):
		a = text(a)
		if a != last:
			actions[str(i)] = a
			last = a
	talents = {}
	for i in range(1, 17):
		t = text(s.get('talent%d' % i))
		if t:
			talents['t%d' % (i - 1)] = t
	states = []
	for i in range(1, 21):
		sp = java(s.get('stateparam%d' % i))
		if not sp or text(sp.get('stateid')) in ('', '-1'):
			continue
		data = [text(d) for d in sp.get('data') or []]
		while data and not data[-1]:
			data.pop()
		states.append({'slot': i, 'self': i in SELF_SLOTS, 'id': num(sp.get('stateid')), 'data': data,
			'time': text(sp.get('timeparam')), 'chance': text(sp.get('succeedparam')), 'type': num(sp.get('typeid'))})
	role = roles.get(num(s['roleid']), {})
	e = {'id': num(s['id']), 'role': num(s['roleid']), 'race': role.get('race', 0), 'class': role.get('class', 0),
		'name': text(s['name']), 'icon': text(s['icon']),
		'type': num(s['kindstatus'], 1), 'use': num(s['kinduse'], 1), 'from': num(s['kindfrom']), 'show': num(s['kindshow']),
		'time_type': num(s['kindtime'], 1), 'bar': num(s['timeshow'], 1), 'extra': num(s['extraflag']),
		'move_mode': num(s['movemode']), 'autoattack': num(s['autoattack']), 'passive_event': num(s['passiveeffect']),
		'max_level': num(s['maxlevel'], 10), 'max_learn': num(s['maxlearn'], 1),
		'require_level': [num(x) for x in text(s['requirelevel']).split(',') if x.strip()],
		'occupation_level': [num(x) for x in text(s['occupationlevel']).split(',') if x.strip()],
		'cost_money': text(s['costmoney']), 'pre_skill': num(s['preconditionskill']), 'pre_level': num(s['basesp']),
		'learn_from': num(s['kindfromplus']),
		'mp': text(s['mpcost']), 'exe_time': text(s['exetime']), 'cast_dist': text(s['castdistance']),
		'pray_min': text(s['minpraydistance']), 'pray_max': text(s['maxpraydistance']), 'cool': text(s['cooltime']),
		'hate': text(s['hatedegree']), 'mp_reduce': text(s['mpreducetype']), 'other_value': text(s['othervalue']),
		'action_value': text(s['actionhelpfun']),
		'self_cond': num(s['selfcondition']), 'target': num(s['targettype']), 'other_limit': num(s['otherlimit']),
		'delay_mode': num(s['delaymode']), 'delay_time': text(s['delaytime']), 'fly_speed': text(s['flyspeed']),
		'fight_usable': text(s['fightusable']) or '1', 'dizzy_usable': text(s['dizzyusable']) or '0',
		'handfree_usable': text(s['handfreeusable']) or '1',
		'state_cond': bits(s['statecondition']), 'excl_state_cond': bits(s['exclusivestatecondition']),
		'state_effect_mask': num(s['stateeffectmask']),
		'range': {'approach': approach, 'angle': text(aw.get('angle')), 'effect_dist': text(aw.get('attackdistance00')),
			'attack_dist': attack_dist, 'kill': text(aw.get('killnum')), 'radius': radius},
		'procs': procs, 'actions': actions, 'talents': talents, 'states': states}
	return e


def state_entry(s):
	effects = []
	for eff in java(s['stateeffect']) or []:
		hp = (eff or {}).get('hitstatus') or {}
		hid = num(hp.get('id'), -1)
		if hid <= 0:
			continue
		effects.append({'hs': hid, 'param': text(hp.get('param'))})
	cond = lambda pre, n: [text(s.get('%s%d' % (pre, i))) for i in range(1, n + 1)]
	return {'id': num(s['id']), 'type': num(s['typeid']), 'name': text(s['name']), 'icon': text(s['icon']),
		'light': num(s['lighteffect'], -1),
		'bag': bits(''.join(text(s['bagtype%d' % i]) for i in range(1, 5))),
		'time_type': num(s['timetype']), 'race_mask': num(s['racemask']), 'min_level': num(s['minlevel']),
		'max_level': num(s['maxlevel']), 'occupation': num(s['occupation']),
		'cover': num(s['coverrule']), 'max_stack': num(s['times']), 'add_cond': num(s['addcondition']),
		'begin': cond('begincondition', 3), 'begin_param': cond('beginparam', 3), 'begin_max': cond('beginmax', 3),
		'end': cond('endcondition', 10), 'end_param': cond('endparam', 3),
		'prop_mask': bits(s['propmask']), 'show': num(s['showtype']),
		'offline_save': num(s['isofflinesave']), 'offline_timing': num(s['isofflinetiming']), 'version': num(s['version']),
		'effects': effects}


def main():
	src, outdir = sys.argv[1:3]
	dump = open(src, 'rb').read()
	roles = {num(r['id']): {'name': text(r['name']), 'race': num(r['race']), 'class': num(r['occupation'])}
		for r in table(dump, 'role')[1]}
	_, skill_rows = table(dump, 'skill')
	skills = [skill_entry(s, roles) for s in skill_rows if num(s['roleid']) in ROLES]
	skills.sort(key=lambda e: e['id'])
	_, state_rows = table(dump, 'state')
	states = sorted((state_entry(s) for s in state_rows), key=lambda e: e['id'])
	kinds = {}
	_, dic = table(dump, 'dictionary')
	for d in dic:
		for h in java(d['file']) or []:
			kinds[str(num(h.get('id')))] = {'name': text(h.get('execute')), 'cn': text(h.get('name')),
				'desc': text(h.get('effect')), 'value': text(h.get('data')), 'param': text(h.get('param')),
				'kind': text(h.get('type')), 'mask': text(h.get('reserved1'))}
	state_types = {str(num(r['id'])): text(r['name']) for r in table(dump, 'statetype')[1]}
	skill_roles = {str(k): v for k, v in sorted(roles.items())}
	note = ('Formeln als Text (game/server/skill_expr.gd); tN = talent(N+1); procs = Prozeduren '
		'(1 Zaubern, 2 Ausführen ...); states: slot 1-4 / 9-14 Ziel, 5-8 / 15-20 selbst (self), data[j] -> '
		'j-te Wirkung des Effekts, time ms, chance %; actions: Index (0-9 zu Fuß, 10-19 beritten) -> Aktion '
		'ab diesem Index; range.approach = Zielart (skill.h RANGE_*)')
	json.dump({'source': os.path.basename(src) + ' (Tabelle skill, Rollen %s)' % sorted(ROLES), 'note': note,
		'roles': skill_roles, 'skills': skills},
		open(os.path.join(outdir, 'skill_templates.json'), 'w'), ensure_ascii=False, separators=(',', ':'))
	json.dump({'source': os.path.basename(src) + ' (Tabellen state, statetype, dictionary)',
		'note': 'effects: hs = Wirkungsart (kinds), param = fester Parameter; Werte kommen von der Fertigkeit '
			'(states[].data); bag = Klassen-Bits (bagtype1..4) zum Bannen / Immunität',
		'kinds': kinds, 'state_types': state_types, 'states': states},
		open(os.path.join(outdir, 'state_templates.json'), 'w'), ensure_ascii=False, separators=(',', ':'))
	print(len(skills), 'Fertigkeiten,', len(states), 'Effekte,', len(kinds), 'Wirkungsarten ->', outdir)


if __name__ == '__main__':
	main()
