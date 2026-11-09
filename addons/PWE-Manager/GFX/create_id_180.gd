@tool
extends "create_id_140.gd"

# ====================================================
# GFXELEMENTID 180 = ID_ELE_TYPE_LTNTRAIL (A3DLtnTrail)
# ====================================================
# Ein zuckender Blitz-Schweif (Triangle-Strip) hinter dem KeyPoint-Transform:
#  - Jeder Tick (Angelica: jeder Frame, höchstens alle 40 ms) hängt einen Punkt an.
#    GetTranMatrix(kp) = Richtung * Rad_2D um Z + Position (ohne Scale),
#    Bind = 0: zusätzlich * GetParentTM() -> die Punkte bleiben in der Welt liegen.
#  - AddPoint ersetzt den alten Endpunkt durch einen Zwischenpunkt
#      lerp(letzter Zwischenpunkt, neue Position, Zufall) + Querversatz Amp..Amp_2
#    (zufällig um die Bewegungsrichtung gedreht) und setzt den neuen Endpunkt exakt.
#  - Jeder Eintrag zeichnet die Kante Pos -> Pos_2 (V = 0 / 1) im gemischten Transform.
#  - Alpha = KeyPoint-Alpha * Restleben / SegLife, U = 0, 0.2, ... 1.0, 0.2 ... (ohne Spritesheet).
#  - Gezeichnet wird nur, solange das Element aktiv ist; die Liste leert sich erst mit dem
#    GFX-Ende oder wenn alle Punkte verloschen sind (Lücke >= SegLife zwischen Wiederholungen).
# Der Shader rekonstruiert den Schweif aus der Zeit: Punkte im Raster Tick_Ms plus ein
# mitlaufender Kopf am aktuellen KeyPoint. Die Zickzack-Kette wird je Eintrag ab dem Kettenanfang
# bzw. 16 Schritte zurück gerechnet (ältere Punkte wirken pro Schritt nur mit Faktor 1 - Zufall).
# Bind = 0: gfx_ltntrail_180.gd merkt sich je Tick die Welt-Lage des Nodes (Hist_*).
# EnableMat / EnablePos (Transform bzw. Pos / Pos_2 kommen vom Spiel) lassen sich ohne Spiel
# nicht nachbilden: der Schweif folgt den KeyPoints, Pos / Pos_2 kommen aus der Datei.
# ====================================================

const TRAIL_DRIVER_SCRIPT = "gfx_ltntrail_180.gd"
const DEFAULT_SEG_LIFE = 1000 # A3DLtnTrail()
const INNER_TICK_MS = 40.0 # _inner_tick
const MIN_TICK_MS = 16.0 # kleinstes Tick_Ms, für das das Mesh reicht
const MAX_ENTRIES = 256 # LTNTRAIL_BUF_SIZE
const CHAIN_STEPS = 16
const TIME_LINE = "\tfloat active_time = Time_Manual ? Time : (TIME * 1000.0);\n" # aus create_id_140.gd

var _pairs = 3
var _hist_slots = 19


func _element_id() -> String:
	return "180"

func _node_name() -> String:
	return "LtnTrail_GFX"


func build_element_node(parent_node: Node, max_group_time: float) -> MeshInstance3D:
	var mesh_instance = super.build_element_node(parent_node, max_group_time)
	if mesh_instance == null:
		return null
	mesh_instance.set_script(load(get_script().resource_path.get_base_dir().path_join(TRAIL_DRIVER_SCRIPT)))
	mesh_instance.History_Slots = _hist_slots
	return mesh_instance

# Bind = 0 rechnet im Welt-Raum, Bind = 1 rechnet der Shader selbst mit MODEL_MATRIX um
func _build_shader_code(parent_node: Node, parsed_data: Dictionary, param_types: Dictionary, max_group_time: float, uniform_assignments: Dictionary) -> String:
	var code = super._build_shader_code(parent_node, parsed_data, param_types, max_group_time, uniform_assignments)
	code = code.replace("render_mode ", "render_mode world_vertex_coords, ")
	# Bind = 0: Uhr des Laufzeit-Skripts, damit Tick und gespeicherte Welt-Lage zusammenpassen
	# (TIME startet erst mit dem ersten Frame und läuft mit geglättetem Delta)
	return code.replace(TIME_LINE, "\tfloat active_time = Time_Manual ? Time : (Use_Driver_Time ? Driver_Time : TIME * 1000.0);\n")


