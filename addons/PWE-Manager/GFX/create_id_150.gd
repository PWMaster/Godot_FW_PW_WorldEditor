@tool
extends "create_id_140.gd"

# ====================================================
# GFXELEMENTID 150 = ID_ELE_TYPE_LIGHTNING (A3DGFXLightning)
# ====================================================
# Ein zur Kamera gedrehtes Band (Triangle-Strip) entlang eines zitternden Blitzpfads:
#  - Gerade:  StartPos -> EndPos im KeyPoint-Transform, LightNum Blitze im Zickzack
#             (S -> E -> S ...), je Segs Segmente.
#  - Kurve:   KeyPoint 0 enthält eine CurveMove (CtrlType 110) -> der Blitz folgt diesem
#             Bezier-Pfad, LightNum = 1, ohne KeyPoint-Transform (InitBuf / RenderCurveMethod).
#  - Alle Interval ms (mind. 50) baut BuildPath einen neuen Pfad: Rausch-Offset fStart in
#    [0, 1022], pro Zwischenpunkt Winkel = Rauschen * 2PI um die Blitzachse und
#    Ausschlag = Filter(Rauschen) * Amplitude.
#  - WaveMoving: stehende Sinuswelle sin(Pos * PI * Wellen) * sin(Zeit * 0.01 * Speed).
#  - Breite / Alpha: Start -> Mitte -> Ende entlang des Blitzes, Breite * KeyPoint-Scale.
# APerlinNoise1D liegt nicht im Quellcode -> gleich parametrisiertes 1D-Rauschen (angenähert).
# ====================================================

const CurvePath = preload("gfx_curve_path.gd")

var _segs = 0
var _light_num = 0
var _curved = false
var _valid = false

func _element_id() -> String:
	return "150"

func _node_name() -> String:
	return "Lightning_GFX"

# Ab Dateiversion 102 steht vor dem echten StartTime das StartTime der Amplituden-Animation
# (A3DGFXFloatValueTrans) -> der Parser legt das echte als StartTime_2 ab.
func _element_start_time(parsed_data: Dictionary) -> float:
	if parsed_data.has("DestNum") and parsed_data.has("StartTime_2"):
		return float(parsed_data["StartTime_2"])
	return float(parsed_data.get("StartTime", 0.0))


