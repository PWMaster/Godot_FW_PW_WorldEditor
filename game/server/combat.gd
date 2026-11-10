extends RefCounted

# ====================================================
# Kampf auf dem Server (Fahrplan Schritt 9), vereinfacht nach dem gs (Normalangriff, gactive_imp,
# Monster-KI ai_aggro / ai_rest) und wskill SkillWrapper::AttackDamage für den Schaden:
#   Treffer   Trefferchance = Treffer * 0,333 - Ausweichen * 0,5 + 85 (in % , mindestens 10; zwischen
#             Spielern noch - Stufenabstand bis +-20), sonst verfehlt
#   Krit      Chance = Krit-Rate - Krit-Ausweichen (%), Faktor = (Krit-Schaden - Krit-Verteidigung) / 100,
#             mindestens 1
#   Schaden   (min + Zufall * (max - min) - Verteidigung) * Wirkung * Krit-Faktor, mindestens 1;
#             Wirkung = 1 + F - G mit F = -0,001 * Stufe des Angreifers, G = -0,001 * Stufe des Opfers
#             (Meisterschaft / Widerstand gibt es noch nicht), begrenzt auf 0,3 - 2
# Werte: Spieler stats.attr (Klasse, Stufe, Ausrüstung), Monster ihre Vorlage + lvlup * (Stufe - level[0])
# (npc_templates.json; Krit-Werte dort in %).
# Normalangriff (attack {id}): Spieler greift sein Ziel alle PLAYER_ATTACK_INTERVAL s an (nicht während er
# eine Fertigkeit zaubert, skill_cast.gd), solange es lebt und in Reichweite ist (Waffe attack_range, sonst die der Klasse, + halbe Größe des Monsters +
# RANGE_SLACK); attack_stop beendet es (Bewegung). Das Tempo kommt im Original aus dem Normalangriff-
# Skill (wskill-Daten fehlen in den Quellen): hier fest.
# Monster: angegriffen -> Ziel ist der Angreifer (Aggro), aggressive Monster greifen Spieler in Sicht
# (sight) von selbst an; laufen mit run zum Ziel, schlagen in attack_range alle MONSTER_ATTACK_INTERVAL
# s zu; zu weit vom Geburtsort (aggro_range), aggro_time s ohne Schlagabtausch oder Ziel tot / weg -> zurück
# zum Geburtsort, dort volle HP (return_home); aggro_time zählt ab dem letzten Treffer in beide
# Richtungen (ein Monster, das noch zuschlagen kann, bleibt dran).
# Tod eines Monsters: npcs.gd kill (Respawn), EXP an den Spieler, der den letzten Treffer gesetzt hat
# (exp + lvlup.exp * Stufen, nur mit killed_exp), Quests (quests.gd kill). Tod eines Spielers: HP 0,
# Angriffe enden, Monster lassen ab; revive bringt ihn mit REVIVE_HP der Höchstwerte zum
# Wiederbelebungspunkt seiner Welt (town_pos der Startvorlagen, ResurrectNearby), ohne EXP-Verlust.
# Regeneration jede Sekunde: hp_gen / mp_gen der Klasse (außerhalb des Kampfes [0], im Kampf [2]);
# im Kampf bis COMBAT_TIME s nach dem letzten Treffer.
# Meldungen: hit {src, dst, dmg, miss, crit, hp, max_hp} an alle in Sicht des Opfers, die / revive
# {id, pos} (Spieler) an alle in Sicht, kill {id, tid, exp} an den Spieler; Monster-Tod über
# npc_leave {die: true}, Monster-Gänge über npc_move (world.gd).
# ====================================================

const Proto = preload("../common/protocol.gd")
const Settings = preload("../common/settings.gd")
const Buffs = preload("buffs.gd")
const PLUGIN_SERVER = "res://addons/PWE-Manager/Server/"
const PLAYER_ATTACK_INTERVAL = 2.0
const MONSTER_ATTACK_INTERVAL = 2.0
const RANGE_SLACK = 1.0 # m
const PLAYER_RADIUS = 0.5
const CHASE_REPATH = 1.0 # m: Ziel weiter gelaufen -> neuer Gang
const COMBAT_TIME = 10.0
const REVIVE_HP = 0.1
const AI_RATE = 0.25 # s zwischen den Entscheidungen der Monster

