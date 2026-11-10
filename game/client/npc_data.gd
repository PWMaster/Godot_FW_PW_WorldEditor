extends RefCounted

# ====================================================
# Anzeige der NPC- und Monster-Vorlagen im Client (Sprache des Clients), je Vorlage einmal gelesen:
#   elements.data (<data_root>/<Sprache>/data, angelica_elements.gd): Name; NPC: Titel (name_org)
#   über dem Namen; Monster: Stufen-Namen (level_name: vor dem Namen, ab der 5. Stufe dahinter,
#   CECMonster::Init), Namensfarbe (name_color), Modell-Maßstab (scale_model)
#   Modell: Szene aus der Meta "models" des Knotens Spawns der importierten Map (beim Map-Import
#   mit importiert, spawn_builder.gd), sonst der Importpfad von file_model (ecm_importer.gd);
#   ecm_of() nennt die Quelle (.ecm), aus der world_screen.gd ein fehlendes Modell selbst baut
#   Sammelpunkte (MINE_ESSENCE, Schritt 10b): mine = true, Modell aus file_matter, dist (max_distance),
#   desc (progress_desc, Text am Fortschrittsbalken), task (task_in: Quest nötig), Name weiß
# Namensfarben: NPCs NAME_COLOR_DEFAULT_NPC; Monster nach name_color 1 - 7 (CECMonster::
# GetNameColor), bei 0 nach Stufen-Abstand zur eigenen Figur (DecideTargetNameCol: die Funktion
# fehlt in den v260-Quellen, Werte aus den Quellen von Shenmo Mobile mit derselben Engine).
# ====================================================

const ELEMENTS = "res://addons/PWE-Manager/Data/angelica_elements.gd"
const FILES = "res://addons/PWE-Manager/Data/angelica_files.gd"
const IMPORTER = "res://addons/PWE-Manager/ECM/ecm_importer.gd"
const NPC_COLOR = 0xFF8CF13E # PlayerUtil::NAME_COLOR_DEFAULT_NPC
const MONSTER_COLORS = {1: 0xffffffff, 2: 0xffd9d919, 3: 0xff945305, 4: 0xff6ec3c9, 5: 0xff9370db, 6: 0xffff1cae, 7: 0xff3232cd}
# Stufen-Abstand (eigene - Monster) ab ... -> Farbe
const LEVEL_COLORS = [[15, 0xff777777], [9, 0xff11bc00], [5, 0xff91ff40], [-5, 0xffffffff], [-7, 0xffffb9d2],
	[-14, 0xffff7171], [-21, 0xffff0000]]
const LEVEL_COLOR_LOW = 0xffa80000

var elements = null # angelica_elements.gd
var models = {} # Vorlage -> Szene (Meta der Map)
var my_level = 1
var warnings: Array = []
var _cache = {}
var _importer = null
var _data_root = ""


# -> "" oder Fehlertext; map_root = importierte Map (für die Modelle)
func open(data_root: String, language: String, map_root: Node) -> String:
	_data_root = data_root
	var spawns = map_root.get_node_or_null("Spawns") if map_root != null else null
	if spawns != null and spawns.has_meta("models"):
		var m: Dictionary = spawns.get_meta("models")
		for k in m:
			models[int(k)] = m[k]
	var elements_script = load(ELEMENTS)
	var files = load(FILES).new(data_root)
	var path: String = elements_script.locate(files, language)
	if path == "":
		return "Не найден elements.data (%s/%s/data)" % [data_root, language]
	elements = elements_script.new()
	return elements.open(path, files)

# Vorlage -> {npc, mine, name, title, levels, level_names, name_color, scale, scene, tab (Tab-Auswahl),
# minimap (show_on_minimap)}; Name leer wie in den Daten (Deko-Tiere ohne Schild)
func info(tid: int) -> Dictionary:
	if _cache.has(tid):
		return _cache[tid]
	var r: Dictionary = elements.get_record(tid) if elements != null else {}
	var t = r.get("_type", "")
	var out = {"npc": t == "NPC_ESSENCE", "mine": t == "MINE_ESSENCE", "name": _clean(r.get("name", "")), "title": "", "levels": [],
		"level_names": [], "name_color": 0, "scale": 1.0, "scene": models.get(tid, ""),
		"tab": t == "MONSTER_ESSENCE" and int(r.get("can_select_by_tab", 1)) != 0}
	if t == "NPC_ESSENCE":
		out["title"] = _clean(r.get("name_org", ""))
	elif t == "MONSTER_ESSENCE":
		out["levels"] = r.get("level", [])
		out["level_names"] = r.get("level_name", []).map(func(s): return _clean(s))
		out["name_color"] = int(r.get("name_color", 0))
		var sc = float(r.get("scale_model", 0.0))
		out["scale"] = sc if sc > 0.0 else 1.0
	elif t == "MINE_ESSENCE":
		out["dist"] = float(r.get("max_distance", 3.0))
		out["desc"] = _clean(r.get("progress_desc", ""))
		out["task"] = int(r.get("task_in", 0))
		var rel = elements.path_of(int(r.get("file_matter", 0)))
		out["ecm"] = importer().find_game_file(rel) if rel != "" else ""
	elif r.is_empty():
		warnings.append("Шаблон %d отсутствует в elements.data" % tid)
	out["minimap"] = int(r.get("show_on_minimap", 1)) != 0 # Deko-Tiere (Name leer, nicht wählbar) nicht
	if out["scene"] == "" and not r.is_empty():
		if not out.has("ecm"):
			out["ecm"] = _ecm_path(tid)
		out["scene"] = importer().out_path(out["ecm"], ".tscn") if out["ecm"] != "" else ""
	_cache[tid] = out
	return out

# Quelle (.ecm in den Spieldaten) des Modells einer Vorlage, "" wenn keine
func ecm_of(tid: int) -> String:
	var i = info(tid)
	if not i.has("ecm"):
		i["ecm"] = _ecm_path(tid)
	return i["ecm"]

# ecm_importer.gd der Spieldaten (Pfade, Bauen zur Laufzeit)
func importer():
	if _importer == null:
		_importer = load(IMPORTER).new(_data_root)
	return _importer

# Name mit Stufen-Namen (Monster)
func display_name(i: Dictionary, level: int) -> String:
	var n: String = i["name"]
	var levels: Array = i["levels"]
	var names: Array = i["level_names"]
	for k in range(1, mini(levels.size(), names.size() + 1)):
		if int(levels[k]) == level:
			if names[k - 1] == "":
				return n
			return names[k - 1] + n if k <= 4 else n + names[k - 1]
	return n

func name_color(i: Dictionary, level: int) -> Color:
	if i["npc"]:
		return _argb(NPC_COLOR)
	if i.get("mine", false):
		return Color.WHITE
	if MONSTER_COLORS.has(i["name_color"]):
		return _argb(MONSTER_COLORS[i["name_color"]])
	var delta = my_level - level
	for lc in LEVEL_COLORS:
		if delta >= lc[0]:
			return _argb(lc[1])
	return _argb(LEVEL_COLOR_LOW)

# file_model -> path.data -> .ecm in den Spieldaten
func _ecm_path(tid: int) -> String:
	var rel: String = elements.model_of(tid) if elements != null else ""
	return importer().find_game_file(rel) if rel != "" else ""

static func _clean(s) -> String:
	var t = str(s)
	return load(ELEMENTS).strip_codes(t).strip_edges() if t.contains("^") else t.strip_edges()

static func _argb(c: int) -> Color:
	return Color8((c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff, (c >> 24) & 0xff)