func _gen_element_uniforms(parent_node: Node, parsed_data: Dictionary, declared: Dictionary, uniform_assignments: Dictionary, ctrl_methods: Array) -> String:
	_segs = int(parsed_data.get("Segs", 0))
	_light_num = int(parsed_data.get("LightNum", 0))
	# InitBuf: CurveMove im KeyPoint 0 -> Kurvenmodus mit genau einem Blitz
	var curve_ctrl = _find_kp0_curve(parsed_data, ctrl_methods)
	_curved = curve_ctrl != null
	if _curved:
		_light_num = 1
	_valid = _segs >= 2 and _light_num >= 1

	var c = "group_uniforms Lightning;\n"
	c += "uniform int Random_Seed = " + str(hash(str(parent_node.name)) & 0xFFFF) + ";\n"
	declared["Random_Seed"] = true
	# Ab Version 102 / 73 – fehlen in gfx_element_150.gd, daher roh aus parsed_data
	c += KeyPointShader.declare(declared, "bool", "WaveMoving", " = " + ("true" if _as_bool(parsed_data.get("WaveMoving", "0")) else "false"))
	c += KeyPointShader.declare(declared, "float", "WaveMovingSpeed", " = " + _f(float(parsed_data.get("WaveMovingSpeed", 1.0))))
	c += KeyPointShader.declare(declared, "bool", "FixWaveLength", " = " + ("true" if _as_bool(parsed_data.get("FixWaveLength", "0")) else "false"))
	c += KeyPointShader.declare(declared, "float", "NumWaves", " = " + _f(float(parsed_data.get("NumWaves", 5.0))))
	c += KeyPointShader.declare(declared, "int", "Filter", " = " + str(int(parsed_data.get("Filter", 1)))) # Standard FT_RECTANGLE
	# m_fDeviation (Bogenmaß) setzt nur A3DGFXLtnBolt (151) für seine Einzelblitze, in .gfx-Dateien steht es nicht
	if parsed_data.has("Deviation"):
		c += KeyPointShader.declare(declared, "float", "Deviation", " = " + _f(float(parsed_data["Deviation"])))

	# Amplitude: ab Version 102 eine A3DGFXFloatValueTrans-Kurve, vorher fester Wert (Amplitude_2)
	if parsed_data.has("DestNum"):
		var dest_num = clampi(int(parsed_data["DestNum"]), 0, 5)
		var vals = PackedFloat32Array()
		var times = PackedFloat32Array()
		for k in range(6):
			var key = "DestVal" if k == 0 else "DestVal_" + str(k + 1)
			vals.append(float(parsed_data.get(key, 0.0)) if k <= dest_num else 0.0)
		for k in range(5):
			var key = "TransTime" if k == 0 else "TransTime_" + str(k + 1)
			times.append(float(parsed_data.get(key, 0.0)) if k < dest_num else 0.0)
		c += "uniform float Amp_Values[6];\n"
		c += "uniform float Amp_Times[5];\n"
		c += "uniform int Amp_DestNum = " + str(dest_num) + ";\n"
		c += "uniform float Amp_StartTime = " + _f(float(parsed_data.get("StartTime", 0.0))) + ";\n"
		uniform_assignments["Amp_Values"] = vals
		uniform_assignments["Amp_Times"] = times
		declared["Amp_Values"] = true

	# Kurvenmodus: Stützpunkte wie InitBuf (GetInterpPoint(i / Segs), Richtung, CalcVertVec)
	if _curved and _valid:
		var verts = []
		var pos_data = curve_ctrl.get("Pos_Array")
		if typeof(pos_data) == TYPE_ARRAY or typeof(pos_data) == TYPE_PACKED_VECTOR3_ARRAY:
			for p in pos_data:
				verts.append(p if typeof(p) == TYPE_VECTOR3 else Vector3.ZERO)
		var path = CurvePath.gen_path(verts)
		var int_pos = PackedVector3Array()
		var int_dir = PackedVector3Array()
		var int_up = PackedVector3Array()
		for i in range(_segs + 1):
			# Weniger als 3 Kurvenpunkte: GetInterpPoint schlägt fehl -> Ursprung
			int_pos.append(Vector3.ZERO if path.is_empty() else CurvePath.interp_point(path, i / float(_segs))["pos"])
			if i > 0:
				var d = (int_pos[i] - int_pos[i - 1]).normalized()
				int_dir.append(d)
				int_up.append(_calc_vert_vec(d))
		int_dir.append(int_dir[_segs - 1])
		int_up.append(_calc_vert_vec(int_dir[_segs]))
		var n = str(_segs + 1)
		c += "uniform vec3 Ltn_IntPos[" + n + "];\n"
		c += "uniform vec3 Ltn_IntDir[" + n + "];\n"
		c += "uniform vec3 Ltn_IntUp[" + n + "];\n"
		c += "uniform float Ltn_CurveLen = " + _f(0.0 if path.is_empty() else path["total_len"]) + ";\n"
		uniform_assignments["Ltn_IntPos"] = int_pos
		uniform_assignments["Ltn_IntDir"] = int_dir
		uniform_assignments["Ltn_IntUp"] = int_up
	c += "group_uniforms;\n\n"
	return c


