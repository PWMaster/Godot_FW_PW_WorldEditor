@tool
extends RefCounted

# ====================================================
# GLSL-Generator für den KeyPoint-Zustand eines Elements
# (A3DGFXKeyPointSet::TickAnimation / GetCurKeyPoint, A3DGFXKeyPoint.cpp)
# ====================================================
#  - KeyPoint mit InterpolateMode != 0: Mischung KeyPoint i -> i + 1
#    (Position, Farbe, Scale, Rad_2D; Richtung nur bei Modus 1), CtrlMethods ruhen.
#  - InterpolateMode 0: der Zustand läuft vom vorherigen KeyPoint weiter,
#    die CtrlMethods dieses KeyPoints wirken analytisch über die KeyPoint-Zeit darauf.
#  - Lineare Bewegungen verschieben die Drehzentren mit (ProcData.m_vAxisOff).
#  - GetCurKeyPoint addiert das Scale-Rauschen (CtrlType 109) zum Scale.
# Erzeugt: void kp_state(float span_ms, out vec3 k_pos, out vec4 k_dir, out vec4 k_color, out float k_scale, out float k_rad)
# Erwartet die KeyPoint-Uniforms KP_<k>_<Param> (fehlende werden durch Standardwerte ersetzt).
# Genutzt von create_id_140 (und künftigen KeyPoint-gesteuerten Elementen).
# ====================================================

const CurvePath = preload("gfx_curve_path.gd")
const CTRL_TYPES = ["100", "101", "102", "103", "104", "105", "106", "107", "108", "109", "110", "111"]
const INFINITE_SPAN_SEC = "4294967.295" # TimeSpan -1 = 0xFFFFFFFF ms


# Uniform-Gruppen der CtrlMethods (CtrlMethod_<i>_<Param>) + Pfad-Arrays für CtrlType 110
static func declare_ctrl_uniforms(ctrl_methods: Array, declared: Dictionary, uniform_assignments: Dictionary) -> String:
	var c = ""
	for i in range(ctrl_methods.size()):
		var child = ctrl_methods[i]
		var params_dict = get_node_params(child)
		if params_dict.is_empty():
			continue
		var prefix = "CtrlMethod_" + str(i) + "_"
		c += "group_uniforms _" + str(i) + "_Ctrl_Methode_" + str(child.get("CtrlType")) + ";\n"
		for param in params_dict.keys():
			var glsl_type = godot_type_to_glsl(params_dict.get(param))
			if glsl_type != "":
				c += declare(declared, glsl_type, prefix + param)
				uniform_assignments[prefix + param] = child.get(param)

		if str(child.get("CtrlType")) == "110":
			var verts = []
			var pos_data = child.get("Pos_Array")
			if typeof(pos_data) == TYPE_ARRAY or typeof(pos_data) == TYPE_PACKED_VECTOR3_ARRAY:
				for p in pos_data:
					verts.append(p if typeof(p) == TYPE_VECTOR3 else Vector3.ZERO)
			var path = CurvePath.gen_path(verts)
			if not path.is_empty():
				var n = path["points"].size()
				var quats = PackedVector4Array()
				for q in path["quats"]:
					quats.append(Vector4(q.x, q.y, q.z, q.w))
				uniform_assignments[prefix + "Path_Points"] = path["points"]
				uniform_assignments[prefix + "Path_Ratios"] = path["ratios"]
				uniform_assignments[prefix + "Path_Quats"] = quats
				declared[prefix + "Path_Points"] = n
				c += "uniform vec3 " + prefix + "Path_Points[" + str(n) + "];\n"
				c += "uniform float " + prefix + "Path_Ratios[" + str(n) + "];\n"
				c += "uniform vec4 " + prefix + "Path_Quats[" + str(n) + "];\n"
		c += "group_uniforms;\n\n"
	return c


