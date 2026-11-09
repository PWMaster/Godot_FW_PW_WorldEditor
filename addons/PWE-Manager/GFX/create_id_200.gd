@tool
extends "create_id_130.gd"

# ====================================================
# GFXELEMENTID 200 = ID_ELE_TYPE_GFX_CONTAINER (A3DGFXContainer)
# ====================================================
# Spielt eine andere GFX (GfxPath, relativ zum gfx-Ordner) an der Lage des KeyPoints ab.
# Die Unter-GFX kommt aus den Spieldaten (gfx_sources.gd). Sie wird beim Erstellen komplett aufgebaut - Datei-Node, Elemente,
# CtrlMethods und die Godot-Nodes aller Elemente wie mit den Create-Buttons - und als Kind
# "Sub_GFX" des Containers gespeichert. Container in der Unter-GFX entstehen genauso
# (GFX, die sich selbst enthalten, und mehr als 4 Ebenen werden übersprungen).
# gfx_container_200.gd gibt der Unter-GFX Lage, Scale, Alpha und Zeit vor.
# Dummy-Container (IsDummy) gehören zu Partikeln eines anderen Elements (DummyEle): der Node
# entsteht ausgeblendet, an den Partikeln zeigt gfx_dummy_particles.gd Kopien der Unter-GFX.
# ====================================================

const Parser = preload("gfx_parser.gd")
const CONTAINER_NODE_NAME = "GfxContainer_GFX"
const CONTAINER_DRIVER_SCRIPT = "gfx_container_200.gd"
const SUB_GFX_NODE_NAME = "Sub_GFX"
const MAX_NESTING = 4

# Erstell-Skript und Baufunktion je Element-ID (100 / 101 / 110 hängen den Node selbst an)
const ELEMENT_BUILDERS = {
	"100": ["create_id_100.gd", "build_element_node"],
	"101": ["create_id_101.gd", "build_element_node"],
	"110": ["create_id_110.gd", "build_element_node"],
	"120": ["create_id_120.gd", "build_particle_node"],
	"121": ["create_id_121.gd", "build_particle_node"],
	"122": ["create_id_122.gd", "build_particle_node"],
	"123": ["create_id_123.gd", "build_particle_node"],
	"124": ["create_id_124.gd", "build_particle_node"],
	"125": ["create_id_125.gd", "build_particle_node"],
	"130": ["create_id_130.gd", "build_node"],
	"140": ["create_id_140.gd", "build_element_node"],
	"150": ["create_id_150.gd", "build_element_node"],
	"151": ["create_id_151.gd", "build_bolt_node"],
	"152": ["create_id_152.gd", "build_element_node"],
	"160": ["create_id_160.gd", "build_node"],
	"170": ["create_id_170.gd", "build_node"],
	"180": ["create_id_180.gd", "build_element_node"],
	"190": ["create_id_190.gd", "build_element_node"],
	"200": ["create_id_200.gd", "build_node"],
	"210": ["create_id_210.gd", "build_element_node"],
	"211": ["create_id_211.gd", "build_element_node"],
	"220": ["create_id_220.gd", "build_node"],
	"230": ["create_id_230.gd", "build_node"],
}

# Bibliotheks-Dateien, die gerade aufgebaut werden (Container in Containern)
static var _building: PackedStringArray = []


func _element_id() -> String:
	return "200"

func _node_name() -> String:
	return CONTAINER_NODE_NAME

func _node_label() -> String:
	return "Container"

func build_node(parent_node: Node, max_group_time: float) -> Node3D:
	return build_container_node(parent_node, max_group_time)

# Wie create_id_130, aber die ganze Unter-GFX bekommt einen Owner (wird mitgespeichert)
func _create_element_node(parent_node: Node3D, root_node: Node, undo_redo: EditorUndoRedoManager, max_group_time: float):
	if parent_node.has_node(NodePath(_node_name())):
		return

	var node = build_node(parent_node, max_group_time)
	if node == null:
		return

	undo_redo.add_do_method(parent_node, "add_child", node)
	for n in _subtree(node):
		undo_redo.add_do_property(n, "owner", root_node)
	undo_redo.add_undo_method(parent_node, "remove_child", node)
	undo_redo.add_do_reference(node)


