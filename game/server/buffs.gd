extends RefCounted

# ====================================================
# Statuseffekte (Fertigkeiten-Fahrplan F3) nach wskill StateFilter / EffectStub (statefilter.h, stateeffect.h)
# und PlayerWrapper::AddFilter / CheckFilterCondition / CheckSucceed.
# Daten: Plugin Server/state_templates.json (tools/server_data/skill_templates.py): ein Effekt hat bis zu 5
# Wirkungen (Art hs, fester Parameter param); die Werte bringt die Fertigkeit mit (skill states[].data).
# Anlegen (apply):
#   Immunität (bag & immune), Stufenbereich, Klasse (occupation-Bits), Zusatzbedingung add_cond (1 Ziel zaubert,
#   2 im Kampf, 3 nur nach Krit, 4 außerhalb des Kampfes), Rassen-Bit, Erfolgswurf < chance (-1 / -2: wie /
#   gegen den letzten Wurf derselben Figur). Zeit < 500 ms -> nichts, < 1000 -> 1000 ms; time_type 0 = sofort
#   (nur die Sofort-Wirkungen, kein Effekt bleibt), 2 = ohne Ende.
#   Liegt der Effekt schon, entscheidet die Überdeckungsregel cover (PolyPolicy / OnModify): 1 schwach (neuer
#   scheitert), 2 / 11 einzig (neuer ersetzt), 4 erster Wert größer oder gleich, 5 unabhängig (nebeneinander,
#   je Zaubernder einer), 6 stapeln (gleicher Wert: Stapel + 1 bis max_stack, Zeit neu; größerer Wert ersetzt),
#   7 Zeit zurücksetzen (wenn länger), 8 längere Gesamtzeit, 9 irgendein Wert größer, 10 Zeit addieren, sonst
#   (0, 3) längere Restzeit ersetzt.
#   Beginn: begin[0] 1 = sofort, 2 = nach begin_param[0] ms; andere Auslöser (Treffer, Zustand ...) noch nicht.
# Ende: Zeit abgelaufen, Tod (end[6] leer = OVER_DEATH), Kampf (end[4] "true" = OVER_COMBAT), Monster zurück am
#   Geburtsort, Figur verlässt die Welt (Effekte werden noch nicht gespeichert).
# Wirkungen (Werte der Arten mit "正负属性" im Editor: Parameter 0 = abziehen, EffectStub FLAG_SIGNED):
#   Werte (MODS, je Stapel): Schaden / Abwehr / Treffer / Ausweichen fest und in Promille (adjust*), Krit /
#     Krit-Schaden / Krit-Abwehr (Bruchteil -> %), Höchst-Leben / -Mana fest und in Promille, Tempo (m/s),
#     Regeneration und Heilung in Promille; mods_of(obj), with_mods(Werte, obj) für den Kampf
#   über Zeit (alle param ms, Takt je Effekt ab dem Anlegen): decHp2Death / decHp (bis 1 HP) Schaden * Stapel,
#     persistHeal, incMp, decMp * Stapel
#   sofort: heal, subHp, subHpNotDeath, addMp, subMp
#   übrige (Kontrolle stun / stop / silent / melee -> F5, genState / clearFilter ... -> F10): Effekt liegt und
#     zählt, wirkt aber noch nicht (einmal im Log)
# Meldungen: buffs {id, list} an alle in Sicht des Trägers (auch an ihn selbst), list = [[Effekt, Stapel,
#   Rest ms (0 = ohne Ende), Dauer ms, Sichtbar-Index light (GFX am Modell, -1 = keiner)]]; beim Erscheinen in Sicht
#   schickt world.gd die Liste ebenso (Träger mit Effekten); hit {src, dst, dmg, buff, hp, max_hp} für Schaden über Zeit,
#   heal {src, dst, amount, buff, hp, max_hp}; stats an Spieler bei Leben / Mana / Tempo.
# ====================================================

