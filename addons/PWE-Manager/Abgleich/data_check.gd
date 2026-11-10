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
const PW155_ELEMENTS_VERSION = 0x3000009C
const PW_TASK_MAGIC = 0x93858361
const PW155_TASK_VERSION = 128
const MATCH_MIN = 0.9 # Anteil gleicher Höhen: dasselbe Gelände
const PREFILTER = 0.6 # Vorauswahl mit wenigen Stichproben
const HEIGHT_EQUAL = 0.5 # m
const SIGNATURE = 256 # Stichproben für die Vorauswahl
const SAMPLES = 8100 # Stichproben für den genauen Vergleich
const TERRAIN_TOLERANCE = 2.0 # m
const BELOW_TOLERANCE = 1.0 # m
const WEIGHTS = {"maps": 0.35, "quests": 0.25, "templates": 0.2, "heights": 0.2}
const PART_NAMES = {"maps": "Карты", "quests": "Квесты", "templates": "Шаблоны", "heights": "Высоты НПС"}
const SUPPORTED_ELEMENTS_VERSIONS = [0x10000297, 0x10000253]
const SUPPORTED_TASK_VERSIONS = [181, 184]
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
	_step("Проверяю папки клиента и сервера", 0.01)
	if not DirAccess.dir_exists_absolute(client_root):
		result["errors"].append("Папка клиента не найдена: " + client_root)
	_step("Ищу конфигурацию сервера", 0.02)
	if not _find_server():
		result["errors"].append("Файл gs.conf не найден в " + server_root)
	if not result["errors"].is_empty():
		result["verdict"] = "Сверка невозможна"
		return result
	result["gamed"] = gamed_dir
	result["config"] = config_dir
	_step("Читаю версии данных", 0.02)
	result["versions"] = _versions()
	if _is_pw155(result["versions"]):
		result["profile"] = "pw155"
		result["pw"] = _pw_inventory()
		result["verdict"] = "Данные Perfect World 155 прочитаны. Полная сверка содержимого для PW пока не поддерживается."
		result["seconds"] = (Time.get_ticks_msec() - t0) / 1000.0
		_step("Данные Perfect World 155 загружены", 1.0)
		return result
	var unsupported = _unsupported_formats(result["versions"])
	if not unsupported.is_empty():
		result["errors"].append("Форматы данных не поддерживаются: " + ", ".join(unsupported))
		result["verdict"] = "Сверка контента поддерживает только форматы Forsaken World."
		result["seconds"] = (Time.get_ticks_msec() - t0) / 1000.0
		_step("Формат данных не поддерживается", 1.0)
		return result
	_step("Читаю квесты", 0.05)
	result["quests"] = _quests()
	_step("Читаю миры и точки появления сервера", 0.07)
	_read_worlds()
	_step("Читаю ландшафты клиента", 0.1)
	result["maps"] = _maps()
	_step("Сверяю шаблоны", 0.6)
	result["templates"] = _templates()
	_step("Сверяю высоты НПС", 0.85)
	result["heights"] = _heights()
	_score()
	result["seconds"] = (Time.get_ticks_msec() - t0) / 1000.0
	_step("Готово", 1.0)
	return result

func _is_pw155(versions: Dictionary) -> bool:
	for side in ["client", "server"]:
		var data: Dictionary = versions.get(side, {})
		var tasks: Dictionary = data.get("tasks", {})
		if int(data.get("elements", 0)) != PW155_ELEMENTS_VERSION or int(tasks.get("magic", 0)) != PW_TASK_MAGIC or int(tasks.get("version", 0)) != PW155_TASK_VERSION:
			return false
	return true

