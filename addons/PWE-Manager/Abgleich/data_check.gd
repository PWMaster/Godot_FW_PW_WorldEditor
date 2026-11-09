@tool
extends RefCounted

# ====================================================
# Abgleich Client <-> Server: passen die Server-Daten (Stock-PWE-Server) zum Client
# (Stock-PWE-Client)? Ein neuerer Client enthält meist alles, was der Server braucht; ist der
# Server neuer, führen seine Quests auf Maps und zu NPCs, die der Client nicht kennt.
# Geprüft (je ein Anteil in %; der "Match" ist ihr nach WEIGHTS gewichtetes geometrisches Mittel):
#   Versionen  elements.data, tasks.data (Version, Anzahl, Exportzeit): welche Seite ist neuer
#   Quests     IDs der Quests oberster Ebene (je Eintrag der tasks.dataN zuerst m_ID) des Servers,
#              die der Client auch hat
#   Maps       Welten aus gs.conf ([Map_*], base_path) mit Höhenkarte (config/<Ordner>/terrain.cfg +
#              map/<n>.hmap), zu denen es eine Client-Map mit gleichem Gelände gibt (Höhen aus
#              maps/<Map>/<Map>.trn2 + .t2bk; Anteil gleicher Höhen ab MATCH_MIN), gewichtet nach
#              Spawn-Gebieten
#   Vorlagen   Monster / NPCs der Server-Spawns (npcgen.data aller Welten), die der Client unter
#              derselben ID mit derselben Art (MONSTER_ESSENCE / NPC_ESSENCE) kennt
#   NPC-Höhen  Spawn-Gebiete der gefundenen Maps gegen das Gelände des Clients: Gebiet auf dem Terrain
#              höchstens TERRAIN_TOLERANCE daneben, Box-Gebiet höchstens BELOW_TOLERANCE darunter
# Gelesen über angelica_files.gd (Client auch aus den .pck), nichts wird geschrieben.
# Aufruf: run(client, server, progress) -> Ergebnis; report_text(Ergebnis) -> Bericht.
# ====================================================

const Files = preload("../Data/angelica_files.gd")
const Elements = preload("../Data/angelica_elements.gd")
const NpcGen = preload("../Server/npcgen.gd")
const Heightmap = preload("../Server/heightmap.gd")
const Terrain = preload("../MAP/angelica_terrain.gd")
const Importer = preload("../ECM/ecm_importer.gd")
const TASK_INFO_MAGIC = 0x03958276
const TASK_PACK_MAGIC = 0x02003304
const MATCH_MIN = 0.9 # Anteil gleicher Höhen: dasselbe Gelände
const PREFILTER = 0.6 # Vorauswahl mit wenigen Stichproben
const HEIGHT_EQUAL = 0.5 # m
const SIGNATURE = 256 # Stichproben für die Vorauswahl
const SAMPLES = 8100 # Stichproben für den genauen Vergleich
const TERRAIN_TOLERANCE = 2.0 # m
const BELOW_TOLERANCE = 1.0 # m
const WEIGHTS = {"maps": 0.35, "quests": 0.25, "templates": 0.2, "heights": 0.2}
const PART_NAMES = {"maps": "Maps", "quests": "Quests", "templates": "Vorlagen", "heights": "NPC-Höhen"}
const MIN_PART = 0.001 # für das geometrische Mittel (0 % zählt wie 0,1 %)
const WORST = 3 # größte Abweichungen je Map im Bericht

var client_root = ""
var server_root = ""
var gamed_dir = ""
var config_dir = ""
var result = {}
var _cf # angelica_files.gd des Clients
var _sf # des Servers
var _progress: Callable
var _worlds: Array = [] # [{tag, folder, type, dir, areas, npcgen, hmaps}]