func _gen_element_functions(declared: Dictionary) -> String:
	var u = func(name, fallback): return KeyPointShader.u(declared, name, fallback)
	var segs = str(maxi(_segs, 1))
	var c = "// --- BLITZ-HILFSFUNKTIONEN ---\n"
	c += "vec3 safe_norm(vec3 v) {\n"
	c += "\tfloat l = length(v);\n"
	c += "\treturn l > 0.000001 ? v / l : vec3(0.0);\n"
	c += "}\n"
	c += "// CalcVertVec: beliebiger Vektor senkrecht zu d\n"
	c += "vec3 calc_vert_vec(vec3 d) {\n"
	c += "\treturn safe_norm(abs(d.y) > 0.999 ? cross(d, vec3(1.0, 0.0, 0.0)) : cross(vec3(0.0, 1.0, 0.0), d));\n"
	c += "}\n"
	c += "// Zufall pro Pfad-Neubau (a_Random)\n"
	c += "float ltn_rnd(float n) {\n"
	c += "\treturn fract(sin(n * 91.3458 + float(Random_Seed) * 1.731) * 47453.5453);\n"
	c += "}\n"
	c += "float ltn_hash(float n, float ch) {\n"
	c += "\treturn fract(sin(n * 127.1 + ch * 311.7 + float(Random_Seed) * 0.0131) * 43758.5453) * 2.0 - 1.0;\n"
	c += "}\n"
	c += "float ltn_vnoise(float x, float ch) {\n"
	c += "\tfloat buf = max(1.0, float(" + u.call("BufLen", "256") + "));\n"
	c += "\tfloat i = floor(x);\n"
	c += "\tfloat f = x - i;\n"
	c += "\treturn mix(ltn_hash(mod(i, buf), ch), ltn_hash(mod(i + 1.0, buf), ch), f * f * (3.0 - 2.0 * f));\n"
	c += "}\n"
	c += "// APerlinNoise1D(BufLen, Amplitude, WaveLen, Persistence, OctaveNum) – angenähert, Kanal ch\n"
	c += "float ltn_perlin(float x, float ch) {\n"
	c += "\tfloat v = 0.0;\n"
	c += "\tfloat amp = " + u.call("Amplitude", "1.0") + ";\n"
	c += "\tfloat freq = 1.0 / max(1.0, " + u.call("WaveLen", "1.0") + ");\n"
	c += "\tfor (int o = 0; o < 8; o++) {\n"
	c += "\t\tif (o >= " + u.call("OctaveNum", "1") + ") break;\n"
	c += "\t\tv += amp * ltn_vnoise(x * freq, ch * 7.0 + float(o) * 13.0);\n"
	c += "\t\tamp *= " + u.call("Persistence", "0.5") + ";\n"
	c += "\t\tfreq *= 2.0;\n"
	c += "\t}\n"
	c += "\treturn v;\n"
	c += "}\n"
	c += "// filter() in A3DGFXLightning.cpp: 0 Dreieck, 1 Rechteck, 2 Sinus, 3 Trapez\n"
	c += "float ltn_filter(int type, float d, float v) {\n"
	c += "\tif (d < 0.0) return v;\n"
	c += "\tif (d > 1.0) d = d - floor(d);\n"
	c += "\tif (type == 0) return 2.0 * (d > 0.5 ? 1.0 - d : d);\n"
	c += "\tif (type == 2) return v * sin(d * PI);\n"
	c += "\tif (type == 3) return v * (d < 0.2 ? d * 5.0 : (d > 0.8 ? (1.0 - d) * 5.0 : 1.0));\n"
	c += "\treturn v;\n"
	c += "}\n"
	c += "// Start -> Mitte -> Ende\n"
	c += "float ltn_mid(float r, float s, float m, float e) {\n"
	c += "\treturn r < 0.5 ? mix(s, m, r * 2.0) : mix(m, e, (r - 0.5) * 2.0);\n"
	c += "}\n"
	c += "// m_pAnimableAmiplitude->GetValue(Zeit seit Start)\n"
	c += "float ltn_amplitude(float t_ms) {\n"
	if declared.has("Amp_Values"):
		c += "\tif (t_ms <= Amp_StartTime || Amp_DestNum == 0) return Amp_Values[0];\n"
		c += "\tfloat acc = Amp_StartTime;\n"
		c += "\tfor (int k = 0; k < 5; k++) {\n"
		c += "\t\tif (k >= Amp_DestNum) break;\n"
		c += "\t\tif (t_ms > acc + Amp_Times[k]) { acc += Amp_Times[k]; continue; }\n"
		c += "\t\treturn mix(Amp_Values[k], Amp_Values[k + 1], (t_ms - acc) / max(Amp_Times[k], 0.0001));\n"
		c += "\t}\n"
		c += "\treturn Amp_Values[min(Amp_DestNum, 5)];\n"
	else:
		c += "\treturn " + u.call("Amplitude_2", "0.0") + ";\n"
	c += "}\n"
	if _curved and _valid:
		c += "// Kurvenmodus: Position von Strip-Paar j (m_pIntPos bzw. m_pRandPos aus BuildPath)\n"
		c += "vec3 ltn_curve_pos(int j, float f_start, float fseg, float fwaves, float amp, float wave_t) {\n"
		c += "\tif (j <= 0) return Ltn_IntPos[0];\n"
		c += "\tif (j >= " + segs + ") return Ltn_IntPos[" + segs + "];\n"
		c += "\tint k = j - 1;\n"
		c += "\tfloat fin = float(k) / " + segs + ".0;\n"
		c += "\tif (WaveMoving) {\n"
		c += "\t\t// Angelica addiert hier einen Skalar auf alle drei Komponenten\n"
		c += "\t\tfloat loops = FixWaveLength ? fwaves : NumWaves;\n"
		c += "\t\treturn Ltn_IntPos[k + 1] + vec3(sin(fin * PI * loops) * sin(wave_t) * amp);\n"
		c += "\t}\n"
		c += "\tfloat x = f_start + float(k) * fseg;\n"
		c += "\t// BuildPath nutzt Richtung k + 1, aber Up-Vektor k\n"
		c += "\tvec4 q = quat_axis(Ltn_IntDir[k + 1], ltn_perlin(x, 0.0) * TAU);\n"
		c += "\treturn Ltn_IntPos[k + 1] + quat_rot(q, Ltn_IntUp[k]) * (ltn_filter(Filter, fin, ltn_perlin(x, 1.0)) * amp);\n"
		c += "}\n"
	c += "\n"
	return c


