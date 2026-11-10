extends RefCounted

# ====================================================
# Einsetzen der Fertigkeiten (Fertigkeiten-Fahrplan F2) nach wskill SkillWrapper::StartSkill / Run /
# CheckCondition, Skill::FirstRun / Run / CheckRange und PlayerWrapper::FillAttackMsg / SetPerform.
# Daten: Plugin Server/skill_templates.json (tools/server_data/skill_templates.py aus der Editor-
# Datenbank), Formeln über skill_expr.gd mit den Werten der Figur (_ctx: level = Stufe der Fertigkeit,
# player.*, t0..t15 = Talent-Formeln, range = Reichweite der Waffe).
# Ablauf (skill_cast):
#   Prüfen   tot, bekannt, schon umgesetzt (usable), zaubert schon, Abklingzeit, Ziel (sichtbares, lebendes
#            Monster), Mana (mp), Weite: Abstand > Größen + pray_max -> OUT_OF_RANGE, < pray_min -> TOO_CLOSE
#   Zaubern  Zauberzeit = Summe der Prozedur-Zeiten (total_time, wie GetTotalCastTime);
#            Prozeduren nacheinander: Prozedur 1 rechnet sofort (calc) und dauert time ms, dann jede
#            weitere: calc, time ms (mindestens MIN_TIME); setzt calc player.perform = 1, wirkt die
#            Fertigkeit (Perform): Mana ab, Abklingzeit beginnt (DoCost), Schaden auf das Ziel, wenn es
#            noch in effect_dist + Größen steht: Waffenschaden * ratio + damage, Treffer + attack,
#            Krit + crit, Krit-Schaden + critdamage (Standard ratio 1, sonst 0), dann wie der
#            Normalangriff (combat.gd damage / hit_monster, Meldung hit mit skill und elapsed).
#            Statuseffekte (buffs.gd): eigene Plätze beim Wirken, Ziel-Plätze nur bei einem Treffer (vor dem
#            Schaden), Erfolg / Dauer / Werte aus den Formeln. Element (damagetype), Meisterschaft / Widerstand fehlen.
#   Abbruch  Bewegen (moved, waagrecht > MOVE_CANCEL) oder skill_cancel, solange die laufende Prozedur abbrechbar ist (cancel,
#            Prozedur 1 meist "1"); Tod; Ziel gestorben / verschwunden vor der Wirkung.
# Umgesetzt (usable): Angriff / Fluch (type 1 / 3) auf ein Ziel (approach 0 / 11), von Hand (use 2),
# ohne Bewegung (move_mode 0). Der Normalangriff pausiert während des Zauberns.
# Abklingzeiten nur im Speicher (gehen beim Verlassen der Welt verloren).
# Meldungen: skill_start an die anderen in Sicht, skill_end an alle (auch den Zaubernden), cooldown an
# den Zaubernden, stats nach dem Mana-Abzug.
# ====================================================

const Proto = preload("../common/protocol.gd")
const Expr = preload("skill_expr.gd")
const Buffs = preload("buffs.gd")
const PLUGIN_SERVER = "res://addons/PWE-Manager/Server/"
const Settings = preload("../common/settings.gd")
const MIN_TIME = 50 # ms je Prozedur (Skill::FirstRun / Run)
const SLACK = 1.0 # m Spielraum für die Weite (Position des Clients ist bis 0,1 s alt)
const MOVE_CANCEL = 0.3 # m: so weit bewegt bricht das Zaubern ab
const PLAYER_RADIUS = 0.5
const DEFAULTS = {"ratio": 1.0, "damage": 0.0, "crit": 0.0, "critdamage": 0.0, "toukonratio": 1.0, "damagetype": 0,
	"attack": 0, "player.perform": 0, "player.pray": 0}

var world # world.gd
var net
var log_line: Callable
var combat # combat.gd
var buffs = null # buffs.gd: Statuseffekte der Fertigkeit
var stats_push: Callable # (peer, p) -> Meldung stats
var templates = {} # ID -> Fertigkeit