const Proto = preload("../common/protocol.gd")
const PLUGIN_SERVER = "res://addons/PWE-Manager/Server/"
const Settings = preload("../common/settings.gd")
# Wirkungsart -> Wert in mods (Promille-Werte mit "%")
const MODS = {"modifyPhyDamage": "dmg", "adjustPhyDamage": "dmg%", "modifyPhyDefense": "def", "adjustPhyDefense": "def%",
	"modifyAttack": "hit", "adjustAttack": "hit%", "modifyArmor": "eva", "adjustArmor": "eva%", "modifyPhyCrit": "crit",
	"modifyPhyCritDmg": "crit_dmg", "modifyImpairCritRate": "anti_crit", "modifyImpairCritDmg": "anti_crit_dmg",
	"modifyMaxHp": "max_hp", "adjustHp": "max_hp%", "modifyMaxMp": "max_mp", "adjustMp": "max_mp%", "modifySpeed": "speed",
	"adjustHpgen": "hp_gen%", "adjustMpgen": "mp_gen%", "adjustHeal": "heal%"}
const TO_PERCENT = ["crit", "crit_dmg", "anti_crit", "anti_crit_dmg"] # Bruchteil -> % wie die Kampfwerte
const PERMILLE = ["dmg%", "def%", "hit%", "eva%", "max_hp%", "max_mp%", "hp_gen%", "mp_gen%", "heal%"] # Wert * 1000
const PERIODIC = ["decHp2Death", "decHp", "persistHeal", "incMp", "decMp"]
const INSTANT = ["heal", "subHp", "subHpNotDeath", "addMp", "subMp"]
const MIN_TIME = 500 # ms
const COMBAT_TIME = 10.0 # s wie combat.gd

var world # world.gd
var net
var log_line: Callable
var combat # combat.gd: Tod, Belohnung
var stats_push: Callable # (peer, p)
var states = {} # ID -> Effekt
var kinds = {} # hs -> {name, signed}
var clock: Callable # Tests: eigene Uhr (ms), sonst Time.get_ticks_msec
var _holders = {} # ID des Trägers -> [Träger, Map]
var _unsupported = {}


func _init(p_world, p_net, p_log: Callable) -> void:
	world = p_world
	net = p_net
	log_line = p_log

func load_templates() -> String:
	var path = Settings.server_data_path("state_templates.json")
	if not FileAccess.file_exists(path):
		return "Не найден файл %s" % path
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not d is Dictionary:
		return "Файл %s содержит некорректный JSON" % path
	for s in d.get("states", []):
		states[int(s["id"])] = s
	for k in d.get("kinds", {}):
		var e: Dictionary = d["kinds"][k]
		kinds[int(k)] = {"name": str(e.get("name", "")), "signed": str(e.get("param", "")).contains("正负属性")}
	return ""