# Abgleich ausführen; progress(text, anteil 0 - 1) optional (aus einem Thread: call_deferred)
func run(p_client: String, p_server: String, p_progress: Callable = Callable()) -> Dictionary:
	var t0 = Time.get_ticks_msec()
	client_root = p_client.trim_suffix("/")
	server_root = p_server.trim_suffix("/")
	_progress = p_progress
	_cf = Files.new(client_root)
	_sf = Files.new(server_root)
	result = {"client": client_root, "server": server_root, "errors": [], "score": -1.0}
	if not _cf.dir_exists(client_root):
		result["errors"].append("Client-Ordner fehlt: " + client_root)
	if not _find_server():
		result["errors"].append("gs.conf nicht gefunden unter " + server_root)
	if not result["errors"].is_empty():
		result["verdict"] = "Abgleich nicht möglich"
		return result
	result["gamed"] = gamed_dir
	result["config"] = config_dir
	_step("Versionen", 0.02)
	result["versions"] = _versions()
	_step("Quests", 0.05)
	result["quests"] = _quests()
	_step("Welten und Spawns des Servers", 0.07)
	_read_worlds()
	_step("Gelände des Clients", 0.1)
	result["maps"] = _maps()
	_step("Vorlagen", 0.6)
	result["templates"] = _templates()
	_step("NPC-Höhen", 0.85)
	result["heights"] = _heights()
	_score()
	result["seconds"] = (Time.get_ticks_msec() - t0) / 1000.0
	_step("fertig", 1.0)
	return result

func _step(text: String, f: float) -> void:
	if _progress.is_valid():
		_progress.call(text, f)


# ====================================================
# SERVER FINDEN, gs.conf
# ====================================================
func _find_server() -> bool:
	for rel in ["", "server-fw/gamed", "gamed", "server-fw"]:
		var dir = server_root if rel == "" else server_root.path_join(rel)
		if _sf.file_exists(dir.path_join("gs.conf")):
			gamed_dir = dir
			break
	if gamed_dir == "":
		return false
	var conf = _ini(gamed_dir.path_join("gs.conf"))
	var root: String = conf.get("Template", {}).get("Root", "")
	config_dir = ""
	if root != "":
		var candidate = server_root.path_join(root.trim_prefix("/").trim_suffix("/"))
		if _sf.dir_exists(candidate):
			config_dir = candidate
	if config_dir == "":
		config_dir = gamed_dir.path_join("config")
	result["gs_conf"] = conf
	return _sf.dir_exists(config_dir)

# Schlüssel = Wert ohne Abschnitte (terrain.cfg)
static func _ini_text(text: String) -> Dictionary:
	var out = {}
	for line in text.replace("\r", "").split("\n"):
		var eq = line.find("=")
		if eq > 0:
			out[line.substr(0, eq).strip_edges()] = line.substr(eq + 1).strip_edges()
	return out

# INI-Datei (GBK oder UTF-8) -> {Abschnitt: {Schlüssel: Wert}}; Kommentare ab # bzw. ; am Zeilenanfang
func _ini(path: String) -> Dictionary:
	var out = {}
	var section = ""
	for line in _sf.decode(_sf.get_bytes(path)).replace("\r", "").split("\n"):
		var l = line.strip_edges()
		if l == "" or l.begins_with("#") or l.begins_with(";"):
			continue
		if l.begins_with("[") and l.ends_with("]"):
			section = l.substr(1, l.length() - 2)
			out[section] = {}
			continue
		var eq = l.find("=")
		if eq > 0 and section != "":
			out[section][l.substr(0, eq).strip_edges()] = l.substr(eq + 1).strip_edges()
	return out