func _init(p_world, p_net, p_log: Callable, p_combat) -> void:
	world = p_world
	net = p_net
	log_line = p_log
	combat = p_combat

func load_templates() -> String:
	var path = Settings.server_data_path("skill_templates.json")
	if not FileAccess.file_exists(path):
		return "Не найден файл %s" % path
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not d is Dictionary:
		return "Файл %s содержит некорректный JSON" % path
	for s in d.get("skills", []):
		templates[int(s["id"])] = s
	return ""

# Lässt sich die Fertigkeit schon einsetzen (Umfang F2)?
func usable(sk: Dictionary) -> bool:
	return int(sk["type"]) in [1, 3] and int(sk["range"]["approach"]) in [0, 11] and int(sk["use"]) == 2 \
		and int(sk["move_mode"]) == 0 and sk["procs"].size() > 0

# Werte einer bekannten Fertigkeit für den Client (Tooltip-Prüfungen, Zauberbalken, Annäherung)
func info(p: Dictionary, id: int) -> Dictionary:
	var sk: Dictionary = templates.get(id, {})
	if sk.is_empty():
		return {}
	var ctx = _ctx(p, sk, int(p.get("skills", {}).get(id, 1)))
	return {"mp": _mp(sk, ctx), "time": total_time(sk, ctx), "cool": maxi(0, int(Expr.value(sk["cool"], ctx))),
		"cast": float(Expr.value(sk["cast_dist"], ctx)), "range": float(Expr.value(sk["pray_max"], ctx)),
		"min": float(Expr.value(sk["pray_min"], ctx)), "type": int(sk["type"]), "approach": int(sk["range"]["approach"]),
		"instant": int(sk["time_type"]) == 2, "act": action_name(str(sk["actions"].get("0", "")), int(ctx.get("player.action", 0))),
		"auto": int(sk["autoattack"]) == 0, "usable": usable(sk)}

func infos(p: Dictionary) -> Dictionary:
	var out = {}
	for id in p.get("skills", {}):
		var i = info(p, id)
		if not i.is_empty():
			out[str(id)] = i
	return out

# Restliche Abklingzeiten {ID: ms}
func cooldowns(p: Dictionary) -> Dictionary:
	var out = {}
	var now = Time.get_ticks_msec()
	for id in p.get("cooldowns", {}):
		if int(p["cooldowns"][id]) > now:
			out[str(id)] = int(p["cooldowns"][id]) - now
	return out

# Aktion aus der Formel der Fertigkeit ("player.action==1?神族_X:(player.action==2?魔族_X:X)")
static func action_name(e: String, action: int) -> String:
	e = e.strip_edges()
	while e.begins_with("(") and e.ends_with(")"):
		e = e.substr(1, e.length() - 2).strip_edges()
	var q = e.find("?")
	if q < 0:
		return e
	var rest = e.substr(q + 1)
	var depth = 0
	for i in rest.length():
		var c = rest[i]
		if c == "(":
			depth += 1
		elif c == ")":
			depth -= 1
		elif c == ":" and depth == 0:
			var ok = int(Expr.value(e.substr(0, q), {"player.action": action})) != 0
			return action_name(rest.substr(0, i) if ok else rest.substr(i + 1), action)
	return e


