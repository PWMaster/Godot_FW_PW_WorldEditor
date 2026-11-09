extends RefCounted

# ====================================================
# NPCs und Monster einer Map auf dem Server (Fahrplan Schritt 7), vereinfacht nach dem
# npcgenerator / template_loader des gs:
# Daten (Plugin Server/): data/<Ordner>/npcgen.data (npcgen.gd), npc_templates.json (Werte der
# Vorlagen aus der elements.data des Servers), data/<Ordner>/terrain.cfg + map/<n>.hmap
# (heightmap.gd; fehlen sie, bleibt die Höhe des Gebiets).
# Erzeugt werden die Gebiete, deren Steuerung von Anfang an aktiv ist (ohne Steuerung oder
# "aktiv"); Gebiete, die an ein anderes angehängt sind, liefern diesem nur weitere Bereiche.
# Je Eintrag "Anzahl" Figuren, jede mit eigener Objekt-ID (ab Proto.NPC_ID_BASE, server-weit):
#   Ort    zufällig im Bereich (bei mehreren Bereichen einer davon); Gebiet auf dem Terrain:
#          Höhe = Terrain + Abstand zum Terrain (der gs nimmt dafür die movemap), Box-Gebiet:
#          zufällige Höhe in der Box, mindestens das Terrain
#   Blick  Bereich ohne Ausdehnung: Richtung des Gebiets, sonst zufällig
#   Stufe  level[i] mit Wahrscheinlichkeit level_probability[i] (Monster; NPCs vom Quell-Monster)
# Monster und NPCs mit patroll_mode, Gehtempo und Geburtsort auf dem Terrain laufen umher, solange
# ein Spieler in der Nähe ist (der gs schläft ohne Spieler ebenso): alle WANDER_MIN - WANDER_MAX s
# ein Gang zu einem Punkt bis WANDER_RANGE m um den Geburtsort, höchstens WANDER_TIME s lang
# (ai_rest_task / session_npc_cruise). Pfade aus path.sev fehlen noch.
# Tod (kill): Respawn nach dwRefresh des Eintrags, sonst der Vorlage (1 s - 30 Tage), nur bei
# Gebieten mit "auto_revive"; neu an zufälliger Stelle mit neuer ID.
# Sichtgitter: Zellen zu CELL m; visible() liefert die IDs im Umkreis.
# Gestartete Gänge (moves) und Tode (died) sammelt die Map bis world.gd sie verteilt hat.
# Im Kampf (combat.gd setzt fight, target, to) läuft ein Monster nicht umher.
# Leben / Mana wie npc_template::BuildBaseProp (stats.gd); wählbar (can_selected, Tab:
# can_select_by_tab) nach der Vorlage, bei NPCs nach der NPC-Vorlage (Tab nie).
# Sammelpunkte (Schritt 10b): Sammelgebiete der npcgen (res_areas) mit init_gen und aktiver Steuerung,
# Vorlagen in mine_templates (inventory.gd mines); je Eintrag "Anzahl" Punkte, zufällig im Gebiet,
# Höhe = Terrain + Höhe des Eintrags, Ausrichtung wie gmatter: Achse aus dir[0] / dir[1] (je 256 =
# 2 Pi), Drehung rad um sie. Objekte mit mine = true, Stufe 0, wählbar, nicht mit Tab. harvest():
# verschwindet (nicht perm), Respawn nach refresh des Eintrags (sonst MINE_REFRESH s) bei auto_revive;
# lock / unlock / busy: wer gerade sammelt.
# ====================================================

const Proto = preload("../common/protocol.gd")
const Stats = preload("stats.gd")
const CELL = 64.0
const WANDER_RANGE = 8.0
const WANDER_TIME = 8.0
const WANDER_MIN = 8.0
const WANDER_MAX = 24.0
const ON_TERRAIN = 0.5 # Geburtsort höchstens so weit über dem Terrain: darf umherlaufen
const MIN_WALK = 0.05 # m/s, langsamer = steht
const REFRESH_MAX = 2592000
const POINT = 0.001 # Bereich ohne Ausdehnung
const MINE_REFRESH = 30