var world # world.gd
var net
var log_line: Callable
var stats # stats.gd
var quests = null
var inventory = null
var casting = null # skill_cast.gd
var buffs = null # buffs.gd
var revive_points = {} # Welt -> Vector3 (start_roles.json town_pos)
var _ai_t = 0.0
var _regen_t = 0.0


func _init(p_world, p_net, p_log: Callable, p_stats) -> void:
	world = p_world
	net = p_net
	log_line = p_log
	stats = p_stats
	var path = Settings.server_data_path("start_roles.json")
	var d = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	for r in (d.get("roles", []) if d is Dictionary else []):
		var tw = int(r.get("town_world", 0))
		var tp: Array = r.get("town_pos", [])
		if tw != 0 and tp.size() == 3 and not revive_points.has(tw):
			revive_points[tw] = Vector3(tp[0], tp[1], tp[2])


# ====================================================
# WERTE
# ====================================================
# Kampfwerte eines Monsters (einmal je Objekt berechnet)
func monster_props(nm, o: Dictionary) -> Dictionary:
	if o.has("prop"):
		return o["prop"]
	var t: Dictionary = nm.monster_template(int(o["tid"]))
	var up: Dictionary = t.get("lvlup", {})
	var levels: Array = t.get("level", [o["level"]])
	var n = int(o["level"]) - (int(levels[0]) if not levels.is_empty() else int(o["level"]))
	var v = func(key: String) -> float: return float(t.get(key, 0)) + float(up.get(key, 0)) * n
	var lo = v.call("min_dmg")
	o["prop"] = {"dmg": [lo, maxf(lo, v.call("max_dmg"))], "def": v.call("defense"), "hit": v.call("attack"), "eva": v.call("armor"),
		"crit": v.call("crit_rate"), "crit_dmg": v.call("crit_damage"), "anti_crit": v.call("anti_crit_rate"),
		"anti_crit_dmg": v.call("anti_crit_damage"), "level": int(o["level"]), "exp": int(v.call("exp")) if int(t.get("killed_exp", 1)) != 0 else 0,
		"range": float(t.get("attack_range", 1.0)), "size": float(t.get("size", 1.0)), "run": maxf(0.5, float(t.get("run", 3.0))),
		"sight": float(t.get("sight", 10.0)), "aggressive": int(t.get("aggressive", 0)) != 0,
		"aggro_range": float(t.get("aggro_range", 28.0)), "aggro_time": float(t.get("aggro_time", 20.0)),
		"return_home": int(t.get("return_home", 1)) != 0}
	return o["prop"]

func player_props(p: Dictionary) -> Dictionary:
	var a: Dictionary = p.get("attr", {})
	var out = a.duplicate()
	out["level"] = p["level"]
	if not out.has("dmg"):
		out["dmg"] = [1, 1]
	return Buffs.with_mods(out, p)

# Reichweite des Normalangriffs eines Spielers (Waffe, sonst Klasse)
func player_range(p: Dictionary) -> float:
	var weapon = int(p.get("equip", {}).get(0, 0))
	var r = float(inventory.item(weapon).get("range", 0.0)) if inventory != null and weapon != 0 else 0.0
	if r <= 0.0:
		r = float(stats.classes.get(str(p["class"]), {}).get("attack_range", 4.0))
	return r

# AttackDamage -> {dmg, miss, crit}
static func damage(att: Dictionary, vic: Dictionary, pvp: bool = false) -> Dictionary:
	var f = clampi(int(att["level"]) - int(vic["level"]), -20, 20) if pvp else 0
	var hit_rate = maxi(10, int(float(att.get("hit", 0)) * 0.333 - float(vic.get("eva", 0)) * 0.5 + 85 - f))
	if hit_rate < 100 and randi() % 100 > hit_rate:
		return {"dmg": 0, "miss": true, "crit": false}
	var crit = int(float(att.get("crit", 0)) - float(vic.get("anti_crit", 0)))
	var crit_factor = 1.0
	var is_crit = crit >= 100 or randi() % 100 < crit
	if is_crit:
		crit_factor = maxf(1.0, (float(att.get("crit_dmg", 100)) - float(vic.get("anti_crit_dmg", 0))) / 100.0)
	var d: Array = att["dmg"]
	var effect = clampf(1.0 - 0.001 * int(att["level"]) + 0.001 * int(vic["level"]), 0.3, 2.0)
	var dmg = int((float(d[0]) + randf() * (float(d[1]) - float(d[0])) - float(vic.get("def", 0))) * effect * crit_factor)
	return {"dmg": maxi(1, dmg), "miss": false, "crit": is_crit}


