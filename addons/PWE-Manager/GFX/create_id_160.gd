@tool
extends "create_id_130.gd"

# ====================================================
# GFXELEMENTID 160 = ID_ELE_TYPE_MODEL (A3DGFXModel)
# ====================================================
# Kein Sprite, sondern ein Skin-Modell (gfx\Models\<ModelPath>, .smd) samt Aktion: die .smd der
# Spieldaten wird wie beim ECM-Import zur Szene (gfx_sources.gd).
# Transform, Farbe, Transparenz und Aktion setzt gfx_model_160.gd jeden Frame aus KeyPoints +
# CtrlMethods (gleiche Zeitlogik wie die Shader, ein Modell mit eigenem Material lässt sich
# nicht per Shader steuern). Fehlt das Modell, entsteht der Node trotzdem; Model_Resource
# lässt sich dann im Inspektor nachtragen.
# ====================================================

const MODEL_NODE_NAME = "Model_GFX"
const MODEL_DRIVER_SCRIPT = "gfx_model_160.gd"

# A3DBLEND: ONE = 2, INVSRCCOLOR = 4 -> additiv (wie bei den Shader-Elementen)
const ADDITIVE_DEST_BLENDS = [2, 4]


func _element_id() -> String:
	return "160"

func _node_name() -> String:
	return MODEL_NODE_NAME

func _node_label() -> String:
	return "Modelle"

func build_node(parent_node: Node, max_group_time: float) -> Node3D:
	return build_model_node(parent_node, max_group_time)


# ====================================================
# BAUT DAS MODELL (ohne Szene / UndoRedo -> auch für Tests nutzbar)
# ====================================================
func build_model_node(parent_node: Node, max_group_time: float) -> Node3D:
	var parsed_data = parent_node.get("parsed_data")
	if typeof(parsed_data) != TYPE_DICTIONARY:
		return null

	var model_path = str(parsed_data.get("ModelPath", "")).strip_edges()
	var sources = preload("gfx_sources.gd")
	# die .smd wird wie beim ECM-Import zur Szene (Hinweis dort)
	var model_res: Resource = sources.model(model_path) if model_path != "" else null

	var model = Node3D.new()
	model.name = MODEL_NODE_NAME
	model.set_script(load(_driver_path(MODEL_DRIVER_SCRIPT)))
	_apply_time_settings(model, parsed_data, max_group_time)

	# Werte roh aus parsed_data; fehlende Zeilen (ältere Dateiversionen) = Standardwerte aus A3DGFXModel()
	model.Model_Path = model_path
	model.Model_Resource = model_res
	model.Action_Name = str(parsed_data.get("ModelActName", "")).strip_edges()
	model.Action_Loops = int(str(parsed_data.get("Loops", "1")))
	model.Facing_Dir = _as_bool(parsed_data.get("FacingDir", "0"))
	model.Blend_Add = int(str(parsed_data.get("DestBlend", "6"))) in ADDITIVE_DEST_BLENDS
	model.Alpha_Compare = _as_bool(parsed_data.get("AlphaCmp", "0"))
	model.Z_Write = _as_bool(parsed_data.get("WriteZ", "0"))
	model.Z_Test = preload("gfx_parser.gd").z_test_enabled(parent_node, parsed_data)
	model.keypoints = _build_keypoints(parent_node, parsed_data)
	model.rebuild_model()

	# Startzustand für den Editor (Modell am ersten KeyPoint)
	if not model.keypoints.is_empty():
		var kp0: Dictionary = model.keypoints[0]
		var s: float = kp0["scale"]
		model.transform = Transform3D(Basis(kp0["dir"]).scaled(Vector3(s, s, s)), kp0["pos"])
	return model