# ====================================================
# ANFRAGEN -> [Code, Daten]
# ====================================================
func cast(peer: int, p: Dictionary, id, target) -> Array:
	if not id is int or not target is int:
		return [Proto.Code.BAD_REQUEST, {}]
	if p.get("dead", false):
		return [Proto.Code.YOU_ARE_DEAD, {}]
	if not p.get("skills", {}).has(id):
		return [Proto.Code.SKILL_UNKNOWN, {}]
	var sk: Dictionary = templates.get(id, {})
	if sk.is_empty() or not usable(sk):
		return [Proto.Code.SKILL_NOT_YET, {}]
	if p.has("cast"):
		return [Proto.Code.SKILL_BUSY, {}]
	var now = Time.get_ticks_msec()
	if int(p.get("cooldowns", {}).get(id, 0)) > now:
		return [Proto.Code.SKILL_COOLDOWN, {}]
	var nm = world.npc_maps.get(p["map"])
	var o = nm.objects.get(target) if nm != null and p["npc_seen"].has(target) else null
	if o == null or o["npc"] or o.get("mine", false) or not o["select"] or int(o["hp"]) <= 0:
		return [Proto.Code.NO_TARGET, {}]
	var level = int(p["skills"][id])
	var ctx = _ctx(p, sk, level)
	var cost = _mp(sk, ctx)
	if int(p["mp"]) < cost:
		return [Proto.Code.NO_MANA, {}]
	var mprop = combat.monster_props(nm, o)
	var dist = p["pos"].distance_to(o["pos"])
	var reach = PLAYER_RADIUS + float(mprop["size"]) * 0.5
	if dist > reach + float(Expr.value(sk["pray_max"], ctx)) + SLACK:
		return [Proto.Code.OUT_OF_RANGE, {}]
	if dist < float(Expr.value(sk["pray_min"], ctx)):
		return [Proto.Code.TOO_CLOSE, {}]
	var total = total_time(sk, ctx)
	var c = {"id": id, "level": level, "target": target, "start": now, "pos": p["pos"], "idx": 0, "ctx": ctx,
		"cost": cost, "cool": maxi(0, int(Expr.value(sk["cool"], ctx))), "done": false}
	for k in DEFAULTS:
		ctx[k] = DEFAULTS[k]
	p["cast"] = c
	c["next"] = now + _run_proc(sk, c, 0)
	var a: Dictionary = p.get("attack", {})
	if not a.is_empty():
		a["next"] = maxf(float(a.get("next", 0.0)), (now + total) / 1000.0)
	var act = action_name(str(sk["actions"].get("0", "")), int(ctx.get("player.action", 0)))
	_to_viewers(p, p["pos"], "skill_start", {"src": p["id"], "id": id, "dst": target, "time": total, "act": act}, false)
	log_line.call("Умение: %s применяет %d (%s) к цели %d, время %d мс" % [p["name"], id, sk["name"], target, total])
	if c["done"]:
		_perform(peer, p, sk, c, nm, o)
	return [Proto.Code.OK, {"id": id, "time": total}]

func cancel_request(peer: int, p: Dictionary) -> Array:
	cancel(peer, p, false, "Anfrage")
	return [Proto.Code.OK, {}]

# Zaubern abbrechen; force = auch nicht abbrechbare Prozeduren (Tod, Ziel weg)
func cancel(_peer: int, p: Dictionary, force: bool, why: String = "") -> void:
	var c: Dictionary = p.get("cast", {})
	if c.is_empty():
		return
	var sk: Dictionary = templates.get(int(c["id"]), {})
	if not force:
		var proc: Dictionary = sk["procs"][mini(int(c["idx"]), sk["procs"].size() - 1)]
		if int(Expr.value(str(proc.get("cancel", "")), c["ctx"])) == 0:
			return
	p.erase("cast")
	_to_viewers(p, p["pos"], "skill_end", {"src": p["id"], "id": c["id"], "ok": false}, true)
	log_line.call("Умение: %s прерывает %d (%s)" % [p["name"], c["id"], why])

# Bewegung (world.gd move): waagrecht weiter als MOVE_CANCEL vom Ort des Zauberbeginns -> abbrechen
func moved(peer: int, p: Dictionary) -> void:
	var c: Dictionary = p.get("cast", {})
	if c.is_empty():
		return
	var d = Vector2(p["pos"].x - c["pos"].x, p["pos"].z - c["pos"].z).length()
	if d > MOVE_CANCEL:
		cancel(peer, p, false, "bewegt %.2f m" % d)