# ====================================================
# ANLEGEN
# ====================================================
# Effekt state_id auf obj (Spieler oder Monster der Map map_name); values = Werte der Wirkungen, src = Zaubernder
# (Spieler-Dictionary), crit = der Treffer war kritisch -> angelegt?
func apply(obj: Dictionary, map_name: String, state_id: int, values: Array, time_ms: int, chance: int, src: Dictionary, crit: bool = false) -> bool:
	var st: Dictionary = states.get(state_id, {})
	if st.is_empty() or int(obj.get("hp", 0)) <= 0:
		return false
	var now = _now()
	var player = _is_player(obj)
	if int(obj.get("immune", 0)) & int(st["bag"]) != 0:
		return false
	var level = int(obj.get("level", 1))
	if (int(st["min_level"]) > 0 and level < int(st["min_level"])) or (int(st["max_level"]) > 0 and level > int(st["max_level"])):
		return false
	if player and int(st["occupation"]) != 0 and (int(st["occupation"]) & (1 << int(obj.get("class", 0)))) == 0:
		return false
	var fighting = _fighting(obj)
	match int(st["add_cond"]):
		1:
			if not obj.has("cast"):
				return false
		2:
			if not fighting:
				return false
		3:
			if not crit:
				return false
		4:
			if fighting:
				return false
	var race_mask = int(st["race_mask"])
	if player and race_mask != 0 and race_mask & ((1 << int(obj.get("race", 0))) | (1 << maxi(0, int(obj.get("race", 0)) - 1))) == 0:
		return false
	var ok: bool
	if chance == -1:
		ok = src.get("last_state_ok", true)
	elif chance == -2:
		ok = not src.get("last_state_ok", true)
	else:
		ok = randi() % 100 < chance
	src["last_state_ok"] = ok
	if not ok:
		return false
	var effects = []
	for j in st["effects"].size():
		var e: Dictionary = st["effects"][j]
		var kind: Dictionary = kinds.get(int(e["hs"]), {"name": "", "signed": false})
		var v = float(values[j]) if j < values.size() else 0.0
		var param = str(e["param"]).to_int()
		if kind["signed"] and param == 0:
			v = -v
		effects.append({"name": kind["name"], "hs": int(e["hs"]), "param": param, "value": v, "times": 0, "elapsed": 0})
	if effects.is_empty():
		return false
	var src_id = int(src.get("id", 0))
	var time_type = int(st["time_type"])
	if time_type != 1 and time_type != 2: # sofort: nur die Sofort-Wirkungen (OnInstant)
		if str(st["begin"][0]) != "1":
			return false
		var b = {"id": state_id, "src": src_id, "effects": effects, "map": map_name}
		for e in effects:
			if e["name"] in INSTANT:
				_instant(obj, b, e)
			else:
				_note(e)
		return true
	var t = time_ms
	if time_type == 1:
		if t < MIN_TIME:
			return false
		t = maxi(t, 1000)
	var first = absf(effects[0]["value"])
	var list: Array = obj.get("buffs", [])
	var same = list.filter(func(x): return int(x["id"]) == state_id)
	var rule = int(st["cover"])
	if rule == 5: # unabhängig: je Zaubernder einer
		for x in same:
			if int(x["src"]) == src_id:
				_remove(obj, x)
	elif not same.is_empty():
		var old: Dictionary = same[0]
		var left = int(old["end"]) - now if int(old["end"]) > 0 else 1 << 40
		match rule:
			1:
				return false
			2, 11:
				_remove(obj, old)
			4:
				if first + 0.0001 <= float(old["first"]):
					return false
				_remove(obj, old)
			6:
				if first > float(old["first"]) + 0.0001:
					_remove(obj, old)
				elif float(old["first"]) < first + 0.0001: # gleich: stapeln
					if int(st["max_stack"]) > int(old["stack"]):
						old["stack"] = int(old["stack"]) + 1
						if old["active"]:
							for e in old["effects"]:
								_take(obj, old, e)
					elif old["active"]:
						for e in old["effects"]:
							if e["name"] in INSTANT:
								_instant(obj, old, e)
					_restart(old, t, time_type, now)
					_changed(obj)
					return true
				else:
					return false
			7:
				if t <= left:
					return false
				_restart(old, t, time_type, now)
				_changed(obj)
				return true
			8:
				if t <= int(old["time"]):
					return false
				_remove(obj, old)
			9:
				var bigger = false
				for j in mini(effects.size(), old["effects"].size()):
					if float(effects[j]["value"]) - float(old["effects"][j]["value"]) > 0.0001:
						bigger = true
				if not bigger:
					return false
				_remove(obj, old)
			10:
				if int(old["end"]) > 0:
					old["end"] = int(old["end"]) + t
					old["time"] = int(old["end"]) - int(old["start"])
				_changed(obj)
				return true
			_:
				if t <= left:
					return false
				_remove(obj, old)
	var b = {"id": state_id, "src": src_id, "stack": 1, "start": now, "time": t, "end": now + t if time_type == 1 else 0,
		"next": now + 1000, "active": false, "first": first, "effects": effects, "map": map_name,
		"death_end": str(st["end"][6]) == "", "combat_end": str(st["end"][4]) == "true"}
	match str(st["begin"][0]):
		"1":
			pass
		"2":
			b["delay_until"] = now + str(st["begin_param"][0]).to_int()
		_:
			b["dormant"] = true # andere Auslöser noch nicht umgesetzt
	list.append(b)
	obj["buffs"] = list
	obj["buff_map"] = map_name
	_holders[_key(obj)] = [obj, map_name]
	if not b.has("delay_until") and not b.has("dormant"):
		_activate(obj, b)
	_changed(obj)
	return true