func _gen_vertex_body(declared: Dictionary) -> String:
	var u = func(name, fallback): return KeyPointShader.u(declared, name, fallback)
	if not _valid:
		return "\t// InitBuf schlägt fehl (Segs < 2 oder LightNum < 1) -> nichts zeichnen\n\tVERTEX = vec3(0.0);\n\tv_color = vec4(0.0);\n\tv_active = 0.0;\n"

	var segs = str(_segs)
	var render_count = _segs * _light_num + 1
	var w_start = u.call("Width", "0.0")
	var w_end = u.call("Width_2", w_start)
	var a_start = u.call("Alpha", "1.0")
	var a_end = u.call("Alpha_2", a_start)
	var c = "\t// --- A3DGFXLightning: Pfad-Neubau alle Interval ms (TickAnimation / UpdatePath) ---\n"
	c += "\tfloat elapsed = max(0.0, v_current_time - LocalStartTime);\n"
	c += "\tfloat interval = max(50.0, float(" + u.call("Interval", "100") + "));\n"
	c += "\tfloat epoch = floor(elapsed / interval);\n"
	c += "\tfloat f_start = floor(ltn_rnd(epoch) * 1023.0); // a_Random(0, 1022)\n"
	c += "\tfloat amp = WaveMoving ? ltn_amplitude(elapsed) : ltn_amplitude(epoch * interval);\n"
	c += "\tfloat wave_t = active_time * 0.01 * WaveMovingSpeed; // ::GetTickCount() * 0.01 * Speed\n"
	c += "\tint i = int(UV2.x + 0.5);\n"
	c += "\tfloat side = UV2.y; // 0 = Pos - ViewUp, 1 = Pos + ViewUp\n"
	c += "\tvec3 cam = (inverse(MODEL_MATRIX) * vec4(INV_VIEW_MATRIX[3].xyz, 1.0)).xyz;\n"
	c += "\t// Breite * GFX-Scale * KeyPoint-Scale\n"
	c += "\tfloat w_start = " + w_start + " * k_scale;\n"
	c += "\tfloat w_end = " + w_end + " * k_scale;\n"
	c += "\tfloat w_mid = " + u.call("Width_3", "(" + w_start + " + " + w_end + ") * 0.5") + " * k_scale;\n"
	c += "\tfloat a_start = " + a_start + ";\n"
	c += "\tfloat a_end = " + a_end + ";\n"
	c += "\tfloat a_mid = " + u.call("Alpha_3", "(" + a_start + " + " + a_end + ") * 0.5") + ";\n"
	c += "\tfloat ratio = float(i) / " + str(render_count - 1) + ".0;\n"
	c += "\tvec3 pos;\n"
	c += "\tvec3 view_up;\n"
	c += "\tfloat width;\n"
	c += "\tfloat alpha;\n"

	if _curved:
		c += "\t// --- RenderCurveMethod: entlang des Kurvenpfads, ohne KeyPoint-Transform ---\n"
		c += "\tfloat fwaves = Ltn_CurveLen / max(" + u.call("WaveLen_2", "1.0") + ", 0.000001);\n"
		c += "\tfloat fseg = fwaves / " + segs + ".0;\n"
		c += "\tbool use_normal = " + u.call("UseNormal", "false") + ";\n"
		c += "\tvec3 last = Ltn_IntPos[0];\n"
		c += "\tvec3 last_up = safe_norm(cross(Ltn_IntDir[0], use_normal ? " + u.call("Normal", "vec3(0.0)") + " : last - cam));\n"
		c += "\tpos = last;\n"
		c += "\tview_up = last_up;\n"
		c += "\t// Jedes Paar richtet sich nach dem Vorgänger aus (Vorzeichen-Abgleich mit vLastViewUp)\n"
		c += "\tfor (int j = 1; j <= " + segs + "; j++) {\n"
		c += "\t\tif (j > i) break;\n"
		c += "\t\tvec3 p = ltn_curve_pos(j, f_start, fseg, fwaves, amp, wave_t);\n"
		c += "\t\tvec3 nu = safe_norm(cross(p - last, use_normal ? " + u.call("Normal", "vec3(0.0)") + " : p - cam));\n"
		c += "\t\tif (dot(nu, last_up) < 0.0) nu = -nu;\n"
		c += "\t\tlast = p;\n"
		c += "\t\tlast_up = nu;\n"
		c += "\t\tpos = p;\n"
		c += "\t\tview_up = nu;\n"
		c += "\t}\n"
		c += "\tif (i == 0) { width = w_start; alpha = a_start; }\n"
		c += "\telse if (i == " + segs + ") { width = w_end; alpha = a_end; }\n"
		c += "\telse { width = ltn_mid(ratio, w_start, w_mid, w_end); alpha = ltn_mid(ratio, a_start, a_mid, a_end); }\n"
	else:
		c += "\t// --- Gerade: GetTranMatrix(kp), bei Pos1Enable / Pos2Enable kommen die Positionen von außen ---\n"
		c += "\tbool external_pos = " + u.call("Pos1Enable", "false") + " || " + u.call("Pos2Enable", "false") + ";\n"
		c += "\tvec4 rot = quat_mul(k_dir, quat_axis(vec3(0.0, 0.0, 1.0), k_rad));\n"
		var end_pos = u.call("EndPos", "vec3(0.0)")
		if declared.has("Deviation"):
			# BuildPath: Endpunkt je Neubau um bis zu Deviation zur Seite gedreht (gleiche Länge)
			var start_pos = u.call("StartPos", "vec3(0.0)")
			c += "\tvec3 dev_axis = " + end_pos + " - " + start_pos + ";\n"
			c += "\tvec3 dev_dir = safe_norm(dev_axis);\n"
			c += "\tvec3 dev_up = quat_rot(quat_axis(dev_dir, ltn_rnd(epoch * 3.0 + 1.0) * TAU), calc_vert_vec(dev_dir));\n"
			c += "\tvec3 end_cur = " + start_pos + " + quat_rot(quat_axis(dev_up, ltn_rnd(epoch * 3.0 + 2.0) * Deviation), dev_dir) * length(dev_axis);\n"
			end_pos = "end_cur"
		c += "\tvec3 vs = external_pos ? " + u.call("StartPos", "vec3(0.0)") + " : quat_rot(rot, " + u.call("StartPos", "vec3(0.0)") + ") + k_pos;\n"
		c += "\tvec3 ve = external_pos ? " + end_pos + " : quat_rot(rot, " + end_pos + ") + k_pos;\n"
		c += "\tvec3 dir = ve - vs;\n"
		c += "\tfloat dist = length(dir);\n"
		c += "\tdir = safe_norm(dir);\n"
		c += "\tvec3 up = calc_vert_vec(dir);\n"
		c += "\tfloat fwaves = dist / max(" + u.call("WaveLen_2", "1.0") + ", 0.000001);\n"
		c += "\tfloat fseg = fwaves / " + segs + ".0;\n"
		c += "\tint n_mod = i % " + str(_segs * 2) + ";\n"
		c += "\tif (n_mod == 0) {\n"
		c += "\t\tpos = vs; width = w_start; alpha = a_start;\n"
		c += "\t\tview_up = safe_norm(cross(dir, vs - cam));\n"
		c += "\t} else if (n_mod == " + segs + ") {\n"
		c += "\t\tpos = ve; width = w_end; alpha = a_end;\n"
		c += "\t\tview_up = safe_norm(cross(dir, ve - cam));\n"
		c += "\t} else {\n"
		c += "\t\t// Zickzack: gerade Blitze laufen S -> E, ungerade E -> S\n"
		c += "\t\tint n_mod_seg = i % " + segs + ";\n"
		c += "\t\tfloat portion = float((i / " + segs + ") % 2 == 1 ? " + segs + " - n_mod_seg : n_mod_seg) / " + segs + ".0;\n"
		c += "\t\t// Index des Zwischenpunkts (nCount); Angelica filtert über nCount / Segs\n"
		c += "\t\tint n_count = i - ((i - 1) / " + segs + " + 1);\n"
		c += "\t\tfloat fin = float(n_count) / " + segs + ".0;\n"
		c += "\t\tif (!WaveMoving) {\n"
		c += "\t\t\tfloat x = f_start + float(n_count) * fseg;\n"
		c += "\t\t\tvec3 rand_up = quat_rot(quat_axis(dir, ltn_perlin(x, 0.0) * TAU), up);\n"
		c += "\t\t\tpos = vs + dir * (portion * dist) + rand_up * (ltn_filter(Filter, fin, ltn_perlin(x, 1.0)) * amp);\n"
		c += "\t\t\tview_up = safe_norm(cross(dir, pos - cam));\n"
		c += "\t\t} else {\n"
		c += "\t\t\tfloat loops = FixWaveLength ? fwaves : NumWaves;\n"
		c += "\t\t\tpos = vs + dir * (portion * dist);\n"
		c += "\t\t\tview_up = safe_norm(cross(dir, pos - cam));\n"
		c += "\t\t\tpos += view_up * (sin(fin * PI * loops) * sin(wave_t) * amp);\n"
		c += "\t\t}\n"
		c += "\t\twidth = ltn_mid(portion, w_start, w_mid, w_end);\n"
		c += "\t\talpha = ltn_mid(portion, a_start, a_mid, a_end);\n"
		c += "\t}\n"

	c += "\tVERTEX = pos + view_up * width * (side * 2.0 - 1.0);\n"
	c += "\tv_color = vec4(k_color.rgb, alpha * k_color.a);\n"
	c += "\t// U entlang des ganzen Strips, V über die Breite\n"
	c += "\tcell_uv.x = " + u.call("UReverse", "false") + " ? 1.0 - ratio : ratio;\n"
	c += "\tcell_uv.y = (side < 0.5) != " + u.call("VReverse", "false") + " ? 1.0 : 0.0;\n"
	return c