# quat_*, srnd-freie Hilfsfunktionen + Rauschen (nur wenn CtrlType 107 / 109 vorkommt)
static func gen_helper_functions(ctrl_methods: Array) -> String:
	var c = "// --- QUATERNIONEN (A3DQUATERNION a * b == quat_mul(a, b)) ---\n"
	c += "vec4 quat_mul(vec4 a, vec4 b) {\n"
	c += "\treturn vec4(a.w * b.xyz + b.w * a.xyz + cross(a.xyz, b.xyz), a.w * b.w - dot(a.xyz, b.xyz));\n"
	c += "}\n"
	c += "vec4 quat_axis(vec3 axis, float angle) {\n"
	c += "\tfloat len = length(axis);\n"
	c += "\tif (len < 0.000001) return vec4(0.0, 0.0, 0.0, 1.0);\n"
	c += "\treturn vec4(axis / len * sin(angle * 0.5), cos(angle * 0.5));\n"
	c += "}\n"
	c += "vec3 quat_rot(vec4 q, vec3 v) {\n"
	c += "\treturn v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);\n"
	c += "}\n"
	c += "// SLERPQuad\n"
	c += "vec4 quat_slerp(vec4 a, vec4 b, float f) {\n"
	c += "\tfloat d = dot(a, b);\n"
	c += "\tif (d < 0.0) { b = -b; d = -d; }\n"
	c += "\tif (d > 0.9995) return normalize(mix(a, b, f));\n"
	c += "\tfloat th = acos(clamp(d, -1.0, 1.0));\n"
	c += "\treturn (a * sin((1.0 - f) * th) + b * sin(f * th)) / sin(th);\n"
	c += "}\n\n"

	var has_noise = false
	for child in ctrl_methods:
		if str(child.get("CtrlType")) in ["107", "109"]:
			has_noise = true
	if has_noise:
		c += "// --- NOISE FUNKTIONEN FÜR CTRL 107 & 109 ---\n"
		c += "float hash12(float p) { return fract(sin(p * 12.9898) * 43758.5453); }\n"
		c += "float noise1D(float p) {\n"
		c += "\tfloat i = floor(p); float f = fract(p);\n"
		c += "\treturn mix(hash12(i), hash12(i + 1.0), f * f * (3.0 - 2.0 * f));\n}\n"
		c += "float fbm1D(float x, int octaves, float persistence) {\n"
		c += "\tfloat v = 0.0; float a = 0.5;\n"
		c += "\tfor (int i = 0; i < 8; ++i) {\n"
		c += "\t\tif (i >= octaves) break;\n"
		c += "\t\tv += a * noise1D(x); x *= 2.0; a *= persistence;\n\t}\n"
		c += "\treturn v;\n}\n\n"
	return c