# ====================================================
# VERSIONEN
# ====================================================
func _versions() -> Dictionary:
	var c = {"elements": _elements_version(_client_elements()), "tasks": _task_info(_client_file("tasks.data"))}
	var s = {"elements": _elements_version(config_dir.path_join("elements.data")), "tasks": _task_info(config_dir.path_join("tasks.data"))}
	var newer = ""
	var why = ""
	var ct = c["tasks"].get("export", 0)
	var st = s["tasks"].get("export", 0)
	if ct > 0 and st > 0 and ct != st:
		newer = "client" if ct > st else "server"
		why = "Quests exportiert %s / %s" % [_date(ct), _date(st)]
	elif c["elements"] > 0 and s["elements"] > 0 and c["elements"] != s["elements"]:
		newer = "client" if c["elements"] > s["elements"] else "server"
		why = "elements.data 0x%x / 0x%x" % [c["elements"], s["elements"]]
	elif c["elements"] > 0 and c["elements"] == s["elements"]:
		newer = "gleich"
		why = "gleiche Versionen"
	return {"client": c, "server": s, "newer": newer, "why": why}

func _client_elements() -> String:
	var p = _cf.resolve("data/elements.data")
	return p if p != "" else Elements.locate(_cf)

# Datei in data/ des Clients (sonst in einem Sprachordner)
func _client_file(name: String) -> String:
	for base in ["data", "Deu/data", "Eng/data", "Franz/data", "resources/data"]:
		var p = _cf.resolve(base + "/" + name)
		if p != "":
			return p
	return ""

func _elements_version(path: String) -> int:
	var b = (_cf if path.begins_with(client_root) else _sf).get_bytes(path) if path != "" else PackedByteArray()
	return b.decode_u32(0) if b.size() >= 4 else 0

func _task_info(path: String) -> Dictionary:
	if path == "":
		return {}
	var b = (_cf if path.begins_with(client_root) else _sf).get_bytes(path)
	if b.size() < 20 or b.decode_u32(0) != TASK_INFO_MAGIC:
		return {}
	return {"path": path, "version": b.decode_u32(4), "count": b.decode_u32(8), "packs": b.decode_u32(12), "export": b.decode_u32(16)}

static func _date(unix: int) -> String:
	return Time.get_datetime_string_from_unix_time(unix, true).get_slice(" ", 0) if unix > 0 else "?"


# ====================================================
# QUESTS
# ====================================================
func _quests() -> Dictionary:
	var c = _quest_ids(result["versions"]["client"]["tasks"], _cf)
	var s = _quest_ids(result["versions"]["server"]["tasks"], _sf)
	var missing = []
	for id in s:
		if not c.has(id):
			missing.append(id)
	missing.sort()
	var extra = 0
	for id in c:
		if not s.has(id):
			extra += 1
	var out = {"server": s.size(), "client": c.size(), "common": s.size() - missing.size(), "missing": missing, "client_only": extra}
	out["score"] = float(out["common"]) / s.size() if not s.is_empty() else -1.0
	return out

# IDs der Quests oberster Ebene aus tasks.data1 ... N: je Teildatei Magic, Anzahl, Offsets; m_ID vorn
func _quest_ids(info: Dictionary, files) -> Dictionary:
	var ids = {}
	if info.is_empty():
		return ids
	for n in range(1, int(info["packs"]) + 1):
		var b = files.get_bytes(info["path"] + str(n))
		if b.size() < 8 or b.decode_u32(0) != TASK_PACK_MAGIC:
			continue
		var count = b.decode_u32(4)
		for i in count:
			var off = b.decode_u32(8 + 4 * i) if 8 + 4 * i + 4 <= b.size() else -1
			if off >= 0 and off + 4 <= b.size():
				ids[b.decode_u32(off)] = true
	return ids


