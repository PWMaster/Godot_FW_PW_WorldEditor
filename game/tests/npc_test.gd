extends SceneTree

# ====================================================
# Test der NPCs und Monster des Servers (server/npcs.gd) ohne Netz, Map s9 aus dem Plugin
# (Server/data/s9: npcgen.data, terrain.cfg, map/1.hmap; Server/npc_templates.json):
#   godot --headless --path <Projekt> -s res://game/tests/npc_test.gd
# Prüft: Anzahl wie die aktiven Gebiete, jede Figur in ihrem Gebiet und auf dem Terrain, Lady Vestry
# (erste Menschen-Quest) an ihrem Platz, Stufen aus der Vorlage, Sichtgitter = Abstandsrechnung,
# Umherlaufen nur mit Spieler in der Nähe und nur um den Geburtsort, Tod und Respawn nach der Zeit
# mit neuer ID, gleicher Zufallsstart -> gleiche Welt.
# Ende: "NPC-TEST OK" (Exit 0) oder "NPC-TEST FEHLER" (Exit 1).
# ====================================================

const Proto = preload("../common/protocol.gd")
const Npcs = preload("../server/npcs.gd")
const PLUGIN_SERVER = "res://addons/PWE-Manager/Server/"
const START = Vector3(-144.556, 101.998, 34.636) # Start der Menschen in s9
const VESTRY = 14429 # Lady Vestry, erste Quest
const SEED = 4711
const FAR = 260.0 # m: weiter als die wachen Zellen um den Spieler (Sicht 120 m, Zellen zu 64 m)

var checks = 0
var failures = 0
var templates: Dictionary
var data: Dictionary
var terrain


func _initialize() -> void:
	var spawn_builder = load(PLUGIN_SERVER + "spawn_builder.gd")
	templates = JSON.parse_string(FileAccess.get_file_as_string(PLUGIN_SERVER + "npc_templates.json"))
	data = load(PLUGIN_SERVER + "npcgen.gd").new().read(spawn_builder.npcgen_path("s9"))
	terrain = load(PLUGIN_SERVER + "heightmap.gd").new()
	var err = terrain.load_dir(spawn_builder.server_dir().path_join("data/s9"))
	_check("Höhen von s9 (%s)" % err, err == "")
	_check("Start liegt auf den Höhen (%.3f)" % terrain.height(START.x, START.z), absf(terrain.height(START.x, START.z) - START.y) < 0.01)
	var nm = _new_map()
	_spawns(nm)
	_view(nm)
	_wander(nm)
	_respawn(nm)
	var again = _new_map()
	var same = true
	for id in nm.objects:
		if id >= Proto.NPC_ID_BASE + 50:
			continue
		var o = again.objects.get(id)
		same = same and o != null and o["tid"] == nm.objects[id]["tid"] and o["home"].is_equal_approx(nm.objects[id]["home"])
	_check("gleicher Zufallsstart -> gleiche Figuren", same)
	if failures == 0:
		print("NPC-TEST OK (%d Prüfungen)" % checks)
	else:
		print("NPC-TEST FEHLER: %d von %d Prüfungen" % [failures, checks])
	quit(0 if failures == 0 else 1)

func _new_map():
	var nm = Npcs.new("s9", templates, {"next": Proto.NPC_ID_BASE})
	nm.load_spawns(data, "s9", terrain, 0.0, SEED)
	return nm

# Anzahl, Ort, Höhe, Stufen, Lady Vestry
func _spawns(nm) -> void:
	var expected = 0
	for ar in nm._areas:
		for g in ar["area"]["gens"]:
			if not nm.unknown.has(int(g["id"])):
				expected += g["num"]
	var total = nm.counts["monsters"] + nm.counts["npcs"]
	_check("s9: %d Monster, %d NPCs aus %d Gebieten (%d Ereignis-Gebiete, %d Vorlagen unbekannt)" % [nm.counts["monsters"],
		nm.counts["npcs"], nm.counts["areas"], nm.counts["events"], nm.counts["unknown"]],
		total == expected and total == nm.objects.size() and nm.counts["monsters"] > 300 and nm.counts["npcs"] > 50)
	var outside = []
	var levels_bad = []
	for id in nm.objects:
		var o = nm.objects[id]
		var ok = false
		for region in nm._areas[o["area"]]["regions"]:
			var half: Vector3 = region["ext"] * 0.5 + Vector3.ONE * 0.01
			var d: Vector3 = (o["pos"] - region["pos"]).abs()
			var h = terrain.height(o["pos"].x, o["pos"].z)
			var off = float(nm._areas[o["area"]]["area"]["gens"][o["gen"]]["offset_trn"])
			var y_ok = absf(o["pos"].y - h - off) < 0.01 if region["type"] == 0 else o["pos"].y >= h + off - 0.01
			ok = ok or (d.x <= half.x and d.z <= half.z and y_ok)
		if not ok:
			outside.append(id)
		if not o["npc"] and not o["level"] in nm.monster_template(o["tid"])["level"].map(func(x): return int(x)):
			levels_bad.append(id)
	_check("alle im Gebiet, Höhe Terrain + Abstand (%d daneben)" % outside.size(), outside.is_empty())
	_check("Monster-Stufen aus der Vorlage (%d falsch)" % levels_bad.size(), levels_bad.is_empty())
	var vestry = null
	for o in nm.objects.values():
		if o["tid"] == VESTRY:
			vestry = o
	var area_pos = Vector3.ZERO
	for a in data["areas"]:
		for g in a["gens"]:
			if g["id"] == VESTRY:
				area_pos = a["pos"]
	_check("Lady Vestry an ihrem Platz (%s, %.0f m vom Start)" % [vestry["pos"] if vestry else "fehlt", vestry["pos"].distance_to(START) if vestry else -1.0],
		vestry != null and vestry["pos"].distance_to(area_pos) < 0.01)