# ====================================================
# ANFRAGEN -> [Code, Daten]
# ====================================================
func attack(peer: int, p: Dictionary, id: int) -> Array:
	if p.get("dead", false):
		return [Proto.Code.YOU_ARE_DEAD, {}]
	var nm = world.npc_maps.get(p["map"])
	var o = nm.objects.get(id) if nm != null and p["npc_seen"].has(id) else null
	if o == null or o["npc"] or o.get("mine", false) or not o["select"] or int(o["hp"]) <= 0:
		return [Proto.Code.ATTACK_INVALID, {}]
	var now = Time.get_ticks_msec() / 1000.0
	var keep = p.get("attack", {})
	p["attack"] = {"id": id, "next": maxf(now, float(keep.get("next", 0.0)))}
	return [Proto.Code.OK, {"id": id, "interval": PLAYER_ATTACK_INTERVAL, "range": player_range(p)}]

func stop(p: Dictionary) -> void:
	var a = p.get("attack", {})
	if not a.is_empty():
		p["attack"] = {"id": 0, "next": a.get("next", 0.0)}

func revive(peer: int, p: Dictionary) -> Array:
	if not p.get("dead", false):
		return [Proto.Code.NOT_DEAD, {}]
	p["dead"] = false
	p["hp"] = maxi(1, int(p["max_hp"] * REVIVE_HP + 0.5))
	p["mp"] = int(p["max_mp"] * REVIVE_HP + 0.5)
	var pos: Vector3 = revive_points.get(int(p["world"]), p["pos"])
	p["pos"] = pos
	p["t"] = Time.get_ticks_msec()
	net.push(peer, "pos_correct", {"pos": [pos.x, pos.y, pos.z], "dir": p["dir"]})
	_push_stats(peer, p)
	_to_viewers(p["map"], pos, "revive", {"id": p["id"], "pos": [pos.x, pos.y, pos.z]})
	log_line.call("Kampf: %s wiederbelebt bei %s" % [p["name"], world._fmt(pos)])
	return [Proto.Code.OK, {"pos": [pos.x, pos.y, pos.z]}]


# ====================================================
# TAKT (world.gd, 10 / s, nach dem Takt der NPCs und vor dem Verteilen der Gänge)
# ====================================================
func tick(now: float, dt: float) -> void:
	for peer in world.players.keys():
		var p = world.players.get(peer)
		if p != null:
			_player_attack(peer, p, now)
	_ai_t += dt
	if _ai_t >= AI_RATE:
		_ai_t = 0.0
		for map_name in world.npc_maps:
			_monsters(world.npc_maps[map_name], map_name, now)
	_regen_t += dt
	if _regen_t >= 1.0:
		_regen_t -= 1.0
		for peer in world.players:
			_regen(peer, world.players[peer], now)

func _player_attack(peer: int, p: Dictionary, now: float) -> void:
	var a: Dictionary = p.get("attack", {})
	if a.is_empty() or int(a.get("id", 0)) == 0 or p.get("dead", false) or now < float(a["next"]) or p.has("cast"):
		return
	var nm = world.npc_maps.get(p["map"])
	var o = nm.objects.get(int(a["id"])) if nm != null else null
	if o == null or int(o["hp"]) <= 0:
		stop(p)
		return
	var mp = monster_props(nm, o)
	if Vector2(o["pos"].x - p["pos"].x, o["pos"].z - p["pos"].z).length() > player_range(p) + mp["size"] * 0.5 + RANGE_SLACK:
		return # der Client läuft noch heran
	a["next"] = now + PLAYER_ATTACK_INTERVAL
	hit_monster(peer, p, nm, o, damage(player_props(p), Buffs.with_mods(mp, o)), now)

# Treffer eines Spielers auf ein Monster (Normalangriff, Fertigkeiten skill_cast.gd): Leben, Aggro,
# Meldung hit (extra: z.B. skill, elapsed), Tod
func hit_monster(peer: int, p: Dictionary, nm, o: Dictionary, r: Dictionary, now: float, extra: Dictionary = {}) -> void:
	p["fight"] = now
	o["hp"] = maxi(0, int(o["hp"]) - int(r["dmg"]))
	o["last_hit"] = now
	if int(o.get("target", 0)) == 0:
		o["target"] = p["id"]
		o["fight"] = true
		o["to"] = null
	var msg = {"src": p["id"], "dst": o["id"], "dmg": r["dmg"], "miss": r["miss"], "crit": r["crit"], "hp": o["hp"], "max_hp": o["max_hp"]}
	msg.merge(extra)
	_to_viewers(p["map"], o["pos"], "hit", msg)
	if int(o["hp"]) <= 0:
		_monster_dies(peer, p, nm, o, now)