var map_name = ""
var folder = ""
var terrain = null # heightmap.gd oder null
var objects = {} # ID -> Figur (siehe _spawn)
var cells = {} # Vector2i -> {ID: true}
var moves: Array = [] # IDs, die seit dem letzten Verteilen losgelaufen sind
var died: Array = [] # IDs, die seit dem letzten Verteilen gestorben sind
var counts = {"monsters": 0, "npcs": 0, "mines": 0, "areas": 0, "events": 0, "unknown": 0}
var mine_templates = {} # Sammelpunkt-Vorlagen (inventory.gd mines), vor load_spawns setzen
var unknown = {} # Vorlagen-IDs ohne Werte
var _templates: Dictionary
var _ids: Dictionary # {"next": ...} server-weit geteilt
var _areas: Array = []
var _respawns: Array = [] # [Zeit, Gebiet, Eintrag] bzw. [Zeit, Sammelgebiet, Eintrag, true]
var _res: Array = [] # aktive Sammelgebiete
var _rng = RandomNumberGenerator.new()


# templates: npc_templates.json, ids: gemeinsamer Zähler {"next": ID}
func _init(p_map: String, p_templates: Dictionary, p_ids: Dictionary) -> void:
	map_name = p_map
	_templates = p_templates
	_ids = p_ids

# npcgen (npcgen.gd read()) laden und alles von Anfang an Aktive erzeugen -> "" oder Fehlertext
func load_spawns(data: Dictionary, p_folder: String, p_terrain, now: float, seed_value: int = 0) -> String:
	folder = p_folder
	terrain = p_terrain
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	var active = {}
	for c in data["controllers"]:
		active[c["id"]] = c["active"]
	var by_export = {}
	for a in data["areas"]:
		if a.get("export_id", 0) != 0:
			by_export[a["export_id"]] = a
	for a in data["areas"]:
		if a["attached"]:
			continue
		if a["ctrl"] != 0 and not active.get(a["ctrl"], true):
			counts["events"] += 1
			continue
		var regions = [a]
		for x in a["attach_ids"]:
			if by_export.has(x):
				regions.append(by_export[x])
		_areas.append({"area": a, "regions": regions})
	counts["areas"] = _areas.size()
	for ai in _areas.size():
		var a: Dictionary = _areas[ai]["area"]
		for gi in a["gens"].size():
			for n in a["gens"][gi]["num"]:
				_spawn(ai, gi, now)
	for r in data.get("res_areas", []):
		if r["attached"]:
			continue
		if (r["ctrl"] != 0 and not active.get(r["ctrl"], true)) or not r["init_gen"]:
			counts["events"] += 1
			continue
		_res.append(r)
		var ri = _res.size() - 1
		for ei in r["res"].size():
			var e: Dictionary = r["res"][ei]
			if not mine_templates.has(int(e["id"])):
				if not unknown.has(int(e["id"])):
					unknown[int(e["id"])] = true
					counts["unknown"] += 1
				continue
			for n in maxi(1, int(e["num"])):
				_spawn_mine(ri, ei)
	return ""

func monster_template(tid: int) -> Dictionary:
	return _templates["monsters"].get(str(tid), {})

func npc_template(tid: int) -> Dictionary:
	return _templates["npcs"].get(str(tid), {})

# Werte für Stufe, Größe, Tempo: das Monster selbst bzw. das Quell-Monster eines NPCs
func _base_template(tid: int, npc: bool) -> Dictionary:
	if npc:
		var n = npc_template(tid)
		return monster_template(int(n["monster"])) if not n.is_empty() else {}
	return monster_template(tid)