# ====================================================
# WELTEN DES SERVERS
# ====================================================
func _read_worlds() -> void:
	_worlds = []
	var conf: Dictionary = result["gs_conf"]
	var seen = {}
	for section in conf:
		if not section.begins_with("Map_"):
			continue
		var folder: String = str(conf[section].get("base_path", "")).trim_suffix("/").strip_edges()
		if folder == "" or seen.has(folder.to_lower()):
			continue
		seen[folder.to_lower()] = true
		var dir = _sf.resolve(folder, config_dir)
		var w = {"tag": int(conf[section].get("tag", "-1")), "folder": folder, "type": int(conf[section].get("type", "0")),
			"dir": dir, "areas": [], "hmaps": []}
		if dir != "":
			var gen = _sf.resolve("npcgen.data", dir)
			if gen != "":
				var d = NpcGen.new().parse(_sf.get_bytes(gen), _sf)
				if not d.has("error"):
					w["areas"] = d["areas"]
			# so viele Teilkarten, wie terrain.cfg nennt (manche Ordner haben übrige .hmap)
			var cfg = _sf.resolve("terrain.cfg", dir)
			var parts = 0
			if cfg != "":
				var v = _ini_text(_sf.decode(_sf.get_bytes(cfg)))
				parts = int(v.get("nRow", "0")) * int(v.get("nCol", "0"))
			var n = 1
			while parts <= 0 or n <= parts:
				var h = _sf.resolve("map/%d.hmap" % n, dir)
				if h == "":
					break
				w["hmaps"].append(h)
				n += 1
			if parts > 0 and w["hmaps"].size() != parts:
				w["hmaps"] = []
		_worlds.append(w)
	_worlds.sort_custom(func(a, b): return a["tag"] < b["tag"])


# ====================================================
# MAPS (gleiches Gelände)
# ====================================================
# Client: Gelände jeder Map (maps/<Map>/<Map>.trn2 mit den Höhen der .t2bk, angelica_terrain.gd
# read_height_grid); Server: Höhenkarte der Welt (heightmap.gd). Bei gleicher Ausdehnung an
# SAMPLES Rasterpunkten verglichen (Vorauswahl mit SIGNATURE Punkten), gleich = unter HEIGHT_EQUAL.
func _maps() -> Dictionary:
	var client = _client_terrains()
	var worlds = []
	var matched_maps = {}
	var weight_all = 0.0
	var weight_ok = 0.0
	var count_ok = 0
	var count_all = 0
	var done = 0
	for w in _worlds:
		done += 1
		if w["hmaps"].is_empty():
			if not w["areas"].is_empty():
				worlds.append({"tag": w["tag"], "folder": w["folder"], "areas": w["areas"].size(), "map": "", "match": 0.0,
					"note": "keine Höhenkarte auf dem Server"})
			continue
		_step("Maps vergleichen (%s)" % w["folder"], 0.45 + 0.15 * done / maxf(1.0, _worlds.size()))
		var hm = Heightmap.new()
		var err = hm.load_dir(w["dir"])
		if err != "":
			worlds.append({"tag": w["tag"], "folder": w["folder"], "areas": w["areas"].size(), "map": "", "match": 0.0, "note": err})
			continue
		var best = ""
		var best_sim = 0.0
		for name in client:
			if not _same_extent(client[name], hm.bounds()):
				continue
			var sim = _compare(hm, client[name], SIGNATURE)
			if sim >= PREFILTER:
				sim = _compare(hm, client[name], SAMPLES)
			if sim > best_sim:
				best_sim = sim
				best = name
		var ok = best_sim >= MATCH_MIN
		var weight = maxf(1.0, w["areas"].size())
		weight_all += weight
		count_all += 1
		if ok:
			weight_ok += weight
			count_ok += 1
			matched_maps[best.to_lower()] = true
			w["client_map"] = best
			w["client_grid"] = client[best]
		worlds.append({"tag": w["tag"], "folder": w["folder"], "areas": w["areas"].size(), "map": best if ok else "",
			"match": best_sim, "note": "" if ok else ("ähnlichste: %s %.0f %%" % [best, best_sim * 100.0] if best != "" else "keine Client-Map gleicher Größe")})
	var client_only = []
	for name in client:
		if not matched_maps.has(name.to_lower()):
			client_only.append(name)
	client_only.sort()
	return {"worlds": worlds, "matched": count_ok, "total": count_all, "client_maps": client.size(), "client_only": client_only,
		"score": weight_ok / weight_all if weight_all > 0.0 else -1.0, "share": float(count_ok) / count_all if count_all > 0 else -1.0}

