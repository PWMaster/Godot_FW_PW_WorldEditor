@tool
extends "create_id_140.gd"

# ====================================================
# GFXELEMENTID 151 = ID_ELE_TYPE_LTNBOLT (A3DGFXLtnBolt)
# ====================================================
# Ein Blitz-Stern: von der Mitte gehen Strahlen aus (BuildStrokeDir):
#   PerBolts * 2 Richtungen im Kreis in der X / Y-Ebene (sin, cos, 0), dazu Circles - 1 um Y
#   gedrehte Kreise ohne die Pole -> Circles * (PerBolts - 1) * 2 + 2 Strahlen.
# Jeder Strahl ist eine Kette aus MaxSteps Einzelblitzen (AddPath): Schrittlänge zufällig
#   StepMin..StepMax * Scale von KeyPoint 0, Breite / Alpha laufen über die Kette von
#   WidthStart / AlphaStart zu WidthEnd / AlphaEnd; mit Wahrscheinlichkeit MaxBranches / MaxSteps
#   zweigt am Kettenglied eine weitere Kette in dieselbe Richtung ab (höchstens MaxBranches).
# Jeder Einzelblitz ist ein A3DGFXLightning (150): 8 Segmente, WaveLen = Schrittlänge / 3,
#   Amplitude = StrokeAmp, Rauschen (256, 2, 1, 0.8, 5), Neubau alle Interval ms, Endpunkt je
#   Neubau um bis zu Deviation (Bogenmaß) zur Seite gedreht. create_id_150.gd baut sie als
#   Kinder "Stroke_<n>" des Nodes "LtnBolt_GFX".
# Die Einzelblitze hängen am Element (SetBindEle): sie übernehmen KeyPoints, Zeit, Textur und Blend.
# Angelica würfelt die Pfade bei jedem GFX-Start neu, hier einmal beim Erstellen (fester Zufall).
# ====================================================

const BOLT_NODE_NAME = "LtnBolt_GFX"
const MAX_STROKES = 512 # Schutz gegen riesige Verzweigungen
const BOLT_KEYS = ["Deviation", "StepMin", "StepMax", "WidthStart", "WidthEnd", "AlphaStart", "AlphaEnd",
	"StrokeAmp", "MaxSteps", "MaxBranches", "PerBolts", "Circles"]

var _rng = RandomNumberGenerator.new()
var _strokes = []
var _bolt = {}


func _element_id() -> String:
	return "151"

func _node_name() -> String:
	return BOLT_NODE_NAME

# Wie create_id_140, aber der Node hat Kinder -> alle bekommen einen Owner
func _create_with_shader(parent_node: Node3D, root_node: Node, undo_redo: EditorUndoRedoManager, max_group_time: float):
	if parent_node.has_node(_node_name()):
		return
	var node = build_bolt_node(parent_node, max_group_time)
	if node == null:
		return
	undo_redo.add_do_method(parent_node, "add_child", node)
	undo_redo.add_do_property(node, "owner", root_node)
	for stroke in node.get_children():
		undo_redo.add_do_property(stroke, "owner", root_node)
	undo_redo.add_undo_method(parent_node, "remove_child", node)
	undo_redo.add_do_reference(node)


# ====================================================
# BAUT DEN BLITZ-STERN (ohne Szene / UndoRedo -> auch für Tests nutzbar)
# ====================================================
func build_bolt_node(parent_node: Node, max_group_time: float) -> Node3D:
	var parsed_data = parent_node.get("parsed_data")
	if typeof(parsed_data) != TYPE_DICTIONARY:
		return null
	var bolt = Node3D.new()
	bolt.name = BOLT_NODE_NAME
	var c150 = load(get_script().resource_path.get_base_dir().path_join("create_id_150.gd")).new()
	var element_script = load(get_script().resource_path.get_base_dir().path_join("gfx_element_150.gd"))
	var strokes = build_strokes(parsed_data, hash(str(parent_node.name)))
	for n in range(strokes.size()):
		# Einzelblitz als 150-Element mit den Basis-Werten, KeyPoints und CtrlMethods des Sterns
		var stroke_el = Node3D.new()
		stroke_el.name = "Stroke_" + str(n + 1)
		stroke_el.set_script(element_script)
		stroke_el.parsed_data = _stroke_data(parsed_data, strokes[n])
		for group in parent_node.get_children():
			if str(group.name) in ["CtrlMethods", "Affectors"]:
				stroke_el.add_child(group.duplicate())
		var mesh = c150.build_element_node(stroke_el, max_group_time)
		stroke_el.free()
		if mesh != null:
			mesh.name = "Stroke_" + str(n + 1)
			bolt.add_child(mesh)
	c150.free()
	return bolt

