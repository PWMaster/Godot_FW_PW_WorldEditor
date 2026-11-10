@tool
extends RefCounted

# ====================================================
# Spawns des Spielservers als Marker in einer Map (Knoten "Spawns").
# Daten: Server/maps.json (Client-Map -> Server-Ordner, erster = Hauptwelt) und
# Server/data/<Ordner>/npcgen.data (npcgen.gd). Eingetragen wird die Hauptwelt der Map.
#   Spawns
#     Monster / NPCs / Monster-Gruppen   je Gebiet ein Marker3D an Pos, Blick nach Dir,
#                                         Name "<Nr> <Name> x<Anzahl>" (ohne Namen die Vorlagen-ID)
#     ... (Ereignis)                      Gebiete, deren Steuerung nicht von Anfang an aktiv ist
#     Sammelpunkte                        Sammelgebiete (Kräuter, Erze ...)
#     Objekte                             dynamische Objekte
# Meta je Marker "spawn": Gebiet (Typ, Ausdehnung, Steuerung, Einträge mit Vorlagen-ID, Name,
# Modell (.ecm), Anzahl, Respawn-Zeit, Pfad ...); am Knoten Spawns die Quelle (Ordner,
# Welt-Nummer, Art).
# import_models() (Map-Import) importiert die Modelle der NPCs und Monster als Szenen
# (ecm_importer.gd, res://ECM_Import/models/...) und legt am Knoten Spawns die Meta "models" an:
# {Vorlagen-ID: Szene}; der Client baut damit die Figuren, die der Server meldet.
# Namen und Modelle aus elements.data / path.data der Spieldaten (angelica_elements.gd) in der
# Sprache, die im Editor die Leiste XML gewählt hat (<Sprache>/data, sonst Deu, Franz, Eng, data).
# ====================================================

const NpcGen = preload("npcgen.gd")
const Settings = preload("../../../game/common/settings.gd")
const Elements = preload("../Data/angelica_elements.gd")
const NODE_NAME = "Spawns"
const MAPS_FILE = "maps.json"
const DATA_DIR = "data"
const GROUPS = ["Monster", "NPCs", "Monster-Gruppen"] # nach NPC-Typ 0 / 1 / 2
const EVENT_SUFFIX = " (Ereignis)"
const MIN_EXTENTS = 0.5

var warnings: Array = []


static func server_dir() -> String:
	return Settings.server_data_dir()