# Höhenraster aller Client-Maps mit Gelände: {Map: read_height_grid()}
func _client_terrains() -> Dictionary:
	var out = {}
	var maps_dir = _cf.resolve("maps")
	if maps_dir == "":
		return out
	var terrain = Terrain.new(Importer.new(client_root))
	var names = _cf.list_dir(maps_dir)["dirs"]
	for i in names.size():
		var m: String = names[i]
		_step("Gelände des Clients (%s)" % m, 0.1 + 0.35 * i / maxf(1.0, names.size()))
		var trn2 = _cf.resolve(m + "/" + m + ".trn2", maps_dir)
		if trn2 == "":
			continue
		var g = terrain.read_height_grid(trn2)
		if not g.has("error"):
			out[m] = g
	return out

# Gleiche Ausdehnung (bis 1 m) von Client-Raster und Server-Höhenkarte ([min x, min z, max x, max z])
static func _same_extent(g: Dictionary, b: Array) -> bool:
	var right = g["left"] + (g["cols"] - 1) * g["step"]
	var bottom = g["top"] - (g["rows"] - 1) * g["step"]
	return absf(g["left"] - b[0]) < 1.0 and absf(right - b[2]) < 1.0 and absf(g["top"] - b[3]) < 1.0 and absf(bottom - b[1]) < 1.0

# Anteil gleicher Höhen an etwa n Rasterpunkten der Server-Höhenkarte
static func _compare(hm, g: Dictionary, n: int) -> float:
	var b = hm.bounds()
	var k = maxi(2, int(sqrt(float(n))))
	var w = b[2] - b[0]
	var d = b[3] - b[1]
	var same = 0
	for i in k:
		var x = b[0] + roundf((i + 0.5) / k * w / hm.grid) * hm.grid
		for j in k:
			var z = b[3] - roundf((j + 0.5) / k * d / hm.grid) * hm.grid
			if absf(hm.height(x, z) - Terrain.grid_height(g, x, z)) < HEIGHT_EQUAL:
				same += 1
	return float(same) / (k * k)


# ====================================================
# VORLAGEN
# ====================================================
func _templates() -> Dictionary:
	var used = {} # Vorlage -> Anzahl in den Spawns
	for w in _worlds:
		for a in w["areas"]:
			for g in a["gens"]:
				if int(g["id"]) > 0:
					used[int(g["id"])] = used.get(int(g["id"]), 0) + int(g["num"])
	var se = Elements.new()
	var ce = Elements.new()
	var err = se.open(config_dir.path_join("elements.data"), _sf)
	var cpath = _client_elements()
	var cerr = ce.open(cpath, _cf) if cpath != "" else "elements.data des Clients fehlt"
	if err != "" or cerr != "":
		if err != "":
			result["errors"].append("Server: " + err)
		if cerr != "":
			result["errors"].append("Client: " + cerr)
		return {"score": -1.0, "used": used.size()}
	var known = 0
	var ok = 0
	var spawns_known = 0
	var spawns_ok = 0
	var unknown_server = 0
	var missing = []
	var ids = used.keys()
	ids.sort()
	for id in ids:
		var st = se.type_of(id)
		if st == "":
			unknown_server += 1
			continue
		known += 1
		spawns_known += used[id]
		var ct = ce.type_of(id)
		if ct == st:
			ok += 1
			spawns_ok += used[id]
		else:
			missing.append([id, st, ct, Elements.strip_codes(se.name_of(id))])
	se.close()
	ce.close()
	return {"used": used.size(), "known": known, "ok": ok, "unknown_server": unknown_server, "missing": missing,
		"score": float(ok) / known if known > 0 else -1.0, "spawn_score": float(spawns_ok) / spawns_known if spawns_known > 0 else -1.0}