func _gen_element_uniforms(parent_node: Node, parsed_data: Dictionary, declared: Dictionary, _uniform_assignments: Dictionary, _ctrl_methods: Array) -> String:
	var seg_life = int(parsed_data.get("SegLife", DEFAULT_SEG_LIFE))
	# Kopf (Zwischen- + Endpunkt) + lebende Tick-Punkte; die Kette braucht CHAIN_STEPS ältere Ticks
	_pairs = clampi(int(ceil(maxf(1.0, seg_life) / MIN_TICK_MS)) + 3, 3, MAX_ENTRIES)
	_hist_slots = _pairs + CHAIN_STEPS

	var c = "group_uniforms Lightning_Trail;\n"
	c += "uniform int Random_Seed = " + str(hash(str(parent_node.name)) & 0xFFFF) + ";\n"
	declared["Random_Seed"] = true
	c += "// Abstand der Schweif-Punkte in ms (Angelica: 1 Punkt pro Frame, höchstens alle 40 ms; 16.7 = 60 FPS).\n"
	c += "// Das Mesh reicht für SegLife / 16 Punkte, bei größerem SegLife das Element neu erstellen.\n"
	c += "uniform float Tick_Ms : hint_range(" + _f(MIN_TICK_MS) + ", " + _f(INNER_TICK_MS) + ", 0.1) = " + _f(INNER_TICK_MS) + ";\n"
	declared["Tick_Ms"] = true
	c += "group_uniforms;\n\n"
	c += "group_uniforms Bind_0_World_History; // setzt gfx_ltntrail_180.gd\n"
	c += "uniform vec3 Hist_Origin[" + str(_hist_slots) + "];\n"
	c += "uniform vec4 Hist_Rot[" + str(_hist_slots) + "];\n"
	c += "uniform float Hist_Scale[" + str(_hist_slots) + "];\n"
	c += "uniform vec3 Cur_Origin = vec3(0.0);\n"
	c += "uniform vec4 Cur_Rot = vec4(0.0, 0.0, 0.0, 1.0);\n"
	c += "uniform float Cur_Scale = 1.0;\n"
	c += "uniform bool Use_Driver_Time = false;\n"
	c += "uniform float Driver_Time = 0.0;\n"
	c += "group_uniforms;\n"
	c += "const float LT_HIST = " + str(_hist_slots) + ".0;\n\n"
	for n in ["Hist_Origin", "Hist_Rot", "Hist_Scale", "Cur_Origin", "Cur_Rot", "Cur_Scale", "Use_Driver_Time", "Driver_Time"]:
		declared[n] = true
	return c