# maps.json -> {Client-Map: [{folder, tag, type, match}, ...]}
static func map_sources() -> Dictionary:
	var f = FileAccess.open(server_dir().path_join(MAPS_FILE), FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	return d.get("maps", {}) if d is Dictionary else {}

# Quellen einer Client-Map (erste = Hauptwelt), [] wenn es keine Spawn-Daten gibt
static func sources(map_name: String) -> Array:
	return map_sources().get(map_name.to_lower(), [])

static func npcgen_path(folder: String) -> String:
	return server_dir().path_join(DATA_DIR).path_join(folder).path_join("npcgen.data")

# Sprache der Namen: im Editor die der Leiste XML, sonst Deu
static func preferred_language() -> String:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var settings = Engine.get_singleton(&"EditorInterface").get_editor_settings()
		return str(settings.get_project_metadata("aui_xml_panel", "language", "Deu"))
	return "Deu"

# elements.data der Spieldaten öffnen (Sprache wie preferred_language), null wenn nicht da
func open_elements(files, lang: String = "") -> RefCounted:
	if files == null:
		return null
	var p: String = Elements.locate(files, lang if lang != "" else preferred_language())
	if p == "":
		warnings.append("Точки появления: не найден elements.data (<язык>/data), у маркеров нет имён")
		return null
	var el = Elements.new()
	var err = el.open(p, files)
	if err != "":
		warnings.append("Spawns: " + err)
		return null
	return el

# Knoten "Spawns" für die Map bauen (nicht eingehängt), null wenn es keine Daten gibt.
# elements: angelica_elements.gd (offen) für Namen und Modelle, sonst aus files geöffnet
func build_node(map_name: String, files = null, elements = null) -> Node3D:
	var src = sources(map_name)
	if src.is_empty():
		return null
	if elements == null:
		elements = open_elements(files)
	var main: Dictionary = src[0]
	var data = NpcGen.new().read(npcgen_path(main["folder"]), files)
	if data.has("error"):
		warnings.append("Spawns %s (%s): %s" % [map_name, main["folder"], data["error"]])
		return null
	var root = Node3D.new()
	root.name = NODE_NAME
	root.set_meta("source", main.duplicate())
	root.set_meta("npcgen_version", data["version"])
	var active = {} # Steuerung -> von Anfang an aktiv
	var ctrl_names = {}
	for c in data["controllers"]:
		active[c["id"]] = c["active"]
		ctrl_names[c["id"]] = c["name"]
	var groups = {}
	var index = 0
	for a in data["areas"]:
		index += 1
		var kind = GROUPS[a["npc_type"]] if a["npc_type"] < GROUPS.size() else "Typ %d" % a["npc_type"]
		var event = a["ctrl"] != 0 and not active.get(a["ctrl"], true)
		var group = _group(root, groups, kind + (EVENT_SUFFIX if event else ""))
		var first = a["gens"][0] if not a["gens"].is_empty() else {"id": 0, "num": 0}
		var total = 0
		var gens = []
		for g in a["gens"]:
			total += g["num"]
			gens.append({"id": g["id"], "name": _name(elements, g["id"]), "model": _model(elements, g["id"]),
				"num": g["num"], "refresh": g["refresh"], "aggressive": g["aggressive"],
				"path": g["path"], "loop": g["loop"], "run": g["run"], "dead_time": g["dead_time"],
				"offset_trn": g["offset_trn"], "offset_water": g["offset_water"]})
		var label = gens[0]["name"] if not gens.is_empty() and gens[0]["name"] != "" else str(first["id"])
		var m = _marker("%04d %s x%d" % [index, label, total], a["pos"], a["dir"], a["ext"])
		m.set_meta("spawn", {
			"area": index - 1, "npc_type": a["npc_type"], "on_terrain": a["type"] == 0, "ext": a["ext"],
			"ctrl": a["ctrl"], "ctrl_name": ctrl_names.get(a["ctrl"], ""), "auto_revive": a["auto_revive"],
			"life_time": a["life_time"], "max_num": a["max_num"], "attached": a["attached"], "gens": gens,
		})
		group.add_child(m)
	index = 0
	for r in data["res_areas"]:
		index += 1
		var group = _group(root, groups, "Sammelpunkte" + (EVENT_SUFFIX if r["ctrl"] != 0 and not active.get(r["ctrl"], true) else ""))
		var res = []
		for x in r["res"]:
			var e = x.duplicate()
			e["name"] = _name(elements, x["id"])
			res.append(e)
		var label = "0"
		if not res.is_empty():
			label = res[0]["name"] if res[0]["name"] != "" else str(res[0]["id"])
		var m = _marker("%04d %s" % [index, label], r["pos"], Vector3.ZERO, Vector3(r["ext_x"], r["ext_y"], r["ext_z"]))
		m.set_meta("spawn", {"res_area": index - 1, "ctrl": r["ctrl"], "res": res, "radius": r["radius"]})
		group.add_child(m)
	index = 0
	for o in data["dyn_objects"]:
		index += 1
		var group = _group(root, groups, "Objekte" + (EVENT_SUFFIX if o["ctrl"] != 0 and not active.get(o["ctrl"], true) else ""))
		var m = _marker("%04d %d" % [index, o["id"]], o["pos"], Vector3.ZERO, Vector3.ONE)
		m.set_meta("spawn", {"dyn_object": index - 1, "id": o["id"], "ctrl": o["ctrl"], "scale": o["scale"] / 16.0,
			"dir": o["dir"], "rad": o["rad"]})
		group.add_child(m)
	root.set_meta("counts", {"areas": data["areas"].size(), "res_areas": data["res_areas"].size(),
		"dyn_objects": data["dyn_objects"].size()})
	return root

# Spawns unter map_root einhängen (vorhandene "Spawns" ersetzt), Owner = map_root
# -> Anzahl Marker
func build(map_name: String, map_root: Node3D, files = null) -> int:
	var node = build_node(map_name, files)
	if node == null:
		return 0
	var old = map_root.get_node_or_null(NODE_NAME)
	if old != null:
		map_root.remove_child(old)
		old.free()
	map_root.add_child(node)
	set_owner_recursive(node, map_root)
	return count_markers(node)

# Modelle der NPCs und Monster unter node (Knoten Spawns) importieren; Meta "models" am Knoten.
# importer: ecm_importer.gd (Hinweise landen in seinen warnings) -> Anzahl der Modelle
func import_models(node: Node3D, importer) -> int:
	var by_model = {} # .ecm -> [Vorlagen-IDs]
	for group in node.get_children():
		for m in group.get_children():
			var s: Dictionary = m.get_meta("spawn", {})
			for g in s.get("gens", []):
				if g.get("model", "") != "":
					if not by_model.has(g["model"]):
						by_model[g["model"]] = []
					if not g["id"] in by_model[g["model"]]:
						by_model[g["model"]].append(g["id"])
	var models = {}
	var count = 0
	for rel in by_model:
		var res: Dictionary = importer.source_ecm(rel)
		if res["scene"] == null:
			continue
		count += 1
		var scene: String = importer.out_path(res["ecm"], ".tscn")
		for id in by_model[rel]:
			models[id] = scene
	node.set_meta("models", models)
	return count

static func count_markers(node: Node) -> int:
	var n = 0
	for c in node.get_children():
		n += 1 if c is Marker3D else count_markers(c)
	return n

static func set_owner_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for c in node.get_children():
		set_owner_recursive(c, owner)

static func _name(elements, id: int) -> String:
	return Elements.strip_codes(elements.name_of(id)) if elements != null and id > 0 else ""

static func _model(elements, id: int) -> String:
	return elements.model_of(id) if elements != null and id > 0 else ""

func _group(root: Node3D, groups: Dictionary, name: String) -> Node3D:
	if not groups.has(name):
		var g = Node3D.new()
		g.name = name
		root.add_child(g)
		groups[name] = g
	return groups[name]

func _marker(name: String, pos: Vector3, dir: Vector3, ext: Vector3) -> Marker3D:
	var m = Marker3D.new()
	for c in [".", ":", "@", "/", "\"", "%"]:
		name = name.replace(c, "_")
	m.name = name
	var flat = Vector3(dir.x, 0.0, dir.z)
	if flat.length() > 0.001:
		m.transform = Transform3D(Basis.looking_at(-flat.normalized(), Vector3.UP), pos)
	else:
		m.position = pos
	m.gizmo_extents = maxf(MIN_EXTENTS, maxf(absf(ext.x), absf(ext.z)))
	return m