# ====================================================
# NPC-HÖHEN
# ====================================================
# Spawn-Gebiete der gefundenen Maps gegen das Gelände des Clients
func _heights() -> Dictionary:
	var worlds = []
	var checked = 0
	var ok = 0
	for w in _worlds:
		if not w.has("client_grid") or w["areas"].is_empty():
			continue
		var g: Dictionary = w["client_grid"]
		var right = g["left"] + (g["cols"] - 1) * g["step"]
		var bottom = g["top"] - (g["rows"] - 1) * g["step"]
		var wc = 0
		var wo = 0
		var worst = []
		for a in w["areas"]:
			var pos: Vector3 = a["pos"]
			var inside = pos.x >= g["left"] and pos.x <= right and pos.z <= g["top"] and pos.z >= bottom
			var dev = pos.y - Terrain.grid_height(g, pos.x, pos.z)
			var good = inside and (absf(dev) <= TERRAIN_TOLERANCE if a["type"] == 0 else dev >= -BELOW_TOLERANCE)
			wc += 1
			if good:
				wo += 1
			else:
				worst.append([absf(dev) if inside else INF, pos, dev, "Terrain" if a["type"] == 0 else "Box", inside])
		worst.sort_custom(func(x, y): return x[0] > y[0])
		checked += wc
		ok += wo
		worlds.append({"folder": w["folder"], "map": w["client_map"], "checked": wc, "ok": wo,
			"worst": worst.slice(0, WORST).map(func(x): return {"pos": x[1], "dev": x[2], "kind": x[3], "inside": x[4]})})
	return {"worlds": worlds, "checked": checked, "ok": ok, "score": float(ok) / checked if checked > 0 else -1.0}


# ====================================================
# ERGEBNIS
# ====================================================
# Match = gewichtetes geometrisches Mittel der Bereiche: alles muss passen; fehlen z.B. fast alle
# Maps, sinkt der Match stark, auch wenn Quests und Vorlagen vorhanden sind
func _score() -> void:
	var sum = 0.0
	var weight = 0.0
	var weakest = ""
	var weakest_score = 2.0
	for k in WEIGHTS:
		var s = float(result.get(k, {}).get("score", -1.0))
		if s >= 0.0:
			sum += log(maxf(s, MIN_PART)) * WEIGHTS[k]
			weight += WEIGHTS[k]
			if s < weakest_score:
				weakest_score = s
				weakest = k
	result["score"] = exp(sum / weight) if weight > 0.0 else -1.0
	var v: Dictionary = result["versions"]
	var pct = result["score"] * 100.0
	var text = ""
	match v["newer"]:
		"client":
			text = "Client neuer als Server (%s)" % v["why"]
		"server":
			text = "Server neuer als Client (%s)" % v["why"]
		"gleich":
			text = "Client und Server gleich alt (%s)" % v["why"]
		_:
			text = "Versionen nicht bestimmbar"
	if pct >= 90.0:
		text += " - passt: der Client hat, was der Server braucht"
	elif pct >= 60.0:
		text += " - passt teilweise: einige Quests / Maps / NPCs fehlen im Client"
	else:
		text += " - passt nicht: Quests führen wahrscheinlich auf Maps und zu NPCs, die der Client nicht hat"
	if weakest != "" and weakest_score < 0.9:
		text += " (am schwächsten: %s %s)" % [PART_NAMES[weakest], _pct(weakest_score)]
	result["verdict"] = text

static func _pct(f: float) -> String:
	return ("%.1f %%" % (f * 100.0)).replace(".", ",") if f >= 0.0 else "-"