func _monster_dies(peer: int, p: Dictionary, nm, o: Dictionary, now: float) -> void:
	var mp = monster_props(nm, o)
	if buffs != null:
		buffs.forget(o)
	nm.kill(int(o["id"]), now)
	for other in world.players.values():
		if int(other.get("attack", {}).get("id", 0)) == int(o["id"]):
			stop(other)
	var exp = int(mp["exp"])
	if exp > 0 and quests != null:
		quests.add_exp(p, exp)
		quests.save_stats(p)
		_push_stats(peer, p)
	net.push(peer, "kill", {"id": o["id"], "tid": o["tid"], "exp": exp})
	if quests != null:
		quests.kill(peer, p, int(o["tid"]))

# Monster einer Map: Aggro, Verfolgen, Zuschlagen, Zurücklaufen
func _monsters(nm, map_name: String, now: float) -> void:
	var near = []
	for p in world.players.values():
		if p["map"] == map_name and not p.get("dead", false):
			near.append(p)
	for o in nm.objects.values():
		if o["npc"] or o.get("mine", false):
			continue
		if int(o.get("target", 0)) != 0:
			_fight(nm, o, now)
		elif o.get("homing", false):
			if o["to"] == null:
				o["homing"] = false
				o["fight"] = false
				if buffs != null:
					buffs.clear(o)
				o["hp"] = o["max_hp"]
		elif not near.is_empty():
			var mp = monster_props(nm, o)
			if not mp["aggressive"]:
				continue
			for p in near:
				if p["pos"].distance_to(o["pos"]) <= mp["sight"]:
					o["target"] = p["id"]
					o["fight"] = true
					o["to"] = null
					o["last_hit"] = now
					break

func _fight(nm, o: Dictionary, now: float) -> void:
	var mp = monster_props(nm, o)
	var p = _player_by_id(int(o["target"]))
	var home: Vector3 = o["home"]
	var lost = p == null or p.get("dead", false) or p["map"] != nm.map_name \
		or Vector2(o["pos"].x - home.x, o["pos"].z - home.z).length() > mp["aggro_range"] \
		or now - float(o.get("last_hit", now)) > mp["aggro_time"]
	if lost:
		_go_home(nm, o, mp)
		return
	var flat = Vector2(p["pos"].x - o["pos"].x, p["pos"].z - o["pos"].z)
	var reach = mp["range"] + mp["size"] * 0.5 + PLAYER_RADIUS
	if flat.length() > reach + 0.3:
		var goal = Vector3(p["pos"].x, o["pos"].y, p["pos"].z) - Vector3(flat.normalized().x, 0, flat.normalized().y) * reach * 0.8
		var last = o.get("chase", null)
		if o["to"] == null or last == null or (last as Vector3).distance_to(p["pos"]) > CHASE_REPATH:
			if nm.terrain != null:
				goal.y = nm.terrain.height(goal.x, goal.z) + (home.y - nm.terrain.height(home.x, home.z))
			o["to"] = goal
			o["speed"] = maxf(0.3, mp["run"] + float(o.get("speed_add", 0.0)))
			o["dir"] = atan2(flat.x, flat.y)
			o["chase"] = p["pos"]
			nm.moves.append(o["id"])
		return
	if o["to"] != null:
		o["to"] = null
		o["speed"] = 0.0
	o["dir"] = atan2(flat.x, flat.y)
	if now < float(o.get("next_attack", 0.0)):
		return
	o["next_attack"] = now + MONSTER_ATTACK_INTERVAL
	o["last_hit"] = now # Kampf läuft: aggro_time zählt ab dem letzten Schlagabtausch
	var peer = _peer_of(p)
	p["fight"] = now
	var r = damage(Buffs.with_mods(mp, o), player_props(p))
	p["hp"] = maxi(0, int(p["hp"]) - int(r["dmg"]))
	_to_viewers(p["map"], p["pos"], "hit", {"src": o["id"], "dst": p["id"], "dmg": r["dmg"], "miss": r["miss"], "crit": r["crit"],
		"hp": p["hp"], "max_hp": p["max_hp"]})
	if int(p["hp"]) <= 0:
		_player_dies(peer, p)

