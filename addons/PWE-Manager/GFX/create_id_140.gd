@tool
extends Object

# ====================================================
# GFXELEMENTID 140 = ID_ELE_TYPE_RING (A3DGFXRing)
# ====================================================
# Ein Ring- bzw. Kegelmantel-Band um die lokale Y-Achse aus Sects Segmenten (Standard 36):
#   unterer Radius = Radius + Height/2 * tan(Pitch), oberer = Radius - Height/2 * tan(Pitch)
#   (tan(Pitch) auf ±Radius / (Height/2) begrenzt -> höchstens eine Kegelspitze)
#   Y von -Height/2 bis +Height/2 (OrgAtCenter) bzw. 0 bis Height
# Welt = Scale(RadScale, HeiScale, RadScale) * Rotation(KeyPoint-Dir * Rad_2D um Y) + KeyPoint-Pos
# Textur: U einmal um den Ring, V von oben (0) nach unten (1).
# A3DGFXRing::FillVertexBuffer ignoriert UReverse / VReverse / UVExchg.
# Der KeyPoint-Zustand wird originalgetreu von gfx_keypoint_shader.gd erzeugt.
#
# Basis für weitere KeyPoint-gesteuerte Elemente (150 ...): Diese erben per
# extends "create_id_140.gd" und überschreiben die ELEMENT-HOOKS (siehe unten).
# ====================================================

const DEFAULT_SECTS = 36 # _default_sects in A3DGFXRing.cpp
const KeyPointShader = preload("gfx_keypoint_shader.gd")

func execute(root_node: Node):
	var target_nodes = _find_target_nodes(root_node)

	if target_nodes.is_empty():
		push_warning("Keine Nodes mit der ID " + _element_id() + " gefunden!")
		return

	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Create " + _node_name() + " for ID_" + _element_id())

	# 1. Nodes nach Parent (Header) gruppieren
	var header_groups = {}
	for node in target_nodes:
		var parent = node.get_parent()
		if not header_groups.has(parent):
			header_groups[parent] = []
		header_groups[parent].append(node)

	# 2. Für jeden Header die max. Loop-Zeit berechnen und Shader generieren
	for parent in header_groups.keys():
		var group_nodes = header_groups[parent]

		var max_group_time = _get_max_time_for_header(parent)

		if max_group_time <= 0.0:
			max_group_time = 3000.0

		for node in group_nodes:
			_create_with_shader(node, root_node, undo_redo, max_group_time)

	undo_redo.commit_action()
	print(_node_name(), "-Meshes und Shader-Materialien für ", target_nodes.size(), " ID_", _element_id(), "-Nodes erstellt.")


func _get_max_time_for_header(header_node: Node) -> float:
	var max_time = 0.0

	for child in header_node.get_children():
		if child.name.begins_with("Element_"):
			var t_start = 0.0
			var t_total = 0.0
			var is_endless = false

			var data = child.get("parsed_data")
			if typeof(data) == TYPE_DICTIONARY:
				t_start = float(data.get("StartTime", 0.0))
				t_total = t_start
				if data.has("_keypoints"):
					for kp in data["_keypoints"]:
						if kp.has("TimeSpan"):
							var ts = float(kp["TimeSpan"])
							if ts == -1.0:
								is_endless = true
							elif ts > 0.0:
								t_total += ts
			else:
				if child.get("StartTime") != null:
					t_start = float(child.get("StartTime"))
					t_total = t_start

				var kp_idx = 0
				while true:
					var ts_val = child.get("KeyPoint " + str(kp_idx) + "/TimeSpan")
					if ts_val != null:
						var ts = float(ts_val)
						if ts == -1.0:
							is_endless = true
						elif ts > 0.0:
							t_total += ts
						kp_idx += 1
					else:
						break

			if not is_endless and t_total > max_time:
				max_time = t_total

	return max_time

func _find_target_nodes(current_node: Node) -> Array:
	var results = []
	if current_node.name.contains("_ID_" + _element_id()):
		results.append(current_node)

	for child in current_node.get_children():
		results.append_array(_find_target_nodes(child))

	return results