# ====================================================
# TAKT (world.gd, vor dem Kampf-Takt)
# ====================================================
func tick() -> void:
	var now = Time.get_ticks_msec()
	for peer in world.players.keys():
		var p = world.players.get(peer)
		if p == null or not p.has("cast"):
			continue
		if p.get("dead", false):
			cancel(peer, p, true, "tot")
			continue
		var c: Dictionary = p["cast"]
		if now < int(c["next"]):
			continue
		var sk: Dictionary = templates[int(c["id"])]
		var idx = int(c["idx"]) + 1
		if idx >= sk["procs"].size():
			p.erase("cast")
			_to_viewers(p, p["pos"], "skill_end", {"src": p["id"], "id": c["id"], "ok": true}, true)
			log_line.call("Умение: %s завершил применение %d" % [p["name"], c["id"]])
			continue
		var nm = world.npc_maps.get(p["map"])
		var o = nm.objects.get(int(c["target"])) if nm != null else null
		if not c["done"] and (o == null or int(o["hp"]) <= 0):
			cancel(peer, p, true, "Ziel weg") # vor der Wirkung gestorben / verschwunden
			continue
		c["next"] = now + _run_proc(sk, c, idx)
		if c["done"] and not c.get("performed", false):
			_perform(peer, p, sk, c, nm, o)

# Prozedur idx: rechnen, -> Dauer ms; player.perform = 1 markiert die Wirkung (done)
func _run_proc(sk: Dictionary, c: Dictionary, idx: int) -> int:
	c["idx"] = idx
	var proc: Dictionary = sk["procs"][idx]
	var ctx: Dictionary = c["ctx"]
	ctx["player.perform"] = 0
	Expr.value(str(proc["calc"]), ctx)
	if int(ctx.get("player.perform", 0)) == 1:
		c["done"] = true
	return maxi(MIN_TIME, int(Expr.value(str(proc["time"]), ctx)))

# Wirkung: Mana, Abklingzeit, Schaden
func _perform(peer: int, p: Dictionary, sk: Dictionary, c: Dictionary, nm, o) -> void:
	c["performed"] = true
	var now = Time.get_ticks_msec()
	p["mp"] = maxi(0, int(p["mp"]) - int(c["cost"]))
	if int(c["cool"]) > 0:
		if not p.has("cooldowns"):
			p["cooldowns"] = {}
		p["cooldowns"][int(c["id"])] = now + int(c["cool"])
		net.push(peer, "cooldown", {"id": c["id"], "ms": c["cool"]})
	if stats_push.is_valid():
		stats_push.call(peer, p)
	var ctx: Dictionary = c["ctx"]
	_states(p, p, sk, ctx, true, false) # BlessMe: auf sich, unabhängig vom Treffer
	if o == null or int(o["hp"]) <= 0:
		return
	var mprop = combat.monster_props(nm, o)
	var reach = PLAYER_RADIUS + float(mprop["size"]) * 0.5 + float(Expr.value(str(sk["range"]["effect_dist"]), ctx, 0.0))
	if p["pos"].distance_to(o["pos"]) > reach + SLACK:
		_to_viewers(p, p["pos"], "skill_end", {"src": p["id"], "id": c["id"], "ok": false}, true)
		p.erase("cast")
		log_line.call("Умение: %s — промах %d, цель вне радиуса действия" % [p["name"], c["id"]])
		return
	var att: Dictionary = combat.player_props(p).duplicate()
	var ratio = float(ctx.get("ratio", 1.0))
	var plus = float(ctx.get("damage", 0.0))
	var d: Array = att["dmg"]
	att["dmg"] = [float(d[0]) * ratio + plus, float(d[1]) * ratio + plus]
	att["hit"] = float(att.get("hit", 0)) + float(ctx.get("attack", 0))
	att["crit"] = float(att.get("crit", 0)) + 100.0 * float(ctx.get("crit", 0.0))
	att["crit_dmg"] = float(att.get("crit_dmg", 100)) + 100.0 * float(ctx.get("critdamage", 0.0))
	var r = combat.damage(att, Buffs.with_mods(mprop, o))
	if not r["miss"]:
		_states(p, o, sk, ctx, false, r["crit"]) # StateAttack: nur bei Treffer, vor dem Schaden
	combat.hit_monster(peer, p, nm, o, r, now / 1000.0, {"skill": c["id"], "elapsed": now - int(c["start"])})