static func _restart(b: Dictionary, t: int, time_type: int, now: int) -> void:
	b["start"] = now
	b["time"] = t
	b["end"] = now + t if time_type == 1 else 0

func _activate(obj: Dictionary, b: Dictionary) -> void:
	b["active"] = true
	b.erase("delay_until")
	for e in b["effects"]:
		_take(obj, b, e)

# Wirkung einmal anwenden (TakeEffect)
func _take(obj: Dictionary, b: Dictionary, e: Dictionary) -> void:
	var n: String = e["name"]
	if MODS.has(n):
		e["times"] = int(e["times"]) + 1
		_recalc(obj)
	elif n in INSTANT:
		_instant(obj, b, e)
	elif not n in PERIODIC:
		_note(e)

func _note(e: Dictionary) -> void:
	var n = str(e["name"]) if str(e["name"]) != "" else "hs %d" % int(e["hs"])
	if not _unsupported.has(n):
		_unsupported[n] = true
		log_line.call("Эффекты состояний: действие %s пока не реализовано (эффект отображается, но не действует)" % n)


# ====================================================
# ENTFERNEN
# ====================================================
func _remove(obj: Dictionary, b: Dictionary) -> void:
	var list: Array = obj.get("buffs", [])
	list.erase(b)
	if b.get("active", false):
		_recalc(obj)
	if list.is_empty():
		_holders.erase(_key(obj))

# Tod: Effekte mit OVER_DEATH enden
func on_death(obj: Dictionary) -> void:
	var list: Array = obj.get("buffs", [])
	var gone = list.filter(func(b): return b.get("death_end", true))
	if gone.is_empty():
		return
	for b in gone:
		_remove(obj, b)
	_changed(obj)

# Alle Effekte weg (Monster zurück am Geburtsort)
func clear(obj: Dictionary) -> void:
	if obj.get("buffs", []).is_empty():
		return
	for b in obj["buffs"].duplicate():
		_remove(obj, b)
	_changed(obj)

# Träger verlässt die Welt / verschwindet: nur vergessen (keine Meldung)
func forget(obj: Dictionary) -> void:
	obj["buffs"] = []
	obj["buff_mod"] = {}
	_holders.erase(_key(obj))

func list_of(obj: Dictionary) -> Array:
	var now = _now()
	var out = []
	for b in obj.get("buffs", []):
		out.append([int(b["id"]), int(b["stack"]), maxi(0, int(b["end"]) - now) if int(b["end"]) > 0 else 0, int(b["time"]),
			int(states.get(int(b["id"]), {}).get("light", -1))])
	return out


# ====================================================
# TAKT (world.gd, 10 / s)
# ====================================================
func tick() -> void:
	var now = _now()
	for k in _holders.keys():
		var h = _holders.get(k)
		if h == null:
			continue
		var obj: Dictionary = h[0]
		if int(obj.get("hp", 0)) <= 0:
			continue
		var changed = false
		for b in obj.get("buffs", []).duplicate():
			if not obj["buffs"].has(b):
				continue
			if b.has("delay_until") and now >= int(b["delay_until"]):
				_activate(obj, b)
			while b["active"] and now >= int(b["next"]) and int(obj.get("hp", 0)) > 0:
				b["next"] = int(b["next"]) + 1000
				for e in b["effects"]:
					if e["name"] in PERIODIC:
						e["elapsed"] = int(e["elapsed"]) + 1
						var interval = maxi(1, int(e["param"]) / 1000)
						if int(e["elapsed"]) >= interval:
							e["elapsed"] = int(e["elapsed"]) - interval
							_periodic(obj, b, e)
			if int(obj.get("hp", 0)) <= 0:
				break
			if (int(b["end"]) > 0 and now >= int(b["end"])) or (b.get("combat_end", false) and _fighting(obj)):
				_remove(obj, b)
				changed = true
		if changed and int(obj.get("hp", 0)) > 0:
			_changed(obj)