func _go_home(nm, o: Dictionary, mp: Dictionary) -> void:
	o["target"] = 0
	o["chase"] = null
	if not mp["return_home"]:
		o["fight"] = false
		return
	var home: Vector3 = o["home"]
	if o["pos"].distance_to(home) < 0.3:
		o["fight"] = false
		if buffs != null:
			buffs.clear(o)
		o["hp"] = o["max_hp"]
		return
	o["homing"] = true
	o["to"] = home
	o["speed"] = maxf(0.3, mp["run"] + float(o.get("speed_add", 0.0)))
	o["dir"] = atan2(home.x - o["pos"].x, home.z - o["pos"].z)
	nm.moves.append(o["id"])

func _player_dies(peer: int, p: Dictionary) -> void:
	p["dead"] = true
	p["hp"] = 0
	stop(p)
	if casting != null:
		casting.cancel(peer, p, true, "tot")
	if buffs != null:
		buffs.on_death(p)
	var g: Dictionary = p.get("gather", {})
	if not g.is_empty() and inventory != null:
		inventory.cancel_gather(peer, p, world.npc_maps.get(p["map"]), true)
	if quests != null:
		quests.save_stats(p)
	_push_stats(peer, p)
	_to_viewers(p["map"], p["pos"], "die", {"id": p["id"]})
	log_line.call("Kampf: %s stirbt bei %s" % [p["name"], world._fmt(p["pos"])])

func _regen(peer: int, p: Dictionary, now: float) -> void:
	if p.get("dead", false):
		return
	var c: Dictionary = stats.classes.get(str(p["class"]), {})
	var i = 2 if now - float(p.get("fight", -100.0)) < COMBAT_TIME else 0
	var hg: Array = c.get("hp_gen", [0, 0, 0, 0])
	var mg: Array = c.get("mp_gen", [0, 0, 0, 0])
	var m: Dictionary = Buffs.mods_of(p)
	var hp = mini(int(p["max_hp"]), int(p["hp"]) + int(float(hg[i]) * (1.0 + float(m.get("hp_gen%", 0.0)) / 1000.0)))
	var mp = mini(int(p["max_mp"]), int(p["mp"]) + int(float(mg[i]) * (1.0 + float(m.get("mp_gen%", 0.0)) / 1000.0)))
	if hp != int(p["hp"]) or mp != int(p["mp"]):
		p["hp"] = hp
		p["mp"] = mp
		_push_stats(peer, p)


# Tod durch einen Statuseffekt (buffs.gd): Spieler / Monster (Belohnung an den Zaubernden, wenn er da ist)
func player_killed(p: Dictionary) -> void:
	_player_dies(_peer_of(p), p)

func monster_killed(src_id: int, map_name: String, o: Dictionary) -> void:
	var nm = world.npc_maps.get(map_name)
	if nm == null or not nm.objects.has(int(o["id"])):
		return
	var now = Time.get_ticks_msec() / 1000.0
	var p = _player_by_id(src_id)
	if p != null and p["map"] == map_name:
		_monster_dies(_peer_of(p), p, nm, o, now)
		return
	if buffs != null:
		buffs.forget(o)
	nm.kill(int(o["id"]), now)
	for other in world.players.values():
		if int(other.get("attack", {}).get("id", 0)) == int(o["id"]):
			stop(other)


# ====================================================
# HILFEN
# ====================================================
func _player_by_id(id: int):
	for p in world.players.values():
		if int(p["id"]) == id:
			return p
	return null

func _peer_of(p: Dictionary) -> int:
	for peer in world.players:
		if world.players[peer] == p:
			return peer
	return 0

func _push_stats(peer: int, p: Dictionary) -> void:
	if quests != null:
		net.push(peer, "stats", quests.stats_of(p))

# Meldung an alle Spieler derselben Map, die den Ort sehen
func _to_viewers(map_name: String, pos: Vector3, what: String, data: Dictionary) -> void:
	for peer in world.players:
		var o = world.players[peer]
		if o["map"] == map_name and o["pos"].distance_to(pos) <= Proto.VIEW_RANGE:
			net.push(peer, what, data)