# ====================================================
# ERZEUGEN / TOD
# ====================================================
func _spawn(ai: int, gi: int, now: float) -> int:
	var ar: Dictionary = _areas[ai]
	var a: Dictionary = ar["area"]
	var g: Dictionary = a["gens"][gi]
	var tid = int(g["id"])
	var npc = a["npc_type"] == 1
	var base = _base_template(tid, npc)
	if base.is_empty() or (npc and npc_template(tid).is_empty()):
		if not unknown.has(tid):
			unknown[tid] = true
			counts["unknown"] += 1
		return 0
	var region: Dictionary = ar["regions"][_rng.randi_range(0, ar["regions"].size() - 1)]
	var ext: Vector3 = region["ext"]
	var pos: Vector3 = region["pos"]
	var on_terrain = region["type"] == 0
	var point = ext.length() < POINT
	if not point:
		pos.x += _rng.randf_range(-0.5, 0.5) * ext.x
		pos.z += _rng.randf_range(-0.5, 0.5) * ext.z
		if not on_terrain:
			pos.y += _rng.randf_range(-0.5, 0.5) * ext.y
	if terrain != null:
		var h = terrain.height(pos.x, pos.z)
		pos.y = (h if on_terrain else maxf(pos.y, h)) + float(g["offset_trn"])
	var dir = _rng.randf_range(-PI, PI)
	var d: Vector3 = region["dir"]
	if point and Vector2(d.x, d.z).length() > POINT:
		dir = atan2(d.x, d.z)
	var id = int(_ids["next"])
	_ids["next"] = id + 1
	var walk = float(base.get("walk", 0.0))
	var level = _level(base)
	var hp_mp = Stats.monster_hp_mp(base, level)
	var own = npc_template(tid) if npc else base
	var o = {"id": id, "tid": tid, "npc": npc, "area": ai, "gen": gi, "home": pos, "pos": pos, "dir": dir,
		"level": level, "walk": walk, "to": null, "speed": 0.0, "cell": _cell(pos),
		"wander": int(base.get("patrol", 0)) != 0 and walk >= MIN_WALK and terrain != null and on_terrain,
		"next_wander": now + _rng.randf_range(WANDER_MIN, WANDER_MAX),
		"hp": hp_mp[0], "max_hp": hp_mp[0], "mp": hp_mp[1], "max_mp": hp_mp[1],
		"select": int(own.get("select", 1)) != 0, "tab": not npc and int(own.get("tab", 1)) != 0}
	objects[id] = o
	_cell_add(id, o["cell"])
	counts["npcs" if npc else "monsters"] += 1
	return id

func _spawn_mine(ri: int, ei: int) -> int:
	var r: Dictionary = _res[ri]
	var e: Dictionary = r["res"][ei]
	var pos: Vector3 = r["pos"]
	if r["ext_x"] > POINT or r["ext_z"] > POINT:
		pos.x += _rng.randf_range(-0.5, 0.5) * r["ext_x"]
		pos.z += _rng.randf_range(-0.5, 0.5) * r["ext_z"]
	if terrain != null:
		pos.y = terrain.height(pos.x, pos.z) + float(e["height"])
	var id = int(_ids["next"])
	_ids["next"] = id + 1
	var o = {"id": id, "tid": int(e["id"]), "npc": false, "mine": true, "res": ri, "gen": ei, "home": pos, "pos": pos,
		"dir": mine_dir(r["dir"][0], r["dir"][1], r["rad"]), "level": 0, "walk": 0.0, "to": null, "speed": 0.0,
		"cell": _cell(pos), "wander": false, "next_wander": 0.0, "hp": 1, "max_hp": 1, "mp": 0, "max_mp": 0,
		"select": true, "tab": false, "locks": {}}
	objects[id] = o
	_cell_add(id, o["cell"])
	counts["mines"] += 1
	return id

# Blickrichtung (Drehung um y) eines Sammelpunkts: Achse (sin(dir1) cos(dir0), cos(dir1), sin(dir1) sin(dir0)),
# Winkel rad, alles in 256tel von 2 Pi; Richtung = gedrehte z-Achse
static func mine_dir(d0: int, d1: int, rad: int) -> float:
	var e = PI / 128.0
	var axis = Vector3(sin(d1 * e) * cos(d0 * e), cos(d1 * e), sin(d1 * e) * sin(d0 * e))
	if axis.length() < POINT or rad == 0:
		return 0.0
	var f = Basis(Quaternion(axis.normalized(), rad * e)) * Vector3(0, 0, 1)
	return atan2(f.x, f.z)