func _gather_ctrl_nodes(node: Node) -> Array:
	var results = []
	for child in node.get_children():
		if child.name == _node_name():
			continue

		var has_params = false
		if not KeyPointShader.get_node_params(child).is_empty():
			has_params = true
			results.append(child)

		if not has_params:
			results.append_array(_gather_ctrl_nodes(child))

	return results

func _create_with_shader(parent_node: Node3D, root_node: Node, undo_redo: EditorUndoRedoManager, max_group_time: float):
	if parent_node.has_node(_node_name()):
		return

	var mesh_instance = build_element_node(parent_node, max_group_time)
	if mesh_instance == null:
		return

	undo_redo.add_do_method(parent_node, "add_child", mesh_instance)
	undo_redo.add_do_property(mesh_instance, "owner", root_node)
	undo_redo.add_undo_method(parent_node, "remove_child", mesh_instance)
	undo_redo.add_do_reference(mesh_instance)


# ====================================================
# BAUT MESH + SHADER-MATERIAL (ohne Szene / UndoRedo -> auch für Tests nutzbar)
# ====================================================
func build_element_node(parent_node: Node, max_group_time: float) -> MeshInstance3D:
	var parsed_data = parent_node.get("parsed_data")
	var param_types = parent_node.get("PARAM_TYPES")

	if typeof(parsed_data) != TYPE_DICTIONARY or typeof(param_types) != TYPE_DICTIONARY:
		return null

	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = _node_name()
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.extra_cull_margin = 1000.0

	var uniform_assignments = {}
	var shader = Shader.new()
	shader.code = preload("gfx_parser.gd").add_gfx_alpha(_build_shader_code(parent_node, parsed_data, param_types, max_group_time, uniform_assignments))
	# Mesh erst nach dem Shader: die Hooks kennen dann die Strukturwerte des Elements
	mesh_instance.mesh = _build_mesh(parsed_data)

	var mat = ShaderMaterial.new()
	mat.shader = shader

	for uniform_name in uniform_assignments.keys():
		var val = uniform_assignments[uniform_name]
		if val != null:
			if val is Color: mat.set_shader_parameter(uniform_name, Vector4(val.r, val.g, val.b, val.a))
			elif typeof(val) == TYPE_STRING:
				if val.to_lower() == "true": mat.set_shader_parameter(uniform_name, true)
				elif val.to_lower() == "false": mat.set_shader_parameter(uniform_name, false)
				elif val.is_valid_int() and not "." in val: mat.set_shader_parameter(uniform_name, int(val))
				elif val.is_valid_float(): mat.set_shader_parameter(uniform_name, float(val))
				else: mat.set_shader_parameter(uniform_name, val)
			else: mat.set_shader_parameter(uniform_name, val)

	mat.render_priority = clampi(int(parsed_data.get("Priority", 0)), Material.RENDER_PRIORITY_MIN, Material.RENDER_PRIORITY_MAX)
	mesh_instance.material_override = mat
	return mesh_instance