func _gen_uv_post(declared: Dictionary) -> String:
	if declared.has("UVExchg"):
		return "\tif (UVExchg) UV = UV.yx;\n"
	return ""

# Strip aus (Segs * LightNum + 1) Paaren: UV2 = (Paar-Index, Seite)
func _build_mesh(_parsed_data: Dictionary) -> ArrayMesh:
	var pairs = (_segs * _light_num + 1) if _valid else 1
	var verts = PackedVector3Array()
	var uv2s = PackedVector2Array()
	var indices = PackedInt32Array()
	for i in range(pairs):
		for s in range(2):
			verts.append(Vector3.ZERO)
			uv2s.append(Vector2(float(i), float(s)))
	for i in range(pairs - 1):
		var b = i * 2
		indices.append_array([b, b + 1, b + 2, b + 2, b + 1, b + 3])
	if indices.is_empty():
		indices.append_array([0, 1, 0])

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(uv2s)
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Erste CurveMove (CtrlType 110) unter den CtrlMethods von KeyPoint 0
func _find_kp0_curve(parsed_data: Dictionary, ctrl_methods: Array) -> Node:
	var kps = parsed_data.get("_keypoints", [])
	if kps.is_empty():
		return null
	var count = mini(int(kps[0].get("CtrlMethodCount", 0)), ctrl_methods.size())
	for i in range(count):
		if str(ctrl_methods[i].get("CtrlType")) == "110":
			return ctrl_methods[i]
	return null

func _calc_vert_vec(d: Vector3) -> Vector3:
	return (d.cross(Vector3.RIGHT) if absf(d.y) > 0.999 else Vector3.UP.cross(d)).normalized()