# Statuseffekte der Fertigkeit (SkillStub BuildSkillState): Ziel-Plätze (self false) bzw. eigene; Erfolg, Dauer
# und Werte aus den Formeln; ohne Erfolgs-Formel 0 % (StateFilter _succeedparam)
func _states(p: Dictionary, target: Dictionary, sk: Dictionary, ctx: Dictionary, self_slots: bool, crit: bool) -> void:
	if buffs == null:
		return
	for e in sk["states"]:
		if bool(e["self"]) != self_slots or str(e["chance"]).strip_edges() == "":
			continue
		var chance = int(Expr.value(str(e["chance"]), ctx, 0))
		if chance == 0:
			continue
		var values = []
		for x in e["data"]:
			values.append(float(Expr.value(str(x), ctx, 0.0)) if str(x).strip_edges() != "" else 0.0)
		buffs.apply(target, p["map"], int(e["id"]), values, int(Expr.value(str(e["time"]), ctx, 0)), chance, p, crit)


# ====================================================
# HILFEN
# ====================================================
# Werte für die Formeln (PlayerWrapper / skill.og); Talente t0..t15 = (int) Formel
func _ctx(p: Dictionary, sk: Dictionary, level: int) -> Dictionary:
	var a: Dictionary = combat.player_props(p)
	var dmg: Array = a.get("dmg", [1, 1])
	var ctx = {"id": int(sk["id"]), "level": level, "showlevel": level, "playerlevel": int(p["level"]), "rand": randi() % 100,
		"range": combat.player_range(p), "player.level": int(p["level"]), "player.hp": int(p["hp"]), "player.maxhp": int(p["max_hp"]),
		"player.mp": int(p["mp"]), "player.maxmp": int(p["max_mp"]), "player.damagelow": int(dmg[0]), "player.damagehigh": int(dmg[1]),
		"player.attack": int(a.get("hit", 0)), "player.armor": int(a.get("eva", 0)), "player.defence": int(a.get("def", 0)),
		"player.critrate": float(a.get("crit", 0)) / 100.0, "player.critdmg": float(a.get("crit_dmg", 100)) / 100.0,
		"player.race": int(p["race"]), "player.runspeed": Proto.RUN_SPEED, "player.action": 0,
		"player.skilllevel": p.get("skills", {}), "player.bufflevel": {}, "player.buffnum": {}, "player.rune": {}}
	for i in 16:
		var k = "t%d" % i
		if sk["talents"].has(k):
			ctx[k] = int(Expr.value(str(sk["talents"][k]), ctx))
	return ctx

# Zauberzeit = Summe der Prozedur-Zeiten (SkillStub::GetTotalCastTime; exetime ist nur ein Anzeigewert)
static func total_time(sk: Dictionary, ctx: Dictionary) -> int:
	var t = 0
	for proc in sk["procs"]:
		t += maxi(MIN_TIME, int(Expr.value(str(proc["time"]), ctx)))
	return t

func _mp(sk: Dictionary, ctx: Dictionary) -> int:
	return maxi(0, int(Expr.value(str(sk["mp"]), ctx)))

# Meldung an alle Spieler in Sicht des Ortes; self_too = auch an den Zaubernden
func _to_viewers(p: Dictionary, pos: Vector3, what: String, data: Dictionary, self_too: bool) -> void:
	for peer in world.players:
		var o = world.players[peer]
		if (o != p or self_too) and o["map"] == p["map"] and o["pos"].distance_to(pos) <= Proto.VIEW_RANGE:
			net.push(peer, what, data)