func _build_shader_code(parent_node: Node, parsed_data: Dictionary, param_types: Dictionary, max_group_time: float, uniform_assignments: Dictionary) -> String:
	var declared = {}

	# ====================================================
	# RENDER MODE, DESTBLEND, WARP & ZENABLE
	# ====================================================
	var render_blend_mode = "blend_mix"
	var dest_blend_val = str(parsed_data.get("DestBlend", ""))
	if dest_blend_val == "2" or dest_blend_val == "4":
		render_blend_mode = "blend_add"
	elif dest_blend_val == "6":
		render_blend_mode = "blend_mix"

	# Jedes Element hat eine "Warp:"-Zeile -> nur ein AKTIVER Warp erzwingt blend_mix
	var has_warp = _as_bool(parsed_data.get("Warp", "0"))
	if has_warp:
		render_blend_mode = "blend_mix"
	# ZEnable des Elements und 2DRender der GFX
	var z_enable = preload("gfx_parser.gd").z_test_enabled(parent_node, parsed_data)
	var tile_mode = _as_bool(parsed_data.get("TileMode", "0"))

	var shader_code = "shader_type spatial;\n"
	shader_code += "render_mode " + render_blend_mode + ", depth_draw_opaque, cull_disabled, unshaded"
	if not z_enable:
		shader_code += ", depth_test_disabled"
	shader_code += ";\n\n"
	if has_warp:
		shader_code += "uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;\n"
	shader_code += "varying float v_current_time;\n"
	shader_code += "varying vec4 v_color;\n"
	shader_code += "varying float v_active;\n\n"

	var ctrl_methods = []
	for child in _gather_ctrl_nodes(parent_node):
		if child.name.findn("Affector") == -1:
			ctrl_methods.append(child)

	# ====================================================
	# ZEITEINSTELLUNGEN
	# ====================================================
	var start_time = _element_start_time(parsed_data)
	var local_total_time = start_time
	var is_endless = false
	for kp_block in parsed_data.get("_keypoints", []):
		if kp_block.has("TimeSpan"):
			var ts = float(kp_block["TimeSpan"])
			if ts == -1:
				is_endless = true
			elif ts > 0:
				local_total_time += ts
	if local_total_time <= start_time and not is_endless:
		local_total_time = start_time + 3000.0

	shader_code += "group_uniforms Time_Settings;\n"
	shader_code += "uniform bool Time_Manual = false;\n"
	shader_code += "uniform float Time : hint_range(0.0, " + _f(max_group_time) + ") = 0.0;\n"
	shader_code += "uniform float GlobalLoopTime = " + _f(max_group_time) + ";\n"
	shader_code += "uniform float LocalStartTime = " + _f(start_time) + ";\n"
	shader_code += "uniform float LocalTotalTime = " + _f(local_total_time) + ";\n"
	shader_code += "uniform bool Is_Endless = " + ("true" if is_endless else "false") + ";\n"
	shader_code += "group_uniforms;\n\n"
	for n in ["Time_Manual", "Time", "GlobalLoopTime", "LocalStartTime", "LocalTotalTime", "Is_Endless"]:
		declared[n] = true

	# ====================================================
	# HAUPT-PARAMETER (inkl. Element-Geometrie)
	# ====================================================
	shader_code += "group_uniforms Main_Parameters;\n"
	for key in parsed_data.keys():
		if key.begins_with("_") or _skip_main_param(key): continue
		var godot_type = param_types.get(key, TYPE_STRING)
		if godot_type == TYPE_STRING:
			if key in ["TexFile", "ShaderTex"]:
				var hint = " : repeat_enable" if (key == "TexFile" and tile_mode) else ""
				shader_code += KeyPointShader.declare(declared, "sampler2D", key, hint)
				var tex_path_raw = str(parsed_data[key])
				if tex_path_raw != "":
					# Textur aus den Spieldaten (gfx_sources.gd)
					var loaded_tex = preload("gfx_sources.gd").texture(tex_path_raw)
					if loaded_tex != null:
						uniform_assignments[key] = loaded_tex
			else:
				shader_code += "// String: " + key + " = " + str(parsed_data[key]).replace("\\", "/") + "\n"
		else:
			var glsl_type = KeyPointShader.godot_type_to_glsl(godot_type)
			if glsl_type != "":
				shader_code += KeyPointShader.declare(declared, glsl_type, key)
				uniform_assignments[key] = parent_node.get(key)
	if not declared.has("TexFile"):
		shader_code += KeyPointShader.declare(declared, "sampler2D", "TexFile", " : hint_default_white")
	shader_code += "group_uniforms;\n\n"

	# ====================================================
	# KEYPOINTS + CTRLMETHODS
	# ====================================================
	var kp_array = parsed_data.get("_keypoints", [])
	for k in range(kp_array.size()):
		shader_code += "group_uniforms KeyPoint_" + str(k) + ";\n"
		for kp_key in kp_array[k].keys():
			if kp_key.begins_with("_"): continue
			var glsl_type = KeyPointShader.godot_type_to_glsl(param_types.get(kp_key, TYPE_STRING))
			var uniform_name = "KP_" + str(k) + "_" + kp_key
			if glsl_type != "":
				shader_code += KeyPointShader.declare(declared, glsl_type, uniform_name)
				uniform_assignments[uniform_name] = parent_node.get("KeyPoint " + str(k) + "/" + kp_key)
		shader_code += "group_uniforms;\n\n"
	shader_code += KeyPointShader.declare_ctrl_uniforms(ctrl_methods, declared, uniform_assignments)

	# Element-spezifische Uniforms (Hook)
	shader_code += _gen_element_uniforms(parent_node, parsed_data, declared, uniform_assignments, ctrl_methods)

	shader_code += KeyPointShader.gen_helper_functions(ctrl_methods)
	shader_code += KeyPointShader.gen_kp_state(parsed_data, ctrl_methods, declared)
	# Element-spezifische Funktionen (Hook)
	shader_code += _gen_element_functions(declared)

	# ====================================================
	# VERTEX SHADER
	# ====================================================
	shader_code += "void vertex() {\n"
	shader_code += "\t// --- ZEIT-SYNCHRONISATION (identisch zu ID_100) ---\n"
	shader_code += "\tfloat active_time = Time_Manual ? Time : (TIME * 1000.0);\n"
	shader_code += "\tv_current_time = 0.0;\n\n"
	shader_code += "\tfloat f_repeat = float(" + KeyPointShader.u(declared, "RepeatCount", "1") + ");\n"
	shader_code += "\tfloat f_delay = float(" + KeyPointShader.u(declared, "RepeatDelay", "0") + ");\n\n"
	shader_code += "\tfloat loop_active_duration = max(0.001, LocalTotalTime - LocalStartTime);\n"
	shader_code += "\tfloat loop_full_duration = loop_active_duration + max(0.0, f_delay);\n\n"
	shader_code += "\tif (LocalTotalTime <= 0.0) {\n"
	shader_code += "\t\tv_current_time = active_time;\n"
	shader_code += "\t} else {\n"
	shader_code += "\t\tfloat t_global = active_time;\n"
	shader_code += "\t\tif (f_repeat >= 0.0) {\n"
	shader_code += "\t\t\tt_global = mod(active_time, max(0.001, GlobalLoopTime));\n"
	shader_code += "\t\t}\n"
	shader_code += "\t\tfloat t_since_start = t_global - LocalStartTime;\n\n"
	shader_code += "\t\tif (t_since_start < 0.0) {\n"
	shader_code += "\t\t\tv_current_time = t_global;\n"
	shader_code += "\t\t} else {\n"
	shader_code += "\t\t\tfloat current_loop = floor(t_since_start / loop_full_duration);\n"
	shader_code += "\t\t\tif (f_repeat >= 0.0 && current_loop >= f_repeat) {\n"
	shader_code += "\t\t\t\tv_current_time = t_global;\n"
	shader_code += "\t\t\t} else {\n"
	shader_code += "\t\t\t\tfloat t_in_loop = mod(t_since_start, loop_full_duration);\n"
	shader_code += "\t\t\t\tv_current_time = LocalStartTime + t_in_loop;\n"
	shader_code += "\t\t\t}\n"
	shader_code += "\t\t}\n"
	shader_code += "\t}\n"
	shader_code += "\tv_active = (Is_Endless || (v_current_time >= LocalStartTime && v_current_time <= LocalTotalTime)) ? 1.0 : 0.0;\n\n"

	shader_code += "\t// --- KEYPOINT-ZUSTAND ---\n"
	shader_code += "\tvec3 k_pos; vec4 k_dir; vec4 k_color; float k_scale; float k_rad;\n"
	shader_code += "\tkp_state(max(0.0, v_current_time - LocalStartTime), k_pos, k_dir, k_color, k_scale, k_rad);\n"
	shader_code += "\tvec2 cell_uv = UV;\n\n"

	# Geometrie, Farbe und Zell-UV (Hook): setzt VERTEX, v_color, cell_uv
	shader_code += _gen_vertex_body(declared)

	# ====================================================
	# UV: SPRITESHEET (Element-Zeit) bzw. TILE MODE
	# ====================================================
	shader_code += "\n\t// --- TEXTUR-ANIMATION (wie ID_100) ---\n"
	shader_code += "\tfloat f_cols = max(1.0, float(" + KeyPointShader.u(declared, "TexCol", "1") + "));\n"
	shader_code += "\tfloat f_rows = max(1.0, float(" + KeyPointShader.u(declared, "TexRow", "1") + "));\n"
	shader_code += "\tfloat f_interval = max(1.0, float(" + KeyPointShader.u(declared, "TexInterval", "50") + "));\n"
	shader_code += "\tfloat frame = mod(floor(v_current_time / f_interval), f_cols * f_rows);\n"
	shader_code += "\tUV = (vec2(mod(frame, f_cols), floor(frame / f_cols)) + cell_uv) / vec2(f_cols, f_rows);\n"
	if declared.has("TileMode"):
		shader_code += "\tif (TileMode) {\n"
		shader_code += "\t\tUV = cell_uv * vec2(f_cols, f_rows) + (v_current_time / 1000.0) * vec2(" + KeyPointShader.u(declared, "TexSpeed_1", "0.0") + ", " + KeyPointShader.u(declared, "TexSpeed_2", "0.0") + ");\n"
		shader_code += "\t}\n"
	shader_code += _gen_uv_post(declared)
	shader_code += "}\n\n"

	# ====================================================
	# FRAGMENT SHADER
	# ====================================================
	shader_code += "void fragment() {\n"
	shader_code += "\tif (v_active < 0.5) {\n"
	shader_code += "\t\tdiscard;\n"
	shader_code += "\t}\n\n"
	shader_code += "\tvec4 tex_color = texture(TexFile, UV);\n"
	if has_warp:
		shader_code += "\n\t// --- WARP (HEAT DISTORTION, wie ID_100) ---\n"
		shader_code += "\tvec3 normal_map = tex_color.rgb * 2.0 - 1.0;\n"
		shader_code += "\tnormal_map = normalize(mix(vec3(0.0, 0.0, 1.0), normal_map, tex_color.a));\n"
		shader_code += "\tvec2 warp_dir = normal_map.xy / max(normal_map.z, 0.1);\n"
		shader_code += "\tALBEDO = texture(screen_texture, SCREEN_UV + warp_dir * 0.50 * v_color.a).rgb;\n"
		shader_code += "\tALPHA = tex_color.a;\n"
	else:
		shader_code += "\ttex_color *= v_color;\n"
		if render_blend_mode == "blend_mix":
			shader_code += "\t// Alpha leicht dämpfen, damit Mix-Sprites nicht zu massiv wirken (wie ID_100)\n"
			shader_code += "\ttex_color.a *= 0.70;\n"
		shader_code += "\tALBEDO = tex_color.rgb;\n"
		shader_code += "\tALPHA = tex_color.a;\n"
	shader_code += "}\n"
	return shader_code