static func gen_kp_state(parsed_data: Dictionary, ctrl_methods: Array, declared: Dictionary) -> String:
	var kps: Array = parsed_data.get("_keypoints", [])
	var c = "// --- A3DGFXKeyPointSet: KeyPoint-Zustand span_ms nach StartTime ---\n"
	c += "void kp_state(float span_ms, out vec3 k_pos, out vec4 k_dir, out vec4 k_color, out float k_scale, out float k_rad) {\n"
	c += "\t// Resume(): m_KPProcess = KeyPoint 0\n"
	c += "\tk_pos = " + kp_u(declared, 0, "Position") + ";\n"
	c += "\tk_dir = " + kp_u(declared, 0, "Direction") + ";\n"
	c += "\tk_color = " + kp_u(declared, 0, "Color") + ";\n"
	c += "\tk_scale = " + kp_u(declared, 0, "Scale") + ";\n"
	c += "\tk_rad = " + kp_u(declared, 0, "Rad_2D") + ";\n"
	c += "\tfloat k_noise = 0.0;\n"
	c += "\tvec3 axis_off = vec3(0.0);\n"
	c += "\tfloat remaining = span_ms;\n"
	c += "\tbool done = false;\n"

	var ctrl_idx = 0
	for k in range(kps.size()):
		var kp_block: Dictionary = kps[k]
		var is_last = (k == kps.size() - 1)
		# Roh aus parsed_data gelesen (0 = keine, 1 = alles, 2 = ohne Richtung)
		var mode = int(str(kp_block.get("InterpolateMode", "0")))
		var ts = kp_u(declared, k, "TimeSpan")
		var ctrl_count = int(kp_block.get("CtrlMethodCount", 0))
		var kp_ctrls = []
		for i in range(ctrl_count):
			if ctrl_idx < ctrl_methods.size():
				kp_ctrls.append(ctrl_idx)
			ctrl_idx += 1

		c += "\t// ---- KeyPoint " + str(k) + " (InterpolateMode " + str(mode) + ") ----\n"
		c += "\tif (!done) {\n"
		c += "\t\tfloat ts = " + ts + ";\n"
		c += "\t\tbool inside = " + ("true" if is_last else "ts < 0.0 || remaining < ts") + ";\n"
		c += "\t\tfloat t_in = inside ? remaining : ts;\n"
		if mode != 0:
			if is_last:
				c += "\t\t// Letzter KeyPoint im Interpolationsmodus: m_KPProcess = m_KPOrg\n"
				for p in [["k_pos", "Position"], ["k_dir", "Direction"], ["k_color", "Color"], ["k_scale", "Scale"], ["k_rad", "Rad_2D"]]:
					c += "\t\t" + p[0] + " = " + kp_u(declared, k, p[1]) + ";\n"
			else:
				c += "\t\t// A3DGFXKeyPointSet::Interpolate\n"
				c += "\t\tfloat f = ts < 0.0 ? 0.0 : clamp(t_in / max(ts, 0.001), 0.0, 1.0);\n"
				c += "\t\tk_color = mix(" + kp_u(declared, k, "Color") + ", " + kp_u(declared, k + 1, "Color") + ", f);\n"
				c += "\t\tk_rad = mix(" + kp_u(declared, k, "Rad_2D") + ", " + kp_u(declared, k + 1, "Rad_2D") + ", f);\n"
				c += "\t\tk_scale = mix(" + kp_u(declared, k, "Scale") + ", " + kp_u(declared, k + 1, "Scale") + ", f);\n"
				c += "\t\tk_pos = mix(" + kp_u(declared, k, "Position") + ", " + kp_u(declared, k + 1, "Position") + ", f);\n"
				if mode == 1:
					c += "\t\tk_dir = quat_slerp(" + kp_u(declared, k, "Direction") + ", " + kp_u(declared, k + 1, "Direction") + ", f);\n"
		elif not kp_ctrls.is_empty():
			c += "\t\t// CtrlMethods über die KeyPoint-Zeit (Sekunden)\n"
			c += "\t\tfloat t = t_in * 0.001;\n"
			c += "\t\tvec3 lin = vec3(0.0);\n"
			c += "\t\tvec3 jump = vec3(0.0);\n"
			c += "\t\tvec3 p_rel = k_pos;\n"
			for i in kp_ctrls:
				c += _gen_ctrl(ctrl_methods[i], i, declared)
			c += "\t\tk_pos = p_rel + lin;\n"
			c += "\t\taxis_off += lin + jump;\n"
		c += "\t\tif (inside) done = true;\n"
		c += "\t\telse remaining -= ts;\n"
		c += "\t}\n"

	c += "\t// GetCurKeyPoint: Scale + m_fScaleNoise\n"
	c += "\tk_scale += k_noise;\n"
	c += "}\n\n"
	return c