func _pw_inventory() -> Dictionary:
	var client_maps = []
	var maps_dir = client_root.path_join("maps")
	if DirAccess.dir_exists_absolute(maps_dir):
		client_maps = DirAccess.get_directories_at(maps_dir)
		client_maps.sort()
	var server_worlds = []
	var world_data = []
	for section in result["gs_conf"]:
		if str(section).begins_with("World_"):
			var values: Dictionary = result["gs_conf"][section]
			var name = str(section).trim_prefix("World_")
			var folder = str(values.get("base_path", "")).trim_suffix("/").strip_edges()
			if folder == "":
				continue
			var world_dir = config_dir.path_join(folder)
			var npcgen_path = world_dir.path_join("npcgen.data")
			var hmaps_dir = world_dir.path_join("map")
			var hmap_count = 0
			if DirAccess.dir_exists_absolute(hmaps_dir):
				for map_file in DirAccess.get_files_at(hmaps_dir):
					if map_file.get_extension().to_lower() == "hmap":
						hmap_count += 1
			server_worlds.append(name)
			world_data.append({"name": name, "tag": int(values.get("tag", "-1")), "type": int(values.get("type", "0")),
				"base_path": folder, "npcgen_bytes": _disk_file_size(npcgen_path), "heightmap_files": hmap_count})
	server_worlds.sort()
	world_data.sort_custom(func(a, b): return a["name"] < b["name"])
	var inventory = {"client_maps": client_maps, "server_worlds": server_worlds, "world_data": world_data,
		"client_elements_size": _disk_file_size(_client_elements()), "client_tasks_size": _disk_file_size(_client_file("tasks.data")),
		"server_elements_size": _disk_file_size(config_dir.path_join("elements.data")), "server_tasks_size": _disk_file_size(config_dir.path_join("tasks.data"))}
	var manifest = {"format": "Perfect World 155", "client_root": client_root, "server_root": server_root, "config_root": config_dir,
		"versions": result["versions"], "client_maps": client_maps, "server_worlds": world_data, "files": {
			"client_elements_bytes": inventory["client_elements_size"], "client_tasks_bytes": inventory["client_tasks_size"],
			"server_elements_bytes": inventory["server_elements_size"], "server_tasks_bytes": inventory["server_tasks_size"]}}
	var output_path = "res://addons/PWE-Manager/Server/pw_server_import.json"
	var file = FileAccess.open(output_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(manifest, "\t") + "\n")
		file.close()
		inventory["manifest_path"] = ProjectSettings.globalize_path(output_path)
	else:
		inventory["manifest_error"] = "Не удалось записать " + output_path
		result["errors"].append(inventory["manifest_error"])
	return inventory

static func _disk_file_size(path: String) -> int:
	if path == "" or not FileAccess.file_exists(path):
		return -1
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var size = file.get_length()
	file.close()
	return size

func _unsupported_formats(versions: Dictionary) -> PackedStringArray:
	var unsupported = PackedStringArray()
	for side in ["client", "server"]:
		var label = "клиент" if side == "client" else "сервер"
		var data: Dictionary = versions.get(side, {})
		var elements_version = int(data.get("elements", 0))
		var task_info: Dictionary = data.get("tasks", {})
		var task_version = int(task_info.get("version", 0))
		if not elements_version in SUPPORTED_ELEMENTS_VERSIONS:
			unsupported.append("%s elements.data 0x%08X" % [label, elements_version])
		if int(task_info.get("magic", 0)) != TASK_INFO_MAGIC or not task_version in SUPPORTED_TASK_VERSIONS:
			unsupported.append("%s tasks.data v%d (заголовок 0x%08X)" % [label, task_version, int(task_info.get("magic", 0))])
	return unsupported

func _step(text: String, f: float) -> void:
	if _progress.is_valid():
		_progress.call(text, f)


