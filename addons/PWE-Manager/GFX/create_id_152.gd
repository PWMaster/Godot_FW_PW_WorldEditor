@tool
extends "create_id_150.gd"

# ====================================================
# GFXELEMENTID 152 = ID_ELE_TYPE_LIGHTNINGEX (A3DGFXLightningEx)
# ====================================================
# Ein Blitz wie 150. Neu ist nur der Kurvenmodus (CurveMove in KeyPoint 0, RenderCurveMethod):
#  - renderside: Band mittig (0), nach oben (1: Pos .. Pos + 2 Up) oder unten (2: Pos - 2 Up .. Pos).
#  - isappend: die Punkte entstehen nacheinander, je TimeSpan(KeyPoint 0) / Paare ms einer
#    (Ganzzahl-Division: TimeSpan -1 oder 0 ergibt 0 -> es entsteht nie ein Punkt).
#  - istaildisappear: jeder Punkt lebt vertslife ms, die ältesten verschwinden zuerst.
#  - tailfadeout: Alpha * (1 - Alter / vertslife).
#  - Gezeichnet werden die lebenden Punkte als eigener Strip (U, Breite, Alpha über diese Liste).
#    Punkt k: Anfang / Ende = Kurvenpunkt k, dazwischen m_pRandPos[k] (= Kurvenpunkt k + 1 mit
#    Ausschlag) - eins weiter als bei 150, wie in A3DGFXLightningEx.
#  - ResetLoopEnd: jede Wiederholung (RepeatCount) baut den Blitz neu auf.
# Ohne Kurve (gerader Blitz) zeichnet A3DGFXLightningEx exakt wie 150.
# Die Zeit läuft stetig (Angelica fügt je Frame-Tick hinzu und altert im selben Tick).
# ====================================================


func _element_id() -> String:
	return "152"

func _node_name() -> String:
	return "LightningEx_GFX"


func _gen_element_functions(declared: Dictionary) -> String:
	var c = super._gen_element_functions(declared)
	if not (_curved and _valid):
		return c
	var u = func(name, fallback): return KeyPointShader.u(declared, name, fallback)
	var segs = str(_segs)
	c += "// m_pRandPos[k] = Kurvenpunkt k + 1 mit Ausschlag (BuildPath, Kurvenmodus)\n"
	c += "vec3 lx_rand_pos(int k, float f_start, float fseg, float fwaves, float amp, float wave_t) {\n"
	c += "\tfloat fin = float(k) / " + segs + ".0;\n"
	c += "\tif (WaveMoving) {\n"
	c += "\t\tfloat loops = FixWaveLength ? fwaves : NumWaves;\n"
	c += "\t\treturn Ltn_IntPos[k + 1] + vec3(sin(fin * PI * loops) * sin(wave_t) * amp);\n"
	c += "\t}\n"
	c += "\tfloat x = f_start + float(k) * fseg;\n"
	c += "\tvec4 q = quat_axis(Ltn_IntDir[k + 1], ltn_perlin(x, 0.0) * TAU);\n"
	c += "\treturn Ltn_IntPos[k + 1] + quat_rot(q, Ltn_IntUp[k]) * (ltn_filter(" + u.call("Filter", "1") + ", fin, ltn_perlin(x, 1.0)) * amp);\n"
	c += "}\n\n"
	return c