# Bericht als Text (für die Leiste und die Ausgabe)
static func report_text(r: Dictionary) -> String:
	var l = PackedStringArray()
	l.append("ABGLEICH CLIENT <-> SERVER")
	l.append("Client: %s" % r.get("client", ""))
	l.append("Server: %s (%s)" % [r.get("server", ""), r.get("config", "")])
	if not r.get("errors", []).is_empty():
		l.append("Fehler: " + "; ".join(r["errors"]))
	if r.get("score", -1.0) < 0.0 and not r.has("versions"):
		return "\n".join(l)
	l.append("")
	l.append("MATCH: %s" % _pct(r["score"]))
	l.append(r.get("verdict", ""))
	var v = r["versions"]
	l.append("")
	l.append("Versionen (Client / Server):")
	l.append("  elements.data  0x%x / 0x%x" % [v["client"]["elements"], v["server"]["elements"]])
	var ct = v["client"]["tasks"]
	var st = v["server"]["tasks"]
	l.append("  tasks.data     Version %s / %s, %s / %s Quests, exportiert %s / %s" % [ct.get("version", "?"), st.get("version", "?"),
		ct.get("count", "?"), st.get("count", "?"), _date(ct.get("export", 0)), _date(st.get("export", 0))])
	var q = r["quests"]
	l.append("")
	l.append("Quests: %s - %d von %d Server-Quests im Client (Client hat %d weitere)" % [_pct(q["score"]), q["common"], q["server"], q["client_only"]])
	if not q["missing"].is_empty():
		l.append("  fehlen im Client: " + ", ".join(q["missing"].slice(0, 20).map(func(x): return str(x))) + (" ..." if q["missing"].size() > 20 else ""))
	var m = r["maps"]
	l.append("")
	l.append("Maps: %s nach Spawn-Gebieten - %d von %d Server-Welten mit Höhenkarte haben eine Client-Map (%s); %d Client-Maps" % [
		_pct(m["score"]), m["matched"], m["total"], _pct(m["share"]), m["client_maps"]])
	for w in m["worlds"]:
		var line = "  %4d %-6s %5d Gebiete  " % [w["tag"], w["folder"], w["areas"]]
		line += ("-> %-6s %s" % [w["map"], _pct(w["match"])]) if w["map"] != "" else ("FEHLT: " + w["note"])
		l.append(line)
	if not m["client_only"].is_empty():
		l.append("  Client-Maps ohne Server-Welt: " + ", ".join(m["client_only"]))
	var t = r["templates"]
	l.append("")
	if t.get("score", -1.0) >= 0.0:
		l.append("Vorlagen: %s - %d von %d Monster / NPCs der Server-Spawns im Client gleicher Art (nach Anzahl der Spawns %s; %d dem Server selbst unbekannt)" % [
			_pct(t["score"]), t["ok"], t["known"], _pct(t["spawn_score"]), t["unknown_server"]])
		for x in t["missing"].slice(0, 15):
			l.append("  %d %s (%s), im Client: %s" % [x[0], x[3], x[1], x[2] if x[2] != "" else "fehlt"])
		if t["missing"].size() > 15:
			l.append("  ... %d weitere" % (t["missing"].size() - 15))
	else:
		l.append("Vorlagen: -")
	var h = r["heights"]
	l.append("")
	l.append("NPC-Höhen: %s - %d von %d Spawn-Gebieten auf den gefundenen Maps passen zur Client-Höhe" % [_pct(h["score"]), h["ok"], h["checked"]])
	for w in h["worlds"]:
		var line = "  %-6s -> %-6s %s (%d / %d)" % [w["folder"], w["map"], _pct(float(w["ok"]) / maxi(1, w["checked"])), w["ok"], w["checked"]]
		var bad = []
		for x in w["worst"]:
			bad.append(("(%.0f | %.0f) %+.1f m %s" % [x["pos"].x, x["pos"].z, x["dev"], x["kind"]]) if x["inside"] else ("(%.0f | %.0f) außerhalb" % [x["pos"].x, x["pos"].z]))
		if not bad.is_empty():
			line += "  größte: " + ", ".join(bad)
		l.append(line)
	l.append("")
	l.append("Match = gewichtetes geometrisches Mittel (fehlt ein Bereich weitgehend, sinkt er stark).")
	l.append("Gewichtung: Maps %d %%, Quests %d %%, Vorlagen %d %%, NPC-Höhen %d %%; Dauer %.1f s" % [roundi(WEIGHTS["maps"] * 100),
		roundi(WEIGHTS["quests"] * 100), roundi(WEIGHTS["templates"] * 100), roundi(WEIGHTS["heights"] * 100), r.get("seconds", 0.0)])
	return "\n".join(l)