# ====================================================
# SERVER FINDEN, gs.conf
# ====================================================
func _find_server() -> bool:
	for rel in ["", "gamed", "home/gamed", "Server/home/gamed", "server-fw/gamed", "server-fw", "home", "Server/home"]:
		var dir = server_root if rel == "" else server_root.path_join(rel)
		if FileAccess.file_exists(dir.path_join("gs.conf")):
			gamed_dir = dir
			break
	if gamed_dir == "":
		return false
	var conf = _ini(gamed_dir.path_join("gs.conf"))
	var root: String = conf.get("Template", {}).get("Root", "")
	config_dir = ""
	if root != "":
		var candidate = server_root.path_join(root.trim_prefix("/").trim_suffix("/"))
		if DirAccess.dir_exists_absolute(candidate):
			config_dir = candidate
	if config_dir == "":
		config_dir = gamed_dir.path_join("config")
	result["gs_conf"] = conf
	return DirAccess.dir_exists_absolute(config_dir)

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
	var c = {"elements": _elements_version(_client_elements(), _cf), "tasks": _task_info(_client_file("tasks.data"), _cf)}
	var s = {"elements": _elements_version(config_dir.path_join("elements.data"), _sf), "tasks": _task_info(config_dir.path_join("tasks.data"), _sf)}
	var newer = ""
	var why = ""
	var ct = c["tasks"].get("export", 0)
	var st = s["tasks"].get("export", 0)
	if ct > 0 and st > 0 and ct != st:
		newer = "client" if ct > st else "server"
		why = "экспорт квестов %s / %s" % [_date(ct), _date(st)]
	elif c["elements"] > 0 and s["elements"] > 0 and c["elements"] != s["elements"]:
		newer = "client" if c["elements"] > s["elements"] else "server"
		why = "elements.data 0x%x / 0x%x" % [c["elements"], s["elements"]]
	elif c["elements"] > 0 and c["elements"] == s["elements"]:
		newer = "gleich"
		why = "версии совпадают"
	return {"client": c, "server": s, "newer": newer, "why": why}

func _client_elements() -> String:
	var direct = client_root.path_join("data/elements.data")
	if FileAccess.file_exists(direct):
		return direct
	var p = _cf.resolve("data/elements.data")
	return p if p != "" else Elements.locate(_cf)

# Datei in data/ des Clients (sonst in einem Sprachordner)
func _client_file(name: String) -> String:
	for base in ["data", "Deu/data", "Eng/data", "Franz/data", "resources/data"]:
		var direct = client_root.path_join(base).path_join(name)
		if FileAccess.file_exists(direct):
			return direct
		var p = _cf.resolve(base + "/" + name)
		if p != "":
			return p
	return ""

func _elements_version(path: String, files) -> int:
	var b = _read_prefix(path, files, 4)
	return b.decode_u32(0) if b.size() >= 4 else 0

func _task_info(path: String, files) -> Dictionary:
	if path == "":
		return {}
	var b = _read_prefix(path, files, 20)
	if b.size() < 8:
		return {}
	var magic = b.decode_u32(0)
	var version = b.decode_u32(4)
	if magic != TASK_INFO_MAGIC or b.size() < 20:
		return {"path": path, "magic": magic, "version": version}
	return {"path": path, "magic": magic, "version": version, "count": b.decode_u32(8), "packs": b.decode_u32(12), "export": b.decode_u32(16)}