# Eine CtrlMethod (Process) analytisch zwischen StartTime und min(t, EndTime)
static func _gen_ctrl(child: Node, i: int, declared: Dictionary) -> String:
	var ct = str(child.get("CtrlType"))
	var p = "CtrlMethod_" + str(i) + "_"
	if not ct in CTRL_TYPES or not declared.has(p + "StartTime"):
		return ""

	var c = "\t\t{\n"
	c += "\t\t\t// CtrlType " + ct + "\n"
	c += "\t\t\tif (t >= " + p + "StartTime && (" + p + "EndTime < 0.0 || " + p + "StartTime <= " + p + "EndTime)) {\n"
	c += "\t\t\t\tfloat a0 = " + p + "StartTime;\n"
	c += "\t\t\t\tfloat a1 = " + p + "EndTime < 0.0 ? t : min(t, " + p + "EndTime);\n"
	if ct in ["100", "101", "102", "103", "104"]:
		c += "\t\t\t\t// CalcDist: v(t) = Vel + Acc * t\n"
		c += "\t\t\t\tfloat dist = " + p + "Vel * (a1 - a0) + 0.5 * " + p + "Acc * (a1 * a1 - a0 * a0);\n"

	match ct:
		"100":
			c += "\t\t\t\tlin += " + p + "Dir * dist;\n"
		"101":
			c += "\t\t\t\tk_rad += dist;\n"
		"102", "103":
			c += "\t\t\t\tif (length(" + p + "Axis) > 0.000001) {\n"
			c += "\t\t\t\t\tvec4 q = quat_axis(" + p + "Axis, dist);\n"
			c += "\t\t\t\t\tvec3 ctr = " + p + "Pos + axis_off + jump;\n"
			c += "\t\t\t\t\tp_rel = quat_rot(q, p_rel - ctr) + ctr;\n"
			if ct == "102":
				c += "\t\t\t\t\tk_dir = normalize(quat_mul(q, k_dir));\n"
			c += "\t\t\t\t}\n"
		"104":
			c += "\t\t\t\tif (" + p + "Vel != 0.0) {\n"
			c += "\t\t\t\t\tvec3 ctr = " + p + "Pos + axis_off + jump;\n"
			c += "\t\t\t\t\tvec3 r = p_rel - ctr;\n"
			c += "\t\t\t\t\tfloat r_len = length(r);\n"
			c += "\t\t\t\t\tif (r_len > 0.000001) p_rel = ctr + r / r_len * max(0.0, r_len + dist);\n"
			c += "\t\t\t\t}\n"
		"105":
			c += "\t\t\t\t// gfx_ctrl_105 legt 'R, G, B, A' als Color(G, B, A, R) ab -> .argb ergibt wieder RGBA\n"
			c += "\t\t\t\tk_color = clamp(k_color + " + p + "ColorDelta.argb * (a1 - a0), 0.0, 1.0);\n"
		"106":
			var key = p + ("ScaleChage" if declared.has(p + "ScaleChage") else "ScaleChange")
			if declared.has(key):
				c += "\t\t\t\tk_scale = clamp(k_scale + " + key + ".x * (a1 - a0), " + key + ".y, " + key + ".z);\n"
		"107":
			c += "\t\t\t\tfloat n = fbm1D(a1 * 1000.0 / max(1.0, " + p + "WaveLen), int(" + p + "OctaveNum), " + p + "Persistence);\n"
			c += "\t\t\t\tk_color = vec4(" + p + "BaseColor.rgb, clamp(" + p + "BaseColor.a + (n * 2.0 - 1.0) * " + p + "Amplitude / 255.0, 0.0, 1.0));\n"
		"108":
			var stage = gen_stage_interp(p, "Color", "vec4", "a1 * 1000.0", "c_out", "\t\t\t\t", declared)
			if stage != "":
				c += stage
				c += "\t\t\t\tif (stage_cnt > 0) {\n"
				if declared.has(p + "AlphaOnly"):
					c += "\t\t\t\t\tif (" + p + "AlphaOnly) k_color.a = c_out.a; else k_color = c_out;\n"
				else:
					c += "\t\t\t\t\tk_color = c_out;\n"
				c += "\t\t\t\t}\n"
		"109":
			c += "\t\t\t\tk_noise = fbm1D(a1 * 1000.0 / max(0.001, " + p + "WaveLen), int(" + p + "OctaveNum), " + p + "Persistence) * " + p + "Amplitude;\n"
		"110":
			if declared.has(p + "Path_Points"):
				var n = int(declared[p + "Path_Points"])
				var last = str(n - 1)
				c += "\t\t\t\t// CurveMove: Position absolut auf den Pfad (Ratio = Zeit / KeyPoint-Dauer)\n"
				c += "\t\t\t\tfloat ratio = a1 / (ts < 0.0 ? " + INFINITE_SPAN_SEC + " : max(ts * 0.001, 0.000001));\n"
				c += "\t\t\t\tint seg = 0;\n"
				c += "\t\t\t\tfor (int j = 0; j < " + last + "; j++) {\n"
				c += "\t\t\t\t\tif (ratio <= " + p + "Path_Ratios[j + 1]) break;\n"
				c += "\t\t\t\t\tseg = j + 1;\n"
				c += "\t\t\t\t}\n"
				c += "\t\t\t\tvec3 new_pos = " + p + "Path_Points[" + last + "];\n"
				c += "\t\t\t\tvec4 new_q = " + p + "Path_Quats[" + last + "];\n"
				c += "\t\t\t\tif (seg < " + last + ") {\n"
				c += "\t\t\t\t\tfloat f = (ratio - " + p + "Path_Ratios[seg]) / max(0.000001, " + p + "Path_Ratios[seg + 1] - " + p + "Path_Ratios[seg]);\n"
				c += "\t\t\t\t\tnew_pos = mix(" + p + "Path_Points[seg], " + p + "Path_Points[seg + 1], f);\n"
				c += "\t\t\t\t\tnew_q = quat_slerp(" + p + "Path_Quats[seg], " + p + "Path_Quats[seg + 1], f);\n"
				c += "\t\t\t\t}\n"
				c += "\t\t\t\tjump += new_pos - (p_rel + lin);\n"
				c += "\t\t\t\tp_rel = new_pos - lin;\n"
				if declared.has(p + "CalcDir"):
					c += "\t\t\t\tif (" + p + "CalcDir) k_dir = new_q;\n"
			else:
				c += "\t\t\t\t// Weniger als 3 Pfadpunkte: GenPath baut keinen Pfad, Process tut nichts\n"
		"111":
			var stage = gen_stage_interp(p, "Scale", "float", "a1 * 1000.0", "s_out", "\t\t\t\t", declared)
			if stage != "":
				c += stage
				c += "\t\t\t\tif (stage_cnt > 0) k_scale = s_out;\n"
	c += "\t\t\t}\n"
	c += "\t\t}\n"
	return c