func _gen_element_functions(declared: Dictionary) -> String:
	var u = func(name, fallback): return KeyPointShader.u(declared, name, fallback)
	var steps = str(CHAIN_STEPS)
	var bind = u.call("Bind", "true")
	var c = "// --- BLITZ-SCHWEIF (A3DLtnTrail) ---\n"
	c += "// _UnitRandom() je Schweif-Punkt n und Aufruf ch (0 = Anteil, 1 = Winkel, 2 = Ausschlag)\n"
	c += "float lt_rnd(float n, int ch) {\n"
	c += "\tuint h = uint(int(n)) * 747796405u + uint(ch) * 2891336453u + uint(Random_Seed) * 2654435761u;\n"
	c += "\th = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;\n"
	c += "\th = (h >> 22u) ^ h;\n"
	c += "\treturn float(h % 16777216u) / 16777216.0;\n"
	c += "}\n"
	c += "vec3 lt_norm(vec3 v) {\n"
	c += "\tfloat l = length(v);\n"
	c += "\treturn l > 0.000001 ? v / l : vec3(0.0);\n"
	c += "}\n"
	c += "// CalcVertVec: beliebiger Vektor senkrecht zu d\n"
	c += "vec3 lt_vert_vec(vec3 d) {\n"
	c += "\treturn lt_norm(abs(d.y) > 0.999 ? cross(d, vec3(1.0, 0.0, 0.0)) : cross(vec3(0.0, 1.0, 0.0), d));\n"
	c += "}\n"
	c += "// U des Eintrags m der Kette (Kettenanfang 0, dann je +0.2, über 1.0 hinaus -1.0)\n"
	c += "float lt_tex_u(float m) {\n"
	c += "\treturn m < 0.5 ? 0.0 : 0.2 * (1.0 + mod(m - 1.0, 5.0));\n"
	c += "}\n"
	c += "// Tick k: Zeit seit StartTime (inkl. Wiederholungen) bzw. KeyPoint-Zeit; J Ticks je Wiederholung\n"
	c += "float lt_tick_time(float k, float J, float full, float T) {\n"
	c += "\treturn floor(k / J) * full + mod(k, J) * T;\n"
	c += "}\n"
	c += "float lt_tick_span(float k, float J, float T) {\n"
	c += "\treturn mod(k, J) * T;\n"
	c += "}\n"
	c += "int lt_slot(float k) {\n"
	c += "\treturn int(mod(k, LT_HIST));\n"
	c += "}\n"
	c += "// GetTranMatrix(kp) zur KeyPoint-Zeit span (kein Scale);\n"
	c += "// Bind = 0: * GetParentTM() des Ticks (slot, -1 = aktuelle Lage)\n"
	c += "void lt_point(float span, int slot, out vec3 p, out vec4 q) {\n"
	c += "\tvec3 kpos; vec4 kdir; vec4 kcol; float ksc; float krad;\n"
	c += "\tkp_state(span, kpos, kdir, kcol, ksc, krad);\n"
	c += "\tp = kpos;\n"
	c += "\tq = quat_mul(kdir, quat_axis(vec3(0.0, 0.0, 1.0), krad));\n"
	c += "\tif (!" + bind + ") {\n"
	c += "\t\tvec3 o = slot < 0 ? Cur_Origin : Hist_Origin[max(slot, 0)];\n"
	c += "\t\tvec4 r = slot < 0 ? Cur_Rot : Hist_Rot[max(slot, 0)];\n"
	c += "\t\tfloat s = slot < 0 ? Cur_Scale : Hist_Scale[max(slot, 0)];\n"
	c += "\t\tp = quat_rot(r, p * s) + o;\n"
	c += "\t\tq = quat_mul(r, q);\n"
	c += "\t}\n"
	c += "}\n"
	c += "// AddPoint: neuer Zwischenpunkt aus dem letzten (c, q) und der neuen Position p / Richtung qd\n"
	c += "void lt_step(float n, vec3 p, vec4 qd, inout vec3 c, inout vec4 q) {\n"
	c += "\tfloat portion = lt_rnd(n, 0);\n"
	c += "\tvec3 vdir = lt_norm(p - c);\n"
	c += "\tvec3 amp = quat_rot(quat_axis(vdir, lt_rnd(n, 1) * TAU), lt_vert_vec(vdir));\n"
	c += "\tamp *= " + u.call("Amp", "0.05") + " + (" + u.call("Amp_2", "0.08") + " - " + u.call("Amp", "0.05") + ") * lt_rnd(n, 2);\n"
	c += "\tc = c * (1.0 - portion) + p * portion + amp;\n"
	c += "\tq = quat_slerp(q, qd, portion);\n"
	c += "}\n"
	c += "// Zwischenpunkt von Tick k (Kettenanfang s = exakter Punkt), höchstens " + steps + " Schritte zurück\n"
	c += "void lt_center(float k, float s, float J, float T, out vec3 c, out vec4 q) {\n"
	c += "\tfloat k0 = max(s, k - " + steps + ".0);\n"
	c += "\tlt_point(lt_tick_span(k0, J, T), lt_slot(k0), c, q);\n"
	c += "\tif (k0 > s) {\n"
	c += "\t\t// Der echte Zwischenpunkt bei k0 liegt neben dem Tick: Startversatz in Größe des Ausschlags\n"
	c += "\t\t// (hält das Zittern nach einer Bewegung am Laufen); stand der Schweif seit dem Kettenanfang\n"
	c += "\t\t// still, zittert auch Angelica nicht\n"
	c += "\t\tvec3 ps; vec4 qs;\n"
	c += "\t\tlt_point(lt_tick_span(s, J, T), lt_slot(s), ps, qs);\n"
	c += "\t\tif (distance(ps, c) > 0.00001) {\n"
	c += "\t\t\tfloat th = lt_rnd(k0, 3) * TAU;\n"
	c += "\t\t\tfloat z = lt_rnd(k0, 4) * 2.0 - 1.0;\n"
	c += "\t\t\tfloat rxy = sqrt(max(0.0, 1.0 - z * z));\n"
	c += "\t\t\tc += vec3(rxy * cos(th), rxy * sin(th), z) * (" + u.call("Amp", "0.05") + " + (" + u.call("Amp_2", "0.08") + " - " + u.call("Amp", "0.05") + ") * lt_rnd(k0, 5));\n"
	c += "\t\t}\n"
	c += "\t}\n"
	c += "\tfor (int i = 1; i <= " + steps + "; i++) {\n"
	c += "\t\tfloat kk = k0 + float(i);\n"
	c += "\t\tif (kk > k) break;\n"
	c += "\t\tvec3 p; vec4 qd;\n"
	c += "\t\tlt_point(lt_tick_span(kk, J, T), lt_slot(kk), p, qd);\n"
	c += "\t\tlt_step(kk, p, qd, c, q);\n"
	c += "\t}\n"
	c += "}\n\n"
	return c