func _read_prefix(path: String, files, size: int) -> PackedByteArray:
	if path == "":
		return PackedByteArray()
	if FileAccess.file_exists(path):
		var file = FileAccess.open(path, FileAccess.READ)
		if file != null:
			var prefix = file.get_buffer(size)
			file.close()
			return prefix
	var bytes: PackedByteArray = files.get_bytes(path)
	return bytes.slice(0, mini(size, bytes.size()))

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
				"note": "на сервере нет карты высот"})
			continue
		_step("Сравниваю карты (%s)" % w["folder"], 0.45 + 0.15 * done / maxf(1.0, _worlds.size()))
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
			"match": best_sim, "note": "" if ok else ("ближайшая: %s %.0f %%" % [best, best_sim * 100.0] if best != "" else "у клиента нет карты такого размера")})
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
		_step("Читаю ландшафт клиента (%s)" % m, 0.1 + 0.35 * i / maxf(1.0, names.size()))
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
	var cerr = ce.open(cpath, _cf) if cpath != "" else "у клиента отсутствует elements.data"
	if err != "" or cerr != "":
		if err != "":
			result["errors"].append("Сервер: " + err)
		if cerr != "":
			result["errors"].append("Клиент: " + cerr)
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
			text = "Клиент новее сервера (%s)" % v["why"]
		"server":
			text = "Сервер новее клиента (%s)" % v["why"]
		"gleich":
			text = "Клиент и сервер одной версии (%s)" % v["why"]
		_:
			text = "Не удалось определить версии"
	if pct >= 90.0:
		text += " — клиент содержит данные, необходимые серверу"
	elif pct >= 60.0:
		text += " — совпадение частичное: у клиента отсутствуют некоторые квесты, карты или НПС"
	else:
		text += " — данные не совпадают: квесты могут ссылаться на отсутствующие у клиента карты и НПС"
	if weakest != "" and weakest_score < 0.9:
		text += " (хуже всего совпадают: %s %s)" % [PART_NAMES[weakest], _pct(weakest_score)]
	result["verdict"] = text

static func _pct(f: float) -> String:
	return ("%.1f %%" % (f * 100.0)).replace(".", ",") if f >= 0.0 else "-"