# Mehrstufige Übergänge (CtrlType 108 Farbe / 111 Scale), Zeit in Millisekunden
static func gen_stage_interp(prefix: String, base: String, glsl_type: String, t_ms_expr: String, out_var: String, indent: String, declared: Dictionary) -> String:
	var vals = []
	for k in range(1, 7):
		var n = prefix + (base if k == 1 else base + "_" + str(k))
		if not declared.has(n): break
		vals.append(n)
	if vals.is_empty():
		return ""
	var times = []
	for k in range(1, vals.size()):
		var n = prefix + ("TimeSpan" if k == 1 else "TimeSpan_" + str(k))
		if not declared.has(n): break
		times.append(n)
	var stages = min(vals.size() - 1, times.size())

	var c = indent + "int stage_cnt = " + ("int(" + prefix + "Count)" if declared.has(prefix + "Count") else "0") + ";\n"
	c += indent + "float t_ms = " + t_ms_expr + ";\n"
	c += indent + glsl_type + " " + out_var + " = " + vals[0] + ";\n"
	c += indent + "float stage_t = 0.0;\n"
	c += indent + "bool stage_done = false;\n"
	for s in range(stages):
		c += indent + "if (!stage_done && stage_cnt >= " + str(s + 1) + ") {\n"
		c += indent + "\tfloat st = max(0.0001, " + times[s] + ");\n"
		c += indent + "\tif (t_ms <= stage_t + st) { " + out_var + " = mix(" + vals[s] + ", " + vals[s + 1] + ", clamp((t_ms - stage_t) / st, 0.0, 1.0)); stage_done = true; }\n"
		c += indent + "\tstage_t += st;\n"
		c += indent + "}\n"
	if stages > 0:
		c += indent + "if (!stage_done) {\n"
		for s in range(stages):
			c += indent + "\tif (stage_cnt == " + str(s + 1) + ") " + out_var + " = " + vals[s + 1] + ";\n"
		c += indent + "\tif (stage_cnt > " + str(stages) + ") " + out_var + " = " + vals[stages] + ";\n"
		c += indent + "}\n"
	return c


# ====================================================
# HELFER
# ====================================================
# KeyPoint-Uniform oder Standardwert (KEY_POINT::Init)
static func kp_u(declared: Dictionary, k: int, param: String) -> String:
	var defaults = {
		"Position": "vec3(0.0)", "Direction": "vec4(0.0, 0.0, 0.0, 1.0)", "Color": "vec4(1.0)",
		"Scale": "1.0", "Rad_2D": "0.0", "TimeSpan": "0.0",
	}
	return u(declared, "KP_" + str(k) + "_" + param, defaults.get(param, "0.0"))

static func u(declared: Dictionary, uniform_name: String, fallback: String) -> String:
	return uniform_name if declared.has(uniform_name) else fallback

static func declare(declared: Dictionary, glsl_type: String, uniform_name: String, hint: String = "") -> String:
	if declared.has(uniform_name):
		return ""
	declared[uniform_name] = true
	return "uniform " + glsl_type + " " + uniform_name + hint + ";\n"

static func get_node_params(child: Node) -> Dictionary:
	if child.get_script() != null:
		var constants = child.get_script().get_script_constant_map()
		# Nur Steuer-Skripte (Dictionary); Element-Skripte haben KNOWN_PARAMS als Array
		for key in ["KNOWN_PARAMS", "PARAMS"]:
			if constants.has(key) and constants[key] is Dictionary: return constants[key]
	return {}

static func godot_type_to_glsl(type: int) -> String:
	match type:
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_BOOL: return "bool"
		TYPE_VECTOR3: return "vec3"
		TYPE_VECTOR4: return "vec4"
		TYPE_COLOR: return "vec4"
		_: return ""
