@tool
extends "create_id_120.gd"

# ====================================================
# GFXELEMENTID 125 = ID_ELE_TYPE_PARTICLE_CURVE (A3DCurveEmitter)
# ====================================================
# Partikel entstehen entlang einer Bezier-Kurve, optional in einem Schlauch mit Radius.
# Die Kurve steckt in einem eigenen KeyPoint des Emitters (CtrlType 110). Der Parser legt
# dessen Werte auf Element-Ebene ab (InterpolateMode, TimeSpan, ..., CtrlMethodCount) und
# die 110er CtrlMethod VOR die KeyPoint-CtrlMethods -> _emitter_owned_ctrl_count.
# Der Pfad wird wie A3DGFXCtrlCurveMove::GenPath in GDScript gebaut (gfx_curve_path.gd).
# ====================================================

const CurvePath = preload("gfx_curve_path.gd")

var _curve_count = 0

func _element_id() -> String:
	return "125"

func _emitter_owned_ctrl_count(parsed_data: Dictionary) -> int:
	return int(parsed_data.get("CtrlMethodCount", 0))

# GetEmissionCount liefert 0, wenn der Emitter-KeyPoint keine CurveMove hat
func _emitter_can_emit(_parsed_data: Dictionary, emitter_ctrls: Array) -> bool:
	return _find_curve_ctrl(emitter_ctrls) != null

func _gen_emitter_uniforms(_parent_node: Node, parsed_data: Dictionary, declared: Dictionary, uniform_assignments: Dictionary, emitter_ctrls: Array) -> String:
	_curve_count = 0
	var curve_ctrl = _find_curve_ctrl(emitter_ctrls)
	if curve_ctrl == null:
		push_warning("Kurven-Emitter ohne CtrlType 110 -> keine Emission")
		return ""

	var verts = []
	var pos_data = curve_ctrl.get("Pos_Array")
	if typeof(pos_data) == TYPE_ARRAY or typeof(pos_data) == TYPE_PACKED_VECTOR3_ARRAY:
		for p in pos_data:
			verts.append(p if typeof(p) == TYPE_VECTOR3 else Vector3.ZERO)

	var path = CurvePath.gen_path(verts)
	if path.is_empty():
		push_warning("Kurven-Emitter mit weniger als 3 Punkten -> Partikel starten am Ursprung")
		return ""

	_curve_count = path["points"].size()
	uniform_assignments["Curve_Points"] = path["points"]
	uniform_assignments["Curve_Ratios"] = path["ratios"]
	uniform_assignments["Curve_Dirs"] = path["dirs"]
	declared["Curve_Points"] = true
	declared["Curve_Ratios"] = true
	declared["Curve_Dirs"] = true
	declared["Avg_Step_Count"] = true

	var c = "group_uniforms Emitter_Curve;\n"
	c += "uniform vec3 Curve_Points[" + str(_curve_count) + "];\n"
	c += "uniform float Curve_Ratios[" + str(_curve_count) + "];\n"
	c += "uniform vec3 Curve_Dirs[" + str(_curve_count) + "];\n"
	c += "uniform int Avg_Step_Count = " + str(_avg_step_count(int(parsed_data.get("AvgGenSeg", 0)))) + ";\n"
	c += "group_uniforms;\n\n"
	return c

func _gen_emitter_functions(_declared: Dictionary) -> String:
	var c = _calc_vert_vec_glsl()
	if _curve_count < 2:
		return c
	var last = str(_curve_count - 1)
	c += "// A3DGFXCtrlCurveMove::GetInterpPoint (lineare Suche ab Punkt 0)\n"
	c += "vec3 curve_point(float ratio, out int seg) {\n"
	c += "\tseg = 0;\n"
	c += "\tfor (int i = 0; i < " + last + "; i++) {\n"
	c += "\t\tif (ratio <= Curve_Ratios[i + 1]) break;\n"
	c += "\t\tseg = i + 1;\n"
	c += "\t}\n"
	c += "\tif (seg >= " + last + ") {\n"
	c += "\t\tseg = " + last + ";\n"
	c += "\t\treturn Curve_Points[" + last + "];\n"
	c += "\t}\n"
	c += "\tfloat f = (ratio - Curve_Ratios[seg]) / max(0.000001, Curve_Ratios[seg + 1] - Curve_Ratios[seg]);\n"
	c += "\treturn mix(Curve_Points[seg], Curve_Points[seg + 1], f);\n"
	c += "}\n\n"
	return c

func _gen_emitter_init(declared: Dictionary) -> String:
	var u_radius = _u(declared, "Radius", "0.0")
	var c = "\t// A3DCurveEmitter::InitParticle\n"
	if _curve_count >= 2:
		c += "\tfloat c_ratio = rnd(e_idx, 11.0);\n"
		c += "\tif (" + _u(declared, "IsAvgGen", "false") + ") {\n"
		c += "\t\t// genNextStep: fester Schritt 1 / AvgGenSeg (sequenziell) oder zufällige Stufe\n"
		c += "\t\tfloat seg_num = max(1.0, float(" + _u(declared, "AvgGenSeg", "1") + "));\n"
		c += "\t\tif (" + _u(declared, "IsAvgGenSeq", "true") + ") c_ratio = mod(e_idx, float(Avg_Step_Count)) / seg_num;\n"
		c += "\t\telse c_ratio = e_idx < 0.5 ? 0.0 : floor(rnd(e_idx, 14.0) * seg_num) / seg_num;\n"
		c += "\t}\n"
		c += "\tint c_seg;\n"
		c += "\tvec3 c_pos = curve_point(c_ratio, c_seg);\n"
		c += "\tif (" + u_radius + " > 0.001) {\n"
		c += "\t\t// Schlauch um die Kurve: senkrecht zur Segmentrichtung, zufällig gedreht\n"
		c += "\t\tfloat c_r = " + _u(declared, "IsSurface", "false") + " ? " + u_radius + " : " + u_radius + " * rnd(e_idx, 12.0);\n"
		c += "\t\tvec3 c_d = Curve_Dirs[c_seg];\n"
		c += "\t\tc_pos += quat_rot(quat_axis(c_d, rnd(e_idx, 13.0) * TAU), calc_vert_vec(c_d)) * c_r;\n"
		c += "\t}\n"
	else:
		c += "\t// Ungültige Kurve: GetInterpPoint schlägt fehl -> Ursprung\n"
		c += "\tvec3 c_pos = vec3(0.0);\n"
	c += "\t// Ungebunden wird die Kurve nur skaliert, NICHT gedreht (A3DCurveEmitter::InitParticle)\n"
	c += "\tp_rel = is_bind ? c_pos : c_pos * ee_scale;\n"
	c += "\tp_rot = is_bind ? vec4(0.0, 0.0, 0.0, 1.0) : par_dir;\n"
	c += "\tmove_dir = gen_direction(e_idx, is_bind, ee_rot, " + _u(declared, "Angle", "0.0") + ");\n"
	return c


# ====================================================
# KURVE
# ====================================================
func _find_curve_ctrl(emitter_ctrls: Array) -> Node:
	for child in emitter_ctrls:
		if str(child.get("CtrlType")) == "110":
			return child
	return null

# IsAvgGenSeq: wie viele Schritte 0, 1/S, 2/S ... (float32) bis > 1 -> Zykluslänge
func _avg_step_count(seg_num: int) -> int:
	var step = _f32(1.0 / float(maxi(seg_num, 1)))
	var cur = 0.0
	var count = 0
	while count < 100000:
		count += 1
		var nxt = _f32(cur + step)
		if nxt > 1.0:
			break
		cur = nxt
	return count