func _periodic(obj: Dictionary, b: Dictionary, e: Dictionary) -> void:
	var v = float(e["value"])
	var stack = int(b.get("stack", 1))
	match str(e["name"]):
		"decHp2Death":
			_hurt(obj, b, int(v) * stack, true)
		"decHp":
			_hurt(obj, b, int(v) * stack, false)
		"persistHeal":
			_heal(obj, b, int(v * (1.0 + float(mods_of(obj).get("heal%", 0)) / 1000.0)))
		"incMp":
			_mana(obj, int(v))
		"decMp":
			_mana(obj, -int(v) * stack)

func _instant(obj: Dictionary, b: Dictionary, e: Dictionary) -> void:
	var v = float(e["value"])
	match str(e["name"]):
		"heal":
			_heal(obj, b, int(v * (1.0 + float(mods_of(obj).get("heal%", 0)) / 1000.0)))
		"subHp":
			_hurt(obj, b, int(v), true)
		"subHpNotDeath":
			_hurt(obj, b, int(v), false)
		"addMp":
			_mana(obj, int(v))
		"subMp":
			_mana(obj, -int(v))


# ====================================================
# WIRKEN
# ====================================================
# Schaden aus einem Effekt (BeHurt): Meldung hit mit buff, Aggro, Tod mit Belohnung für den Zaubernden
func _hurt(obj: Dictionary, b: Dictionary, amount: int, can_kill: bool) -> void:
	var hp = int(obj.get("hp", 0))
	if not can_kill:
		amount = mini(amount, hp - 1)
	if amount < 1 or hp <= 0:
		return
	obj["hp"] = maxi(0, hp - amount)
	var now = _now() / 1000.0
	var player = _is_player(obj)
	if player:
		obj["fight"] = now
	else:
		obj["last_hit"] = now
		if int(obj.get("target", 0)) == 0 and _player_by_id(int(b["src"])) != null:
			obj["target"] = int(b["src"])
			obj["fight"] = true
			obj["to"] = null
	_to_viewers(obj, b["map"], "hit", {"src": b["src"], "dst": obj["id"], "dmg": amount, "miss": false, "crit": false,
		"buff": b["id"], "hp": obj["hp"], "max_hp": obj["max_hp"]})
	if player:
		_push_stats(obj)
	if int(obj["hp"]) <= 0 and combat != null:
		if player:
			combat.player_killed(obj)
		else:
			combat.monster_killed(int(b["src"]), b["map"], obj)

func _heal(obj: Dictionary, b: Dictionary, amount: int) -> void:
	var hp = int(obj.get("hp", 0))
	if amount < 1 or hp <= 0:
		return
	obj["hp"] = mini(int(obj["max_hp"]), hp + amount)
	_to_viewers(obj, b["map"], "heal", {"src": b["src"], "dst": obj["id"], "amount": int(obj["hp"]) - hp, "buff": b["id"],
		"hp": obj["hp"], "max_hp": obj["max_hp"]})
	if _is_player(obj):
		_push_stats(obj)

func _mana(obj: Dictionary, amount: int) -> void:
	var mp = int(obj.get("mp", 0))
	obj["mp"] = clampi(mp + amount, 0, int(obj.get("max_mp", 0)))
	if obj["mp"] != mp and _is_player(obj):
		_push_stats(obj)