# Sammelpunkt abgebaut: verschwindet, Respawn bei auto_revive
func harvest(id: int, now: float) -> void:
	var o = objects.get(id)
	if o == null or not o.get("mine", false):
		return
	_remove(id)
	died.append(id)
	var r: Dictionary = _res[o["res"]]
	if r["auto_revive"]:
		var t = int(r["res"][o["gen"]]["refresh"])
		_respawns.append([now + float(clampi(t if t > 0 else MINE_REFRESH, 1, REFRESH_MAX)), o["res"], o["gen"], true])

func lock(id: int, player_id: int) -> void:
	var o = objects.get(id)
	if o != null and o.has("locks"):
		o["locks"][player_id] = true

func unlock(id: int, player_id: int) -> void:
	var o = objects.get(id)
	if o != null and o.has("locks"):
		o["locks"].erase(player_id)

func busy(id: int) -> bool:
	var o = objects.get(id)
	return o != null and not o.get("locks", {}).is_empty()

# Stufe nach level_probability (abase::RandSelect), sonst die erste
func _level(t: Dictionary) -> int:
	var levels: Array = t.get("level", [1])
	var p: Array = t.get("level_p", [1.0])
	var r = _rng.randf()
	for i in mini(levels.size(), p.size()):
		r -= float(p[i])
		if r < 0.0:
			return int(levels[i])
	return int(levels[0]) if not levels.is_empty() else 1

# Figur stirbt: verschwindet, Respawn nach der Zeit des Eintrags (nur "auto_revive")
func kill(id: int, now: float) -> bool:
	var o = objects.get(id)
	if o == null:
		return false
	_remove(id)
	died.append(id)
	var a: Dictionary = _areas[o["area"]]["area"]
	if a["auto_revive"]:
		_respawns.append([now + respawn_time(o), o["area"], o["gen"]])
	return true

func respawn_time(o: Dictionary) -> float:
	var t = int(_areas[o["area"]]["area"]["gens"][o["gen"]]["refresh"])
	if t == 0:
		t = int(_base_template(o["tid"], o["npc"]).get("refresh", 0))
	return float(clampi(t, 1, REFRESH_MAX))

func _remove(id: int) -> void:
	var o = objects.get(id)
	if o == null:
		return
	_cell_del(id, o["cell"])
	objects.erase(id)
	counts["mines" if o.get("mine", false) else ("npcs" if o["npc"] else "monsters")] -= 1
	moves.erase(id)


# ====================================================
# TAKT
# ====================================================
# now in Sekunden; near = Positionen der Spieler auf dieser Map (nur dort wird gelaufen)
func tick(now: float, dt: float, near: Array) -> void:
	var i = 0
	while i < _respawns.size():
		if _respawns[i][0] <= now:
			if _respawns[i].size() > 3:
				_spawn_mine(_respawns[i][1], _respawns[i][2])
			else:
				_spawn(_respawns[i][1], _respawns[i][2], now)
			_respawns.remove_at(i)
		else:
			i += 1
	if near.is_empty():
		return
	var awake = {}
	var r = int(ceil(Proto.VIEW_RANGE / CELL))
	for p in near:
		var c = _cell(p)
		for x in range(c.x - r, c.x + r + 1):
			for z in range(c.y - r, c.y + r + 1):
				awake[Vector2i(x, z)] = true
	var ids = []
	for c in awake:
		if cells.has(c):
			ids.append_array(cells[c].keys())
	for id in ids:
		var o = objects[id]
		if o["to"] != null:
			_step(o, dt)
		elif o["wander"] and not o.get("fight", false) and now >= o["next_wander"]:
			_start_wander(o, now)