# ====================================================
# ELEMENT-HOOKS (Standard = A3DGFXRing, überschrieben von create_id_150 ...)
# ====================================================
func _element_id() -> String:
	return "140"

func _node_name() -> String:
	return "Ring_GFX"

func _element_start_time(parsed_data: Dictionary) -> float:
	return float(parsed_data.get("StartTime", 0.0))

# Datei-Zeilen ohne eigenen Uniform (z.B. die Gitterpunkte der 210)
func _skip_main_param(_key: String) -> bool:
	return false

# Zusätzliche Uniforms (nach den KeyPoint-/CtrlMethod-Uniforms)
func _gen_element_uniforms(_parent_node: Node, _parsed_data: Dictionary, _declared: Dictionary, _uniform_assignments: Dictionary, _ctrl_methods: Array) -> String:
	return ""

# Zusätzliche GLSL-Funktionen (nach quat_* und kp_state)
func _gen_element_functions(_declared: Dictionary) -> String:
	return ""

# Muss VERTEX, v_color und cell_uv setzen.
# Verfügbar: k_pos, k_dir, k_color, k_scale, k_rad, active_time, v_current_time, UV (Mesh)
func _gen_vertex_body(declared: Dictionary) -> String:
	var u_radius = KeyPointShader.u(declared, "Radius", "0.0")
	var u_height = KeyPointShader.u(declared, "Height", "0.0")
	var c = "\t// --- A3DGFXRing::InitStreamBuffer (UV.x = Segment / Sects, UV.y = 0 oben / 1 unten) ---\n"
	c += "\tfloat half_h = 0.5 * " + u_height + ";\n"
	c += "\tfloat tan_limit = " + u_radius + " / max(half_h, 0.000001);\n"
	c += "\tfloat d_radius = half_h * clamp(tan(" + KeyPointShader.u(declared, "Pitch", "0.0") + "), -tan_limit, tan_limit);\n"
	c += "\tbool is_top = UV.y < 0.5;\n"
	c += "\tfloat ring_r = is_top ? " + u_radius + " - d_radius : " + u_radius + " + d_radius;\n"
	c += "\tfloat ring_y = " + KeyPointShader.u(declared, "OrgAtCenter", "true") + " ? (is_top ? half_h : -half_h) : (is_top ? " + u_height + " : 0.0);\n"
	c += "\tfloat ang = UV.x * TAU;\n"
	c += "\tvec3 local_pos = vec3(ring_r * cos(ang), ring_y, ring_r * sin(ang));\n\n"
	c += "\t// --- FillVertexBuffer: Scale * GetTranMatrix(kp, _unit_y) ---\n"
	c += "\tfloat rad_scale = " + KeyPointShader.u(declared, "NoRadScale", "false") + " ? 1.0 : k_scale;\n"
	c += "\tfloat hei_scale = " + KeyPointShader.u(declared, "NoHeiScale", "false") + " ? 1.0 : k_scale;\n"
	c += "\tlocal_pos *= vec3(rad_scale, hei_scale, rad_scale);\n"
	c += "\t// Rad_2D dreht den Ring um seine eigene Y-Achse\n"
	c += "\tVERTEX = quat_rot(quat_mul(k_dir, quat_axis(vec3(0.0, 1.0, 0.0), k_rad)), local_pos) + k_pos;\n"
	c += "\tv_color = k_color;\n"
	c += "\t// Der Ring nutzt UReverse / VReverse / UVExchg nicht\n"
	return c