# ====================================================
# WERTE
# ====================================================
# Summe der Werte-Wirkungen (je Stapel), Höchst-Leben / -Mana gleich am Träger, Tempo als speed_add
func _recalc(obj: Dictionary) -> void:
	var m = {}
	for b in obj.get("buffs", []):
		if not b.get("active", false):
			continue
		for e in b["effects"]:
			var key = MODS.get(e["name"], "")
			if key == "":
				continue
			var v = float(e["value"]) * int(e["times"])
			if key in TO_PERCENT:
				v *= 100.0
			elif key in PERMILLE:
				v *= 1000.0
			m[key] = float(m.get(key, 0.0)) + v
	obj["buff_mod"] = m
	var changed = false
	for k in ["hp", "mp"]:
		var base = int(obj.get("max_" + k, 0)) - int(obj.get("buff_" + k, 0))
		var add = int(float(m.get("max_" + k, 0.0)) + base * float(m.get("max_%s%%" % k, 0.0)) / 1000.0)
		if add != int(obj.get("buff_" + k, 0)):
			obj["buff_" + k] = add
			obj["max_" + k] = maxi(1, base + add)
			obj[k] = mini(int(obj.get(k, 0)), int(obj["max_" + k]))
			changed = true
	var speed = float(m.get("speed", 0.0))
	if absf(speed - float(obj.get("speed_add", 0.0))) > 0.0001:
		obj["speed_add"] = speed
		changed = true
	if changed and _is_player(obj):
		_push_stats(obj)

static func mods_of(obj: Dictionary) -> Dictionary:
	return obj.get("buff_mod", {})

# Kampfwerte (combat.gd: dmg [min, max], def, hit, eva, crit, crit_dmg, anti_crit, anti_crit_dmg) mit den Effekten
static func with_mods(props: Dictionary, obj: Dictionary) -> Dictionary:
	var m: Dictionary = obj.get("buff_mod", {})
	if m.is_empty():
		return props
	var out = props.duplicate()
	var d: Array = props.get("dmg", [1, 1])
	var scale = 1.0 + float(m.get("dmg%", 0.0)) / 1000.0
	out["dmg"] = [maxf(0.0, (float(d[0]) + float(m.get("dmg", 0.0))) * scale), maxf(0.0, (float(d[1]) + float(m.get("dmg", 0.0))) * scale)]
	for k in ["def", "hit", "eva"]:
		out[k] = maxf(0.0, (float(props.get(k, 0)) + float(m.get(k, 0.0))) * (1.0 + float(m.get(k + "%", 0.0)) / 1000.0))
	for k in TO_PERCENT:
		out[k] = float(props.get(k, 0)) + float(m.get(k, 0.0))
	return out


# ====================================================
# HILFEN
# ====================================================
func _changed(obj: Dictionary) -> void:
	_to_viewers(obj, str(obj.get("buff_map", obj.get("map", ""))), "buffs", {"id": obj["id"], "list": list_of(obj)})

func _to_viewers(obj: Dictionary, map_name: String, what: String, data: Dictionary) -> void:
	if world == null:
		return
	var pos: Vector3 = obj.get("pos", Vector3.ZERO)
	for peer in world.players:
		var o = world.players[peer]
		if o["map"] == map_name and o["pos"].distance_to(pos) <= Proto.VIEW_RANGE:
			net.push(peer, what, data)

func _push_stats(p: Dictionary) -> void:
	if world == null or not stats_push.is_valid():
		return
	for peer in world.players:
		if world.players[peer] == p:
			stats_push.call(peer, p)
			return

func _player_by_id(id: int):
	if world == null:
		return null
	for p in world.players.values():
		if int(p["id"]) == id:
			return p
	return null

func _fighting(obj: Dictionary) -> bool:
	if _is_player(obj):
		return _now() / 1000.0 - float(obj.get("fight", -100.0)) < COMBAT_TIME
	return obj.get("fight", false) == true

func _now() -> int:
	return int(clock.call()) if clock.is_valid() else Time.get_ticks_msec()

static func _is_player(obj: Dictionary) -> bool:
	return int(obj.get("id", 0)) < Proto.NPC_ID_BASE

static func _key(obj: Dictionary) -> int:
	return int(obj.get("id", 0))