# Bericht als Text (für die Leiste und die Ausgabe)
static func report_text(r: Dictionary) -> String:
	var l = PackedStringArray()
	l.append("СВЕРКА КЛИЕНТА И СЕРВЕРА")
	l.append("Клиент: %s" % r.get("client", ""))
	l.append("Сервер: %s (%s)" % [r.get("server", ""), r.get("config", "")])
	if not r.get("errors", []).is_empty():
		l.append("Ошибки: " + "; ".join(r["errors"]))
	if r.get("profile", "") == "pw155":
		var v: Dictionary = r["versions"]
		var pw: Dictionary = r["pw"]
		l.append("Формат: Perfect World 155")
		l.append("Версии elements.data: 0x%08X / 0x%08X" % [v["client"]["elements"], v["server"]["elements"]])
		l.append("Версии tasks.data: %s / %s (заголовок 0x%08X)" % [v["client"]["tasks"].get("version", "?"), v["server"]["tasks"].get("version", "?"), v["client"]["tasks"].get("magic", 0)])
		l.append("Размер elements.data: %s / %s байт" % [pw["client_elements_size"], pw["server_elements_size"]])
		l.append("Размер tasks.data: %s / %s байт" % [pw["client_tasks_size"], pw["server_tasks_size"]])
		l.append("Карт клиента найдено: %d" % pw["client_maps"].size())
		l.append("Миров сервера найдено: %d" % pw["server_worlds"].size())
		l.append("JSON импорта сервера: %s" % pw.get("manifest_path", pw.get("manifest_error", "не создан")))
		if not pw["server_worlds"].is_empty():
			l.append("Миры: " + ", ".join(pw["server_worlds"]))
		l.append("Прочитаны заголовки и список миров/карт; содержимое квестов, шаблонов и высот этим отчётом не сверяется.")
		return "\n".join(l)
	if not r.has("quests"):
		if r.get("verdict", "") != "":
			l.append(str(r["verdict"]))
		if r.has("versions"):
			var v: Dictionary = r["versions"]
			l.append("Версии данных (клиент / сервер):")
			l.append("  elements.data  0x%08X / 0x%08X" % [v["client"]["elements"], v["server"]["elements"]])
			l.append("  tasks.data     версия %s / %s" % [v["client"]["tasks"].get("version", "не найдена"), v["server"]["tasks"].get("version", "не найдена")])
		return "\n".join(l)
	l.append("")
	l.append("СОВПАДЕНИЕ: %s" % _pct(r["score"]))
	l.append(r.get("verdict", ""))
	var v = r["versions"]
	l.append("")
	l.append("Версии данных (клиент / сервер):")
	l.append("  elements.data  0x%x / 0x%x" % [v["client"]["elements"], v["server"]["elements"]])
	var ct = v["client"]["tasks"]
	var st = v["server"]["tasks"]
	l.append("  tasks.data     версия %s / %s, квестов %s / %s, экспортировано %s / %s" % [ct.get("version", "?"), st.get("version", "?"),
		ct.get("count", "?"), st.get("count", "?"), _date(ct.get("export", 0)), _date(st.get("export", 0))])
	var q = r["quests"]
	l.append("")
	l.append("Квесты: %s — у клиента есть %d из %d серверных квестов (ещё %d только у клиента)" % [_pct(q["score"]), q["common"], q["server"], q["client_only"]])
	if not q["missing"].is_empty():
		l.append("  отсутствуют у клиента: " + ", ".join(q["missing"].slice(0, 20).map(func(x): return str(x))) + (" ..." if q["missing"].size() > 20 else ""))
	var m = r["maps"]
	l.append("")
	l.append("Карты: %s по точкам появления — карты клиента найдены для %d из %d серверных миров с картой высот (%s); карт клиента: %d" % [
		_pct(m["score"]), m["matched"], m["total"], _pct(m["share"]), m["client_maps"]])
	for w in m["worlds"]:
		var line = "  %4d %-6s %5d зон  " % [w["tag"], w["folder"], w["areas"]]
		line += ("-> %-6s %s" % [w["map"], _pct(w["match"])]) if w["map"] != "" else ("НЕ НАЙДЕНА: " + w["note"])
		l.append(line)
	if not m["client_only"].is_empty():
		l.append("  карты клиента без серверного мира: " + ", ".join(m["client_only"]))
	var t = r["templates"]
	l.append("")
	if t.get("score", -1.0) >= 0.0:
		l.append("Шаблоны: %s — у клиента совпадают %d из %d типов монстров и НПС из спавнов сервера (по числу спавнов %s; сервер не распознал %d)" % [
			_pct(t["score"]), t["ok"], t["known"], _pct(t["spawn_score"]), t["unknown_server"]])
		for x in t["missing"].slice(0, 15):
			l.append("  %d %s (%s), у клиента: %s" % [x[0], x[3], x[1], x[2] if x[2] != "" else "нет"])
		if t["missing"].size() > 15:
			l.append("  ... ещё %d" % (t["missing"].size() - 15))
	else:
		l.append("Шаблоны: -")
	var h = r["heights"]
	l.append("")
	l.append("Высоты НПС: %s — %d из %d точек появления на найденных картах совпадают с высотами клиента" % [_pct(h["score"]), h["ok"], h["checked"]])
	for w in h["worlds"]:
		var line = "  %-6s -> %-6s %s (%d / %d)" % [w["folder"], w["map"], _pct(float(w["ok"]) / maxi(1, w["checked"])), w["ok"], w["checked"]]
		var bad = []
		for x in w["worst"]:
			bad.append(("(%.0f | %.0f) %+.1f м %s" % [x["pos"].x, x["pos"].z, x["dev"], x["kind"]]) if x["inside"] else ("(%.0f | %.0f) вне карты" % [x["pos"].x, x["pos"].z]))
		if not bad.is_empty():
			line += "  наибольшие отклонения: " + ", ".join(bad)
		l.append(line)
	l.append("")
	l.append("Итоговое совпадение — взвешенное геометрическое среднее; низкое значение в одном разделе заметно снижает результат.")
	l.append("Вес разделов: карты %d %%, квесты %d %%, шаблоны %d %%, высоты НПС %d %%; время %.1f с" % [roundi(WEIGHTS["maps"] * 100),
		roundi(WEIGHTS["quests"] * 100), roundi(WEIGHTS["templates"] * 100), roundi(WEIGHTS["heights"] * 100), r.get("seconds", 0.0)])
	return "\n".join(l)