# Sichtgitter gegen Abstandsrechnung
func _view(nm) -> void:
	var seen = nm.visible(START, Proto.VIEW_RANGE)
	var brute = []
	for id in nm.objects:
		var p: Vector3 = nm.objects[id]["pos"]
		if Vector2(p.x - START.x, p.z - START.z).length() <= Proto.VIEW_RANGE:
			brute.append(id)
	seen.sort()
	brute.sort()
	var npcs = seen.filter(func(id): return nm.objects[id]["npc"]).size()
	_check("Sicht vom Start: %d NPCs, %d Monster, wie Abstandsrechnung" % [npcs, seen.size() - npcs], seen == brute and npcs > 0)
	var e = nm.entry(seen[0]) if not seen.is_empty() else []
	_check("Eintrag npc_enter [id, Vorlage, x, y, z, Richtung, Stufe, Gang]", e.size() == 8 and e[0] == seen[0] and e[7] is Array)

# Umherlaufen: Spieler bei einem Umherläufer, 60 s
func _wander(nm) -> void:
	var walker = null
	var best = INF
	for o in nm.objects.values():
		if o["wander"] and o["pos"].distance_to(START) < best:
			best = o["pos"].distance_to(START)
			walker = o
	_check("Umherläufer vorhanden (nächster %.0f m vom Start)" % best, walker != null)
	if walker == null:
		return
	var player: Vector3 = walker["home"]
	var far = []
	for o in nm.objects.values():
		if o["wander"] and Vector2(o["pos"].x - player.x, o["pos"].z - player.z).length() > FAR:
			far.append([o["id"], o["pos"]])
	var t = 0.0
	var started = 0
	var max_off = 0.0
	var off_ground = 0
	while t < 60.0:
		t += 0.1
		nm.tick(t, 0.1, [player])
		started += nm.moves.size()
		nm.moves.clear()
		for o in nm.objects.values():
			if not o["wander"] or o["pos"].distance_to(player) > Proto.VIEW_RANGE:
				continue
			var home: Vector3 = o["home"]
			max_off = maxf(max_off, Vector2(o["pos"].x - home.x, o["pos"].z - home.z).length())
			var off = home.y - terrain.height(home.x, home.z)
			if absf(o["pos"].y - terrain.height(o["pos"].x, o["pos"].z) - off) > 0.01:
				off_ground += 1
	_check("in 60 s %d Gänge gestartet, höchstens %.1f m vom Geburtsort" % [started, max_off],
		started > 0 and max_off > 0.5 and max_off <= Npcs.WANDER_RANGE * sqrt(2.0) + 0.01)
	_check("beim Laufen auf dem Terrain (%d daneben)" % off_ground, off_ground == 0)
	_check("ohne Spieler in der Nähe läuft niemand (%d geprüft)" % far.size(),
		not far.is_empty() and far.all(func(f): return nm.objects.has(f[0]) and nm.objects[f[0]]["pos"] == f[1]))

# Tod und Respawn
func _respawn(nm) -> void:
	var victim = null
	for o in nm.objects.values():
		if not o["npc"] and nm._areas[o["area"]]["area"]["auto_revive"]:
			victim = o
			break
	if victim == null:
		_check("Monster mit Respawn vorhanden", false)
		return
	var n = nm.counts["monsters"]
	var wait = nm.respawn_time(victim)
	var t = 100.0
	nm.kill(victim["id"], t)
	_check("Tod: weg, gemeldet (%s, Respawn nach %d s)" % [nm.monster_template(victim["tid"])["name"], wait],
		not nm.objects.has(victim["id"]) and victim["id"] in nm.died and nm.counts["monsters"] == n - 1)
	nm.died.clear()
	nm.tick(t + wait - 0.5, 0.1, [])
	var early = nm.counts["monsters"] == n - 1
	nm.tick(t + wait + 0.1, 0.1, [])
	var back = null
	for o in nm.objects.values():
		if o["area"] == victim["area"] and o["gen"] == victim["gen"] and o["id"] > victim["id"]:
			back = o
	_check("Respawn nach der Zeit mit neuer ID", early and back != null and nm.counts["monsters"] == n)

func _check(what: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("NPC-TEST: ", "ok      " if ok else "FEHLER  ", what)