# Nach Spritesheet / TileMode (z.B. UV-Tausch)
func _gen_uv_post(_declared: Dictionary) -> String:
	return ""

# Band aus Sects Segmenten: UV.x = i / Sects (Winkel), UV.y = 0 oben / 1 unten.
# Die echte Form rechnet der Vertex-Shader aus Radius / Height / Pitch.
func _build_mesh(parsed_data: Dictionary) -> ArrayMesh:
	var sects = int(parsed_data.get("Sects", 0))
	if sects <= 0:
		sects = DEFAULT_SECTS
	var radius = float(parsed_data.get("Radius", 1.0))
	var verts = PackedVector3Array()
	var uvs = PackedVector2Array()
	var indices = PackedInt32Array()
	for i in range(sects + 1):
		var u = float(i) / float(sects)
		var a = u * TAU
		var p = Vector3(cos(a), 0.0, sin(a)) * radius
		verts.append(p)
		uvs.append(Vector2(u, 1.0)) # unten
		verts.append(p)
		uvs.append(Vector2(u, 0.0)) # oben
	for i in range(sects):
		var b = i * 2
		indices.append_array([b, b + 1, b + 2, b + 2, b + 1, b + 3])

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _f(value: float) -> String:
	return "%.6f" % value

func _as_bool(value) -> bool:
	var s = str(value).strip_edges().to_lower()
	return s == "1" or s == "true"