func _start_wander(o: Dictionary, now: float) -> void:
	o["next_wander"] = now + _rng.randf_range(WANDER_MIN, WANDER_MAX)
	var home: Vector3 = o["home"]
	var to = Vector3(home.x + _rng.randf_range(-WANDER_RANGE, WANDER_RANGE), 0.0, home.z + _rng.randf_range(-WANDER_RANGE, WANDER_RANGE))
	var flat = Vector2(to.x - o["pos"].x, to.z - o["pos"].z)
	var max_len = o["walk"] * WANDER_TIME
	if flat.length() > max_len:
		flat = flat.normalized() * max_len
		to.x = o["pos"].x + flat.x
		to.z = o["pos"].z + flat.y
	if flat.length() < 0.5:
		return
	to.y = terrain.height(to.x, to.z) + (home.y - terrain.height(home.x, home.z))
	o["to"] = to
	o["speed"] = o["walk"]
	o["dir"] = atan2(flat.x, flat.y)
	o["next_wander"] += flat.length() / o["walk"]
	moves.append(o["id"])

func _step(o: Dictionary, dt: float) -> void:
	var pos: Vector3 = o["pos"]
	var to: Vector3 = o["to"]
	var flat = Vector2(to.x - pos.x, to.z - pos.z)
	var step = o["speed"] * dt
	if flat.length() <= step:
		pos = to
		o["to"] = null
		o["speed"] = 0.0
	else:
		flat = flat.normalized() * step
		pos.x += flat.x
		pos.z += flat.y
		pos.y = terrain.height(pos.x, pos.z) + (o["home"].y - terrain.height(o["home"].x, o["home"].z))
	o["pos"] = pos
	var c = _cell(pos)
	if c != o["cell"]:
		_cell_del(o["id"], o["cell"])
		_cell_add(o["id"], c)
		o["cell"] = c


# ====================================================
# SICHT
# ====================================================
# IDs der Figuren im Umkreis radius um pos
func visible(pos: Vector3, radius: float) -> Array:
	var out = []
	var c = _cell(pos)
	var r = int(ceil(radius / CELL))
	var r2 = radius * radius
	for x in range(c.x - r, c.x + r + 1):
		for z in range(c.y - r, c.y + r + 1):
			var cell = cells.get(Vector2i(x, z))
			if cell == null:
				continue
			for id in cell:
				var p: Vector3 = objects[id]["pos"]
				if (p.x - pos.x) * (p.x - pos.x) + (p.z - pos.z) * (p.z - pos.z) <= r2:
					out.append(id)
	return out

# Eintrag für npc_enter: [id, Vorlage, x, y, z, Richtung, Stufe, Gang [x, y, z, Tempo] oder []]
func entry(id: int) -> Array:
	var o = objects[id]
	var p: Vector3 = o["pos"]
	return [id, o["tid"], p.x, p.y, p.z, o["dir"], o["level"], move_of(o)]

# Ziel-Info: {id, tid, npc, mine, level, hp, max_hp, mp, max_mp}; {} wenn es die Figur nicht gibt
func info(id: int) -> Dictionary:
	var o = objects.get(id)
	if o == null:
		return {}
	return {"id": id, "tid": o["tid"], "npc": o["npc"], "mine": o.get("mine", false), "level": o["level"], "hp": o["hp"],
		"max_hp": o["max_hp"], "mp": o["mp"], "max_mp": o["max_mp"]}

func move_of(o: Dictionary) -> Array:
	if o["to"] == null:
		return []
	var t: Vector3 = o["to"]
	return [t.x, t.y, t.z, o["speed"]]

func _cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.z / CELL))

func _cell_add(id: int, c: Vector2i) -> void:
	if not cells.has(c):
		cells[c] = {}
	cells[c][id] = true

func _cell_del(id: int, c: Vector2i) -> void:
	var cell = cells.get(c)
	if cell != null:
		cell.erase(id)
		if cell.is_empty():
			cells.erase(c)