func _gen_vertex_body(declared: Dictionary) -> String:
	var u = func(name, fallback): return KeyPointShader.u(declared, name, fallback)
	var bind = u.call("Bind", "true")
	var c = "\t// --- A3DLtnTrail::TickAnimation / AddPoint / FillVertexBuffer ---\n"
	c += "\tfloat lt_T = max(1.0, Tick_Ms);\n"
	c += "\tfloat lt_life = max(1.0, float(" + u.call("SegLife", str(DEFAULT_SEG_LIFE)) + "));\n"
	c += "\tfloat lt_glob = f_repeat >= 0.0 ? mod(active_time, max(0.001, GlobalLoopTime)) : active_time;\n"
	c += "\tfloat lt_tau = max(0.0, lt_glob - LocalStartTime);\n"
	c += "\t// Ticks je Wiederholung (J) und Wiederholungs-Raster; unendlicher KeyPoint: keine Wiederholung\n"
	c += "\tfloat lt_J = 16777216.0;\n"
	c += "\tfloat lt_full = 0.0;\n"
	c += "\tfloat lt_r = 0.0;\n"
	c += "\tif (!Is_Endless) {\n"
	c += "\t\tlt_J = max(1.0, ceil(loop_active_duration / lt_T));\n"
	c += "\t\tlt_full = loop_full_duration;\n"
	c += "\t\tlt_r = floor(lt_tau / lt_full);\n"
	c += "\t}\n"
	c += "\tfloat lt_now = lt_r * lt_J + min(floor((lt_tau - lt_r * lt_full) / lt_T), lt_J - 1.0);\n"
	c += "\t// Kettenanfang: GFX-Start (Stop leert die Liste) oder alle Punkte verloschen\n"
	c += "\tfloat lt_gap = Is_Endless ? 0.0 : lt_full - (lt_J - 1.0) * lt_T;\n"
	c += "\tfloat lt_s = lt_T >= lt_life ? lt_now : (lt_gap >= lt_life ? lt_r * lt_J : 0.0);\n"
	c += "\t// Ältester lebender Tick (Alter < SegLife)\n"
	c += "\tfloat lt_target = lt_tau - lt_life;\n"
	c += "\tfloat lt_kmin = 0.0;\n"
	c += "\tif (lt_target >= 0.0) {\n"
	c += "\t\tif (Is_Endless) {\n"
	c += "\t\t\tlt_kmin = floor(lt_target / lt_T) + 1.0;\n"
	c += "\t\t} else {\n"
	c += "\t\t\tfloat rt = floor(lt_target / lt_full);\n"
	c += "\t\t\tfloat pt = lt_target - rt * lt_full;\n"
	c += "\t\t\tlt_kmin = pt >= (lt_J - 1.0) * lt_T ? (rt + 1.0) * lt_J : rt * lt_J + floor(pt / lt_T) + 1.0;\n"
	c += "\t\t}\n"
	c += "\t}\n"
	c += "\tfloat lt_old = max(lt_s, lt_kmin);\n"
	c += "\t// Kopf: Zwischen- und Endpunkt zur aktuellen Zeit (Zufall des nächsten Ticks)\n"
	c += "\tfloat lt_tnow = lt_tick_time(lt_now, lt_J, lt_full, lt_T);\n"
	c += "\tbool lt_head = lt_tau > lt_tnow || lt_now > lt_s;\n"
	c += "\tbool lt_draw = lt_head && lt_old <= lt_now;\n\n"

	c += "\t// Paar 0 = Endpunkt, 1 = Kopf-Zwischenpunkt, i >= 2 = Tick lt_now - (i - 2)\n"
	c += "\tint lt_i = int(UV2.x + 0.5);\n"
	c += "\tfloat lt_side = UV2.y;\n"
	c += "\tvec3 lt_c;\n"
	c += "\tvec4 lt_q;\n"
	c += "\tfloat lt_u;\n"
	c += "\tfloat lt_age = 0.0;\n"
	c += "\tfloat lt_span_now = Is_Endless ? lt_tau : lt_tau - lt_r * lt_full;\n"
	c += "\tif (lt_i <= 1) {\n"
	c += "\t\tvec3 lt_p; vec4 lt_qd;\n"
	c += "\t\tlt_point(lt_span_now, -1, lt_p, lt_qd);\n"
	c += "\t\tif (lt_i == 0) {\n"
	c += "\t\t\tlt_c = lt_p;\n"
	c += "\t\t\tlt_q = lt_qd;\n"
	c += "\t\t\tlt_u = lt_tex_u(lt_now - lt_s + 2.0);\n"
	c += "\t\t} else {\n"
	c += "\t\t\tlt_center(lt_now, lt_s, lt_J, lt_T, lt_c, lt_q);\n"
	c += "\t\t\tlt_step(lt_now + 1.0, lt_p, lt_qd, lt_c, lt_q);\n"
	c += "\t\t\tlt_u = lt_tex_u(lt_now - lt_s + 1.0);\n"
	c += "\t\t}\n"
	c += "\t} else {\n"
	c += "\t\t// Überzählige Paare fallen auf den ältesten Eintrag (Dreiecke ohne Fläche)\n"
	c += "\t\tfloat lt_k = max(lt_now - float(lt_i - 2), lt_old);\n"
	c += "\t\tlt_center(lt_k, lt_s, lt_J, lt_T, lt_c, lt_q);\n"
	c += "\t\tlt_u = lt_tex_u(lt_k - lt_s);\n"
	c += "\t\tlt_age = lt_tau - lt_tick_time(lt_k, lt_J, lt_full, lt_T);\n"
	c += "\t}\n"
	c += "\t// Kante Pos -> Pos_2; Bind = 1: GFX-Raum -> Welt (world_vertex_coords)\n"
	c += "\tvec3 lt_edge = lt_side < 0.5 ? " + u.call("Pos", "vec3(0.0)") + " : " + u.call("Pos_2", "vec3(0.0)") + ";\n"
	c += "\tvec3 lt_v = quat_rot(lt_q, lt_edge * (" + bind + " ? 1.0 : Cur_Scale)) + lt_c;\n"
	c += "\tif (" + bind + ") lt_v = (MODEL_MATRIX * vec4(lt_v, 1.0)).xyz;\n"
	c += "\tVERTEX = lt_draw ? lt_v : MODEL_MATRIX[3].xyz;\n"
	c += "\t// MultiplyAlpha(Restleben / SegLife) auf die aktuelle KeyPoint-Farbe\n"
	c += "\tfloat lt_alpha = lt_draw ? clamp(1.0 - lt_age / lt_life, 0.0, 1.0) : 0.0;\n"
	c += "\tv_color = vec4(k_color.rgb, k_color.a * lt_alpha);\n"
	c += "\tcell_uv = vec2(lt_u, lt_side);\n"
	return c

# FillVertexBuffer setzt tu / tv direkt: kein Spritesheet, kein TileMode-Lauf, kein UV-Tausch
func _gen_uv_post(_declared: Dictionary) -> String:
	return "\tUV = cell_uv;\n"

# Strip aus _pairs Paaren (neuester zuerst): UV2 = (Paar-Index, Seite 0 = Pos / 1 = Pos_2)
func _build_mesh(_parsed_data: Dictionary) -> ArrayMesh:
	var verts = PackedVector3Array()
	var uv2s = PackedVector2Array()
	var indices = PackedInt32Array()
	for i in range(_pairs):
		for s in range(2):
			verts.append(Vector3.ZERO)
			uv2s.append(Vector2(float(i), float(s)))
	for i in range(_pairs - 1):
		var b = i * 2
		indices.append_array([b, b + 1, b + 2, b + 2, b + 1, b + 3])

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(uv2s)
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
