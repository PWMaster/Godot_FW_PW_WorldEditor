@tool
extends "create_id_160.gd"

# ====================================================
# GFXELEMENTID 230 = ID_ELE_TYPE_ECMODEL (A3DGFXECModel)
# ====================================================
# Ein komplettes Spielmodell aus einer .ecm (ECMPath, relativ zum Spielordner, z.B.
# Models\特效用ECM\巨人翅膀04\巨人翅膀04.ecm) mit einer kombinierten Aktion (ECMActName).
# Die .ecm der Spieldaten wird selbst importiert (gfx_sources.gd, ecm_importer.gd).
# Die .ecm liefert die Basis-Aktionen und Wiederholungen der kombinierten Aktion
# (CombineActName / BaseActName / LoopCount, -1 = endlos); Namen in UTF-8 oder GBK.
# Steuerung wie beim Modell-Element 160 (gfx_ecmodel_230.gd erweitert gfx_model_160.gd):
#   Transform = Scale(kp) * GetTranMatrix(kp), Farbe / Transparenz aus der KeyPoint-Farbe,
#   Blend aus der .gfx, Z-Write an (PrepareRenderSkinModel), Aktion läuft, solange das Element tickt.
# LDType 1 / 2 (Haut / Modell des Zaubernden vom Spiel) gibt es ohne Spiel nicht: die .ecm selbst
# wird gezeigt, wie im Angelica-Editor. Angehängte GFX (CoGfx) und Kind-Modelle der .ecm fehlen.
# ====================================================

const ECM_NODE_NAME = "ECModel_GFX"
const ECM_DRIVER_SCRIPT = "gfx_ecmodel_230.gd"
const UNKNOWN_LOOPS = -1 # ohne .ecm: Effekt-Modelle laufen meist endlos


func _element_id() -> String:
	return "230"

func _node_name() -> String:
	return ECM_NODE_NAME

func _node_label() -> String:
	return "ECModelle"

func build_node(parent_node: Node, max_group_time: float) -> Node3D:
	return build_ecmodel_node(parent_node, max_group_time)


# ====================================================
# BAUT DAS ECMODEL (ohne Szene / UndoRedo -> auch für Tests nutzbar)
# ====================================================
func build_ecmodel_node(parent_node: Node, max_group_time: float) -> Node3D:
	var parsed_data = parent_node.get("parsed_data")
	if typeof(parsed_data) != TYPE_DICTIONARY:
		return null

	var ecm_path = str(parsed_data.get("ECMPath", "")).strip_edges()
	var act_name = str(parsed_data.get("ECMActName", "")).strip_edges()
	var sources = preload("gfx_sources.gd")
	# die .ecm wird selbst importiert (Hinweis dort)
	var src = sources.ecm(ecm_path) if ecm_path != "" else {"scene": null, "ecm": ""}
	var found = {"model": "", "ecm": src["ecm"]}
	var model_res: Resource = src["scene"]

	var model = Node3D.new()
	model.name = ECM_NODE_NAME
	model.set_script(load(_driver_path(ECM_DRIVER_SCRIPT)))
	_apply_time_settings(model, parsed_data, max_group_time)

	model.Model_Path = ecm_path
	model.Model_Resource = model_res
	model.Ecm_File = found["ecm"]
	model.Action_Name = act_name
	model.Action_Loops = UNKNOWN_LOOPS
	if found["ecm"] != "" and act_name != "":
		var act = pick_action(read_ecm(found["ecm"]), act_name)
		if not act.is_empty():
			model.Action_Loops = act["loops"]
			model.Base_Actions = PackedStringArray(act["base"])
	model.Loader_Type = int(str(parsed_data.get("LDType", "0")))
	model.Facing_Dir = false
	model.Blend_Add = int(str(parsed_data.get("DestBlend", "6"))) in ADDITIVE_DEST_BLENDS
	model.Alpha_Compare = false
	model.Z_Write = true
	model.Z_Test = preload("gfx_parser.gd").z_test_enabled(parent_node, parsed_data)
	model.keypoints = _build_keypoints(parent_node, parsed_data)
	model.rebuild_model()

	# Startzustand für den Editor (Modell am ersten KeyPoint)
	if not model.keypoints.is_empty():
		var kp0: Dictionary = model.keypoints[0]
		var s: float = kp0["scale"]
		model.transform = Transform3D(Basis(kp0["dir"]).scaled(Vector3(s, s, s)), kp0["pos"])
	return model


# ====================================================
# .ecm (CECModel::Load, nur die kombinierten Aktionen)
# ====================================================
# {actions: [{name, name_ok, loops, base: [Name], base_loops: [int]}]}
# Namen in UTF-8 oder GBK (Spieldateien), name_ok bleibt für ältere Aufrufer
func read_ecm(path: String) -> Dictionary:
	var actions = []
	var bytes = preload("gfx_parser.gd")._decoder().get_bytes(path)
	if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
		bytes = bytes.slice(3)
	var current = null
	var in_base = false
	var start = 0
	while start < bytes.size():
		var end = bytes.find(10, start)
		if end < 0:
			end = bytes.size()
		var line = bytes.slice(start, end)
		start = end + 1
		if line.size() > 0 and line[line.size() - 1] == 13:
			line = line.slice(0, line.size() - 1)
		var colon = line.find(58) # ':'
		if colon < 0:
			continue
		var key = line.slice(0, colon).get_string_from_ascii().strip_edges()
		var raw = line.slice(colon + 1)
		match key:
			"CombineActName":
				current = {"name": _text(raw), "name_ok": true, "loops": 1, "base": [], "base_loops": []}
				actions.append(current)
				in_base = false
			"BaseActName":
				if current != null:
					current["base"].append(_text(raw))
					current["base_loops"].append(1)
					in_base = true
			"EventCount", "ScriptCount", "ChildCount", "AddiSkinCount", "CoGfxNum":
				# Ereignisse / Skripte danach haben eigene Zeilen, keine Aktions-Wiederholungen mehr
				current = null
			"LoopCount", "LoopMinNum":
				if current != null:
					var n = int(raw.get_string_from_ascii().strip_edges())
					if in_base:
						current["base_loops"][current["base_loops"].size() - 1] = n
					elif key == "LoopCount":
						current["loops"] = n
	return {"actions": actions}

# Kombinierte Aktion zum Namen; ohne lesbare Namen genügt eine einzige.
# loops: -1, wenn die kombinierte oder die erste Basis-Aktion endlos läuft, sonst das Produkt.
func pick_action(ecm: Dictionary, act_name: String) -> Dictionary:
	var list: Array = ecm.get("actions", [])
	var chosen = null
	for a in list:
		if a["name_ok"] and a["name"] == act_name:
			chosen = a
	if chosen == null and list.size() == 1:
		chosen = list[0]
	if chosen == null:
		return {}
	var loops = int(chosen["loops"])
	var base_loops = int(chosen["base_loops"][0]) if not chosen["base_loops"].is_empty() else 1
	var names = []
	for n in chosen["base"]:
		if n != "":
			names.append(n)
	return {"loops": -1 if (loops == -1 or base_loops == -1) else maxi(1, loops) * maxi(1, base_loops), "base": names}

# Name aus einer Zeile der .ecm: UTF-8 oder GBK (angelica_files.gd)
func _text(raw: PackedByteArray) -> String:
	return preload("gfx_parser.gd")._decoder().decode(raw).strip_edges()