# Alle Einzelblitze: [{start, end, step_len, width_start, width_end, alpha_start, alpha_end}]
func build_strokes(parsed_data: Dictionary, seed_value: int) -> Array:
	_rng.seed = seed_value
	_strokes = []
	_bolt = {
		"step_min": float(parsed_data.get("StepMin", 5.0)), "step_max": float(parsed_data.get("StepMax", 6.0)),
		"width_start": float(parsed_data.get("WidthStart", 0.15)), "width_end": float(parsed_data.get("WidthEnd", 0.03)),
		"alpha_start": float(parsed_data.get("AlphaStart", 1.0)), "alpha_end": float(parsed_data.get("AlphaEnd", 0.0)),
		"max_steps": int(parsed_data.get("MaxSteps", 1)), "max_branches": int(parsed_data.get("MaxBranches", 1)),
	}
	var kps = parsed_data.get("_keypoints", [])
	var scale = float(kps[0].get("Scale", 1.0)) if not kps.is_empty() else 1.0
	for d in stroke_dirs(int(parsed_data.get("PerBolts", 3)), int(parsed_data.get("Circles", 3))):
		_bolt["dir"] = d
		_add_path(1, 1, Vector3.ZERO, scale)
	return _strokes

# BuildStrokeDir2D / 3D: Richtungen der Strahlen
func stroke_dirs(per_bolts: int, circles: int) -> Array:
	if per_bolts < 1 or circles < 1:
		return []
	var n_bolts = per_bolts * 2
	var base = []
	for i in range(n_bolts):
		var a = i * TAU / n_bolts
		base.append(Vector3(sin(a), cos(a), 0.0))
	var dirs = base.duplicate()
	for c in range(1, circles):
		var q = Quaternion(Vector3.UP, PI / circles * c)
		for j in range(1, n_bolts):
			if j == per_bolts:
				continue
			dirs.append(q * base[j])
	return dirs

# AddPath: Kettenglied nStep, Abzweig nBranch
func _add_path(step: int, branch: int, start: Vector3, scale: float) -> void:
	if step > _bolt["max_steps"] or _strokes.size() >= MAX_STROKES:
		return
	var f = _rng.randf()
	var step_len = (_bolt["step_min"] * (1.0 - f) + _bolt["step_max"] * f) * scale
	var end = start + step_len * (_bolt["dir"] as Vector3)
	var max_steps = float(_bolt["max_steps"])
	var r0 = (step - 1) / max_steps
	var r1 = step / max_steps
	_strokes.append({
		"start": start, "end": end, "step_len": step_len,
		"width_start": lerpf(_bolt["width_start"], _bolt["width_end"], r0), "width_end": lerpf(_bolt["width_start"], _bolt["width_end"], r1),
		"alpha_start": lerpf(_bolt["alpha_start"], _bolt["alpha_end"], r0), "alpha_end": lerpf(_bolt["alpha_start"], _bolt["alpha_end"], r1),
	})
	step += 1
	if branch < _bolt["max_branches"]:
		branch += 1
		if _rng.randf() < _bolt["max_branches"] / max_steps:
			_add_path(step, branch, end, scale)
	_add_path(step, branch, end, scale)

# parsed_data eines Einzelblitzes (Werte wie in einer .gfx-Datei)
func _stroke_data(parsed_data: Dictionary, s: Dictionary) -> Dictionary:
	var d = parsed_data.duplicate(true)
	for key in BOLT_KEYS:
		d.erase(key)
	var v = func(p: Vector3) -> String: return "%f, %f, %f" % [p.x, p.y, p.z]
	d["GFXELEMENTID"] = "150"
	d.merge({
		"BufLen": "256", "Amplitude": "2.000000", "WaveLen": "1.000000", "Persistence": "0.800000", "OctaveNum": "5",
		"StartPos": v.call(s["start"]), "EndPos": v.call(s["end"]), "Segs": "8", "LightNum": "1",
		"WaveLen_2": _f(s["step_len"] / 3.0), "Interval": str(int(parsed_data.get("Interval", 100))),
		"Width": _f(s["width_start"]), "Width_2": _f(s["width_end"]), "Width_3": _f((s["width_start"] + s["width_end"]) * 0.5),
		"Alpha": _f(s["alpha_start"]), "Alpha_2": _f(s["alpha_end"]), "Alpha_3": _f((s["alpha_start"] + s["alpha_end"]) * 0.5),
		"Amplitude_2": _f(float(parsed_data.get("StrokeAmp", 0.4))), "Pos1Enable": "0", "Pos2Enable": "0", "UseNormal": "0",
		"Filter": "1", "Deviation": _f(float(parsed_data.get("Deviation", deg_to_rad(30.0)))),
	}, true)
	return d