# ====================================================
# BAUT DEN CONTAINER (ohne Szene / UndoRedo -> auch für Tests nutzbar)
# ====================================================
func build_container_node(parent_node: Node, max_group_time: float) -> Node3D:
	var parsed_data = parent_node.get("parsed_data")
	if typeof(parsed_data) != TYPE_DICTIONARY:
		return null

	var node = Node3D.new()
	node.name = CONTAINER_NODE_NAME
	node.set_script(load(_driver_path(CONTAINER_DRIVER_SCRIPT)))
	_apply_time_settings(node, parsed_data, max_group_time)

	# Werte roh aus parsed_data; fehlende Zeilen (ältere Dateiversionen) = Standardwerte aus A3DGFXContainer()
	node.Gfx_Path = str(parsed_data.get("GfxPath", "")).strip_edges()
	node.Play_Speed = float(parsed_data.get("PlaySpeed", 1.0))
	node.Loop_Flag = _as_bool(parsed_data.get("LoopFlag", "0"))
	node.Outer_Color = _as_bool(parsed_data.get("OutColor", "0"))
	node.Is_Dummy = _as_bool(parsed_data.get("IsDummy", "0"))
	node.Dummy_Use_GScale = _as_bool(parsed_data.get("DummyUseGScale", "1"))
	node.Dummy_Users = ", ".join(_dummy_users(parent_node, str(parsed_data.get("Name", ""))))
	node.keypoints = _build_keypoints(parent_node, parsed_data)

	var sub = build_sub_gfx(node.Gfx_Path)
	if sub != null:
		node.add_child(sub)
		# Kopfzeile der Unter-GFX: parsed_data wird nicht mit der Szene gespeichert -> jetzt übernehmen
		node.Sub_Gfx_Speed = float(sub.parsed_data.get("PlaySpeed", 1.0))
		node.Sub_Gfx_Scale = float(sub.parsed_data.get("DedaultScale", 1.0))
		node.prepare_sub_gfx(false)

	# Startzustand für den Editor (Container am ersten KeyPoint)
	if not node.keypoints.is_empty():
		var kp0: Dictionary = node.keypoints[0]
		var s: float = kp0["scale"]
		node.transform = Transform3D(Basis(kp0["dir"]).scaled(Vector3(s, s, s)), kp0["pos"])
	node.visible = not node.Is_Dummy
	return node


# ====================================================
# UNTER-GFX AUS DER BIBLIOTHEK (A3DGFXContainer::Play -> LoadGfx)
# ====================================================
# Datei-Node "Sub_GFX" samt Elementen und deren Godot-Nodes, null = nicht gefunden / übersprungen
func build_sub_gfx(gfx_path: String) -> Node3D:
	var parser = Parser.new()
	var sources = preload("gfx_sources.gd")
	# aus den Spieldaten (fehlt sie, meldet es der Importer)
	var file_path = sources.gfx_file(gfx_path)
	if file_path == "":
		return null
	var key = file_path.to_lower()
	if key in _building or _building.size() >= MAX_NESTING:
		push_warning("GFX Container: " + file_path + " enthält sich selbst oder ist zu tief verschachtelt -> übersprungen")
		return null

	_building.append(key)
	var skipped_ids = []
	var sub = parser.build_file_node(file_path, SUB_GFX_NODE_NAME, skipped_ids)
	for raw_id in skipped_ids:
		preload("gfx_sources.gd").warn("GFX Container: unbekannte ID " + str(raw_id) + " in " + file_path.get_file() + " übersprungen")
	build_elements(sub)
	_building.remove_at(_building.size() - 1)
	return sub

# Godot-Nodes aller Elemente eines Datei-Nodes, wie die Create-Buttons (gleiche Gruppen-Loop-Zeit)
func build_elements(file_node: Node) -> void:
	var max_group_time = _get_max_time_for_header(file_node)
	if max_group_time <= 0.0:
		max_group_time = 3000.0
	for element in file_node.get_children():
		var data = element.get("parsed_data")
		if typeof(data) != TYPE_DICTIONARY:
			continue
		var raw_id = str(data.get("_system_id", ""))
		if not ELEMENT_BUILDERS.has(raw_id):
			if preload("gfx_sources.gd").active():
				preload("gfx_sources.gd").warn("Element-ID " + raw_id + " hat noch kein Erstell-Skript, Elemente übersprungen")
			else:
				print("GFX Container: ID ", raw_id, " (", element.name, ") hat noch kein Erstell-Skript")
			continue
		var creator = load(_driver_path(ELEMENT_BUILDERS[raw_id][0])).new()
		var built = creator.call(ELEMENT_BUILDERS[raw_id][1], element, max_group_time)
		if built != null and built.get_parent() == null:
			element.add_child(built)
		creator.free()
		# Dummy-Elemente zeichnet Angelica nur als Kopien an Partikeln (A3DGFXEx::Render überspringt
		# sie), die Kopien führt gfx_dummy_particles.gd
		if _as_bool(data.get("IsDummy", "0")) and element is Node3D:
			element.visible = false

func _subtree(node: Node) -> Array:
	var nodes = [node]
	for child in node.get_children():
		nodes.append_array(_subtree(child))
	return nodes

# Elemente derselben GFX mit DummyEle = Name dieses Containers
func _dummy_users(parent_node: Node, ele_name: String) -> PackedStringArray:
	var users = PackedStringArray()
	var header = parent_node.get_parent()
	if header == null or ele_name == "":
		return users
	for sibling in header.get_children():
		var data = sibling.get("parsed_data")
		if sibling != parent_node and typeof(data) == TYPE_DICTIONARY and str(data.get("DummyEle", "")).strip_edges() == ele_name:
			users.append(str(sibling.name))
	return users