func _gen_vertex_body(declared: Dictionary) -> String:
	if not (_curved and _valid):
		return super._gen_vertex_body(declared)
	var u = func(name, fallback): return KeyPointShader.u(declared, name, fallback)
	var segs = str(_segs)
	var pairs = str(_segs + 1)
	var w_start = u.call("Width", "0.0")
	var w_end = u.call("Width_2", w_start)
	var a_start = u.call("Alpha", "1.0")
	var a_end = u.call("Alpha_2", a_start)
	var c = "\t// --- A3DGFXLightning: Pfad-Neubau alle Interval ms (wie 150) ---\n"
	c += "\tfloat elapsed = max(0.0, v_current_time - LocalStartTime);\n"
	c += "\tfloat interval = max(50.0, float(" + u.call("Interval", "100") + "));\n"
	c += "\tfloat epoch = floor(elapsed / interval);\n"
	c += "\tfloat f_start = floor(ltn_rnd(epoch) * 1023.0); // a_Random(0, 1022)\n"
	c += "\tfloat amp = WaveMoving ? ltn_amplitude(elapsed) : ltn_amplitude(epoch * interval);\n"
	c += "\tfloat wave_t = active_time * 0.01 * WaveMovingSpeed;\n"
	c += "\tfloat fwaves = Ltn_CurveLen / max(" + u.call("WaveLen_2", "1.0") + ", 0.000001);\n"
	c += "\tfloat fseg = fwaves / " + segs + ".0;\n"
	c += "\tvec3 cam = (inverse(MODEL_MATRIX) * vec4(INV_VIEW_MATRIX[3].xyz, 1.0)).xyz;\n\n"

	c += "\t// --- TickAdd / TickList: aktive Zeit des Elements (ResetLoopEnd: je Wiederholung neu) ---\n"
	c += "\tfloat lx_t = 0.0;\n"
	c += "\tif (LocalTotalTime <= 0.0 || Is_Endless) {\n"
	c += "\t\tlx_t = elapsed;\n"
	c += "\t} else {\n"
	c += "\t\tfloat t_g = f_repeat >= 0.0 ? mod(active_time, max(0.001, GlobalLoopTime)) : active_time;\n"
	c += "\t\tfloat t_s = max(0.0, t_g - LocalStartTime);\n"
	c += "\t\tfloat lx_loop = floor(t_s / loop_full_duration);\n"
	c += "\t\tfloat lx_in = min(mod(t_s, loop_full_duration), loop_active_duration);\n"
	c += "\t\tif (f_repeat >= 0.0) lx_loop = min(lx_loop, f_repeat - 1.0);\n"
	c += "\t\tlx_t = " + u.call("ResetLoopEnd", "false") + " ? lx_in : lx_loop * loop_active_duration + lx_in;\n"
	c += "\t}\n"
	c += "\tfloat lx_life = max(1.0, float(" + u.call("vertslife", "1000") + "));\n"
	c += "\tint lx_first = 0;\n"
	c += "\tint lx_count = " + pairs + ";\n"
	c += "\tfloat lx_per = 0.0;\n"
	c += "\tbool lx_grow = " + u.call("isappend", "true") + ";\n"
	c += "\tif (lx_grow) {\n"
	c += "\t\t// nTimePerVertAdd = m_nTimeSpan / m_nVertPairNum (int, Richtung 0)\n"
	c += "\t\tlx_per = trunc(" + u.call("KP_0_TimeSpan", "0.0") + " / " + pairs + ".0);\n"
	c += "\t\tif (lx_per <= 0.0) {\n"
	c += "\t\t\tlx_count = 0;\n"
	c += "\t\t} else {\n"
	c += "\t\t\tint lx_added = int(min(" + pairs + ".0, floor(lx_t / lx_per)));\n"
	c += "\t\t\tif (" + u.call("istaildisappear", "true") + ") {\n"
	c += "\t\t\t\t// Punkt k entsteht bei (k + 1) * per und lebt vertslife ms\n"
	c += "\t\t\t\tlx_first = int(max(0.0, floor((lx_t - lx_life) / lx_per)));\n"
	c += "\t\t\t}\n"
	c += "\t\t\tlx_count = max(0, lx_added - lx_first);\n"
	c += "\t\t}\n"
	c += "\t}\n\n"

	c += "\t// --- RenderCurveMethod über die lebenden Punkte (Liste ab lx_first) ---\n"
	c += "\tint i = int(UV2.x + 0.5);\n"
	c += "\tfloat side = UV2.y; // 0 = GetRenderPos1, 1 = GetRenderPos2\n"
	c += "\tint lx_vis = clamp(i, 0, max(lx_count - 1, 0)); // überzählige Paare fallen auf den letzten\n"
	c += "\tbool use_normal = " + u.call("UseNormal", "false") + ";\n"
	c += "\tvec3 nrm = " + u.call("Normal", "vec3(0.0)") + ";\n"
	c += "\tint k0 = min(lx_first, " + segs + ");\n"
	c += "\tvec3 last = Ltn_IntPos[k0];\n"
	c += "\tvec3 last_up = safe_norm(cross(Ltn_IntDir[k0], use_normal ? nrm : last - cam));\n"
	c += "\tvec3 pos = last;\n"
	c += "\tvec3 view_up = last_up;\n"
	c += "\tfor (int j = 1; j < " + pairs + "; j++) {\n"
	c += "\t\tif (j > lx_vis) break;\n"
	c += "\t\tint nidx = k0 + j;\n"
	c += "\t\tvec3 p = j == lx_count - 1 ? Ltn_IntPos[nidx] : lx_rand_pos(nidx, f_start, fseg, fwaves, amp, wave_t);\n"
	c += "\t\tvec3 nu = safe_norm(cross(p - last, use_normal ? nrm : p - cam));\n"
	c += "\t\tif (dot(nu, last_up) < 0.0) nu = -nu;\n"
	c += "\t\tlast = p;\n"
	c += "\t\tlast_up = nu;\n"
	c += "\t\tpos = p;\n"
	c += "\t\tview_up = nu;\n"
	c += "\t}\n"
	c += "\tfloat w_start = " + w_start + " * k_scale;\n"
	c += "\tfloat w_end = " + w_end + " * k_scale;\n"
	c += "\tfloat w_mid = " + u.call("Width_3", "(" + w_start + " + " + w_end + ") * 0.5") + " * k_scale;\n"
	c += "\tfloat a_start = " + a_start + ";\n"
	c += "\tfloat a_end = " + a_end + ";\n"
	c += "\tfloat a_mid = " + u.call("Alpha_3", "(" + a_start + " + " + a_end + ") * 0.5") + ";\n"
	c += "\tfloat ratio = lx_count > 1 ? float(lx_vis) / float(lx_count - 1) : 0.0;\n"
	c += "\tfloat width;\n"
	c += "\tfloat alpha;\n"
	c += "\tif (lx_vis == 0) { width = w_start; alpha = a_start; }\n"
	c += "\telse if (lx_vis == lx_count - 1) { width = w_end; alpha = a_end; }\n"
	c += "\telse { width = ltn_mid(ratio, w_start, w_mid, w_end); alpha = ltn_mid(ratio, a_start, a_mid, a_end); }\n"
	c += "\tif (" + u.call("tailfadeout", "false") + " && lx_grow && lx_per > 0.0) {\n"
	c += "\t\tfloat age = clamp(lx_t - float(k0 + lx_vis + 1) * lx_per, 0.0, lx_life);\n"
	c += "\t\talpha *= 1.0 - age / lx_life;\n"
	c += "\t}\n"
	c += "\tif (i >= lx_count) {\n"
	c += "\t\t// Paar nicht in der Liste: ohne Fläche auf den letzten lebenden Punkt\n"
	c += "\t\twidth = 0.0;\n"
	c += "\t\talpha = 0.0;\n"
	c += "\t}\n"
	c += "\tif (lx_count <= 0) {\n"
	c += "\t\tv_active = 0.0;\n"
	c += "\t}\n"
	c += "\t// GetRenderPos1 / 2: Mitte Pos -/+ Up, oben Pos / Pos + 2 Up, unten Pos - 2 Up / Pos\n"
	c += "\tint render_side = " + u.call("renderside", "0") + ";\n"
	c += "\tfloat off = side * 2.0 - 1.0;\n"
	c += "\tif (render_side == 1) off = side * 2.0;\n"
	c += "\telse if (render_side == 2) off = side * 2.0 - 2.0;\n"
	c += "\tVERTEX = pos + view_up * width * off;\n"
	c += "\tv_color = vec4(k_color.rgb, alpha * k_color.a);\n"
	c += "\tcell_uv.x = " + u.call("UReverse", "false") + " ? 1.0 - ratio : ratio;\n"
	c += "\tcell_uv.y = (side < 0.5) != " + u.call("VReverse", "false") + " ? 1.0 : 0.0;\n"
	return c
