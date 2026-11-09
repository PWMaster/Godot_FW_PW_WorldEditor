@tool
extends Object

func execute(root_node: Node):
	var target_nodes = _find_id_110_nodes(root_node)
	
	if target_nodes.is_empty():
		push_warning("Keine Nodes mit der ID 110 gefunden!")
		return
		
	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Create SpeedTrail Plane for ID_110")
	
	# 1. Nodes nach Parent gruppieren
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
			_create_sprite_with_shader(node, root_node, undo_redo, max_group_time)
			
	undo_redo.commit_action()
	print("SpeedTrails und Shader-Materialien für ", target_nodes.size(), " ID_110-Nodes erstellt.")


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
	
func _find_id_110_nodes(current_node: Node) -> Array:
	var results = []
	if current_node.name.contains("_ID_110"):
		results.append(current_node)
		
	for child in current_node.get_children():
		results.append_array(_find_id_110_nodes(child))
		
	return results

func _gather_ctrl_nodes(node: Node) -> Array:
	var results = []
	for child in node.get_children():
		if child.name == "SpeedTrailPlane": 
			continue
			
		var has_params = false
		if not _get_node_params(child).is_empty():
			has_params = true
			results.append(child)
				
		if not has_params:
			results.append_array(_gather_ctrl_nodes(child))
			
	return results

func _get_node_params(child: Node) -> Dictionary:
	if child.get_script() != null:
		var constants = child.get_script().get_script_constant_map()
		# Nur Steuer-Skripte (Dictionary); Element-Skripte haben KNOWN_PARAMS als Array
		for key in ["KNOWN_PARAMS", "PARAMS"]:
			if constants.has(key) and constants[key] is Dictionary: return constants[key]
	return {}

# Ohne Szene / UndoRedo (z.B. Unter-GFX eines Containers): hängt den Node direkt an und gibt ihn zurück
func build_element_node(parent_node: Node3D, max_group_time: float) -> Node3D:
	_create_sprite_with_shader(parent_node, null, null, max_group_time)
	return parent_node.get_node_or_null("SpeedTrailPlane")

# undo_redo = null: direkt anhängen statt über UndoRedo
func _create_sprite_with_shader(parent_node: Node3D, root_node: Node, undo_redo, max_group_time: float):
	# ====================================================
	# 0. MESH ERSETZEN (Statt Sprite3D nutzen wir MeshInstance3D & PlaneMesh)
	# ====================================================
	if parent_node.has_node("SpeedTrailPlane"):
		return
		
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "SpeedTrailPlane"
	
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.extra_cull_margin = 1000.0
	
	var parsed_data = parent_node.get("parsed_data")
	var param_types = parent_node.get("PARAM_TYPES")
	
	if typeof(parsed_data) != TYPE_DICTIONARY or typeof(param_types) != TYPE_DICTIONARY:
		return
		
	var plane_mesh = PlaneMesh.new()
	var w = 4.0
	var h = 1.0
	if parsed_data.has("Width"): w = float(parsed_data["Width"]) * 2.0
	if parsed_data.has("Height"): h = float(parsed_data["Height"]) * 2.0
	plane_mesh.size = Vector2(w, h) 
	plane_mesh.subdivide_width = 50 
	plane_mesh.subdivide_depth = 2
	mesh_instance.mesh = plane_mesh
	
	if undo_redo != null:
		undo_redo.add_do_method(parent_node, "add_child", mesh_instance)
		undo_redo.add_do_property(mesh_instance, "owner", root_node) 
		undo_redo.add_undo_method(parent_node, "remove_child", mesh_instance)
		undo_redo.add_do_reference(mesh_instance)
	else:
		parent_node.add_child(mesh_instance)
	
	var mat = ShaderMaterial.new()
	var shader = Shader.new()
	
	# ====================================================
	# RENDER MODE, DESTBLEND & PRIORITY
	# ====================================================
	var render_blend_mode = "blend_mix"
	var priority_val = 0
	
	var dest_blend_val = null
	if parsed_data.has("DestBlend"):
		dest_blend_val = str(parsed_data["DestBlend"])
	elif parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY:
		if parsed_data["MainParameters"].has("DestBlend"):
			dest_blend_val = str(parsed_data["MainParameters"]["DestBlend"])
			
	if dest_blend_val == "2" or dest_blend_val == "4":
		render_blend_mode = "blend_add"
	elif dest_blend_val == "6":
		render_blend_mode = "blend_mix"
		
	if parsed_data.has("Priority"):
		priority_val = int(parsed_data["Priority"])
	elif parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY:
		if parsed_data["MainParameters"].has("Priority"):
			priority_val = int(parsed_data["MainParameters"]["Priority"])

	var has_warp = false
	var warp_active = false
	if parsed_data.has("Warp"):
		has_warp = true
		warp_active = _as_bool(parsed_data["Warp"])
	elif parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY and parsed_data["MainParameters"].has("Warp"):
		has_warp = true
		warp_active = _as_bool(parsed_data["MainParameters"]["Warp"])
		
	# Jedes Element hat eine "Warp:"-Zeile -> nur ein AKTIVER Warp (Warp: 1) erzwingt blend_mix
	if warp_active:
		render_blend_mode = "blend_mix"
		
	var rot_from_view = false
	if parsed_data.has("RotFromView"):
		rot_from_view = bool(parsed_data["RotFromView"])
	elif parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY:
		if parsed_data["MainParameters"].has("RotFromView"):
			rot_from_view = bool(parsed_data["MainParameters"]["RotFromView"])

	# ====================================================
	# SHADER KOPF
	# ====================================================
	var shader_code = "shader_type spatial;\n"
	shader_code += "render_mode " + render_blend_mode + ", depth_draw_opaque, cull_disabled, unshaded"
	# 2DRender der GFX: ohne Tiefentest (A3DGFXEx::IsZTestEnable)
	if preload("gfx_parser.gd").gfx_2d_render(parent_node):
		shader_code += ", depth_test_disabled"
	shader_code += ";\n\n"
	
	if has_warp:
		shader_code += "uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;\n"

	shader_code += "varying float v_current_time;\n\n"
	
	# --- TRAIL SPECIFIC UNIFORMS ---
	shader_code += "// --- TRAIL PARAMETER ---\n"
	shader_code += "uniform int SegLife : hint_range(25, 10000, 25) = 1000;\n"
	shader_code += "uniform float Speed_Vel = 1.0;\n"
	shader_code += "uniform float FadeLength : hint_range(0.01, 0.5) = 0.15;\n\n"
	
	var uniform_assignments = {} 
	
	var all_ctrl_nodes = _gather_ctrl_nodes(parent_node)
	var ctrl_methods = []
	var affectors = []
	
	for child in all_ctrl_nodes:
		if child.name.findn("Affector") != -1:
			affectors.append(child)
		else:
			ctrl_methods.append(child)
			
	var global_ctrl_idx = 0
	
	# ====================================================
	# ZEITEINSTELLUNGEN
	# ====================================================
	var start_time = 0.0
	if parsed_data.has("StartTime"):
		start_time = float(parsed_data["StartTime"])
		
	var local_total_time = start_time
	var is_endless = false
	
	if parsed_data.has("_keypoints"):
		var kp_array = parsed_data["_keypoints"]
		for k in range(kp_array.size()):
			var kp_block = kp_array[k]
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
	shader_code += "uniform float Time : hint_range(0.0, " + str(max_group_time) + ") = 0.0;\n"
	shader_code += "uniform float GlobalLoopTime = " + str(max_group_time) + ";\n"
	shader_code += "uniform float LocalStartTime = " + str(start_time) + ";\n"
	shader_code += "uniform float LocalTotalTime = " + str(local_total_time) + ";\n"
	shader_code += "uniform bool Is_Endless = " + ("true" if is_endless else "false") + ";\n"
	shader_code += "group_uniforms;\n\n"
	
	# ====================================================
	# HAUPT-PARAMETER (Fügt auch OrgPos1, OrgPos2 etc. hinzu)
	# ====================================================
	shader_code += "group_uniforms Main_Parameters;\n"
	for key in parsed_data.keys():
		if key.begins_with("_") or key in ["Bind", "BindEle"]: continue 
		
		var godot_type = param_types.get(key, TYPE_STRING)
		
		if godot_type == TYPE_STRING:
			if key in ["TexFile", "Tex File", "ShaderTex", "ShaderFile"]:
				var uniform_name = key.replace(" ", "") 
				shader_code += "uniform sampler2D " + uniform_name + ";\n"
				
				var tex_path_raw = str(parsed_data[key])
				if tex_path_raw != "":
					# Textur aus den Spieldaten (gfx_sources.gd)
					var loaded_tex = preload("gfx_sources.gd").texture(tex_path_raw)
					if loaded_tex != null:
						uniform_assignments[uniform_name] = loaded_tex
			else:
				shader_code += "// String: " + key + " = " + str(parsed_data[key]) + "\n"
		else:
			var glsl_type = _godot_type_to_glsl(godot_type)
			if glsl_type != "":
				# --- KORREKTUR: Verhindere doppelte Definition der Trail-Parameter ---
				if not key in ["SegLife", "Speed_Vel", "FadeLength"]:
					shader_code += "uniform " + glsl_type + " " + key + ";\n"
				
				# Den Wert weisen wir trotzdem zu, falls er in der Node existiert!
				uniform_assignments[key] = parent_node.get(key)
	shader_code += "group_uniforms;\n\n"
	
	# ====================================================
	# KEYPOINTS UND CTRL METHODS
	# ====================================================
	if parsed_data.has("_keypoints"):
		var kp_array = parsed_data["_keypoints"]
		for k in range(kp_array.size()):
			shader_code += "group_uniforms KeyPoint_" + str(k) + ";\n"
			var kp_block = kp_array[k]
			
			for kp_key in kp_block.keys():
				if kp_key.begins_with("_"): continue
				
				var godot_type = param_types.get(kp_key, TYPE_STRING)
				var glsl_type = _godot_type_to_glsl(godot_type)
				var uniform_name = "KP_" + str(k) + "_" + kp_key
				
				if glsl_type != "":
					shader_code += "uniform " + glsl_type + " " + uniform_name + ";\n"
					var prop_path = "KeyPoint " + str(k) + "/" + kp_key
					uniform_assignments[uniform_name] = parent_node.get(prop_path)
					
			shader_code += "group_uniforms;\n\n"

			var ctrl_count = 0
			if kp_block.has("CtrlMethodCount"):
				ctrl_count = int(kp_block["CtrlMethodCount"])
				
			for i in range(ctrl_count):
				if global_ctrl_idx < ctrl_methods.size():
					var child = ctrl_methods[global_ctrl_idx]
					var params_dict = _get_node_params(child)
					
					if not params_dict.is_empty():
						var ctrl_type = child.get("CtrlType")
						if ctrl_type == null: ctrl_type = "Unknown"
						
						var group_name = "_" + str(global_ctrl_idx) + "_Ctrl_Methode_" + str(ctrl_type)
						var prefix = "CtrlMethod_" + str(global_ctrl_idx) + "_"
						
						shader_code += "group_uniforms " + group_name + ";\n"
						for param in params_dict.keys():
							var godot_type_ctrl = params_dict.get(param) 
							var glsl_type_ctrl = _godot_type_to_glsl(godot_type_ctrl)
							if glsl_type_ctrl != "":
								var uniform_name_ctrl = prefix + param
								shader_code += "uniform " + glsl_type_ctrl + " " + uniform_name_ctrl + ";\n"
								uniform_assignments[uniform_name_ctrl] = child.get(param)
						shader_code += "group_uniforms;\n\n"
						
					global_ctrl_idx += 1

	# Übrige CtrlMethods
	while global_ctrl_idx < ctrl_methods.size():
		var child = ctrl_methods[global_ctrl_idx]
		var params_dict = _get_node_params(child)
		if not params_dict.is_empty():
			var ctrl_type = child.get("CtrlType")
			if ctrl_type == null: ctrl_type = "Unknown"
			var group_name = "_" + str(global_ctrl_idx) + "_Ctrl_Methode_" + str(ctrl_type)
			var prefix = "CtrlMethod_" + str(global_ctrl_idx) + "_"
			shader_code += "group_uniforms " + group_name + ";\n"
			for param in params_dict.keys():
				var glsl_type = _godot_type_to_glsl(params_dict.get(param))
				if glsl_type != "":
					var uniform_name = prefix + param
					shader_code += "uniform " + glsl_type + " " + uniform_name + ";\n"
					uniform_assignments[uniform_name] = child.get(param)
			shader_code += "group_uniforms;\n\n"
		global_ctrl_idx += 1

	var ctrl_to_kp_basetime = {}
	var ctrl_to_kp_duration = {}
	var current_kp_time = 0.0
	var temp_ctrl_idx = 0

	if parsed_data.has("_keypoints"):
		var kp_array = parsed_data["_keypoints"]
		for k in range(kp_array.size()):
			var kp_block = kp_array[k]
			var ts = float(kp_block.get("TimeSpan", 0.0))
			var ts_sec = -1.0
			if ts != -1.0:
				ts_sec = ts * 0.001
			
			var c_count = int(kp_block.get("CtrlMethodCount", 0))
			for c in range(c_count):
				ctrl_to_kp_basetime[temp_ctrl_idx] = current_kp_time
				ctrl_to_kp_duration[temp_ctrl_idx] = ts_sec
				temp_ctrl_idx += 1
				
			if ts > 0.0:
				current_kp_time += ts_sec

	var has_kp0_direction = false
	var has_kp0_color = false
	var has_kp0_position = false
	var has_kp0_scale = false
	
	if parsed_data.has("_keypoints") and parsed_data["_keypoints"].size() > 0:
		var kp0 = parsed_data["_keypoints"][0]
		if kp0.has("Direction"): has_kp0_direction = true
		if kp0.has("Color"): has_kp0_color = true
		if kp0.has("Position"): has_kp0_position = true
		if kp0.has("Scale"): has_kp0_scale = true

	shader_code += "varying vec4 v_base_color;\n\n"
	
	var has_ctrl_noise = false
	for child in ctrl_methods:
		var ct = str(child.get("CtrlType"))
		if ct == "107" or ct == "109":
			has_ctrl_noise = true
			break
			
	if has_ctrl_noise:
		shader_code += "// --- NOISE FUNKTIONEN ---\n"
		shader_code += "float hash12(float p) { return fract(sin(p * 12.9898) * 43758.5453); }\n"
		shader_code += "float noise1D(float p) {\n"
		shader_code += "\tfloat i = floor(p); float f = fract(p);\n"
		shader_code += "\treturn mix(hash12(i), hash12(i + 1.0), f * f * (3.0 - 2.0 * f));\n}\n"
		shader_code += "float fbm1D(float x, int octaves, float persistence) {\n"
		shader_code += "\tfloat v = 0.0; float a = 0.5;\n"
		shader_code += "\tfor (int i = 0; i < 8; ++i) {\n"
		shader_code += "\t\tif (i >= octaves) break;\n"
		shader_code += "\t\tv += a * noise1D(x); x *= 2.0; a *= persistence;\n\t}\n"
		shader_code += "\treturn v;\n}\n\n"

	for i in range(ctrl_methods.size()):
		var child = ctrl_methods[i]
		if str(child.get("CtrlType")) == "110":
			var count = int(child.get("Count")) if "Count" in child else 0
			if count > 0:
				var u_name = "CtrlMethod_" + str(i) + "_Type_110_Pos_Array"
				shader_code += "uniform vec3 " + u_name + "[" + str(count) + "];\n"
				
				var vec3_array = PackedVector3Array()
				var pos_data = child.get("Pos_Array")
				if pos_data == null:
					pos_data = child.get("Pos")
				
				if typeof(pos_data) == TYPE_ARRAY or typeof(pos_data) == TYPE_PACKED_VECTOR3_ARRAY:
					for p in pos_data:
						vec3_array.append(p)
				else:
					var props = child.get_property_list()
					var pos_dict = {}
					for p in props:
						if p.name.begins_with("Pos"):
							pos_dict[p.name] = child.get(p.name)
							
					for j in range(count):
						var key = "Pos" if j == 0 else "Pos_" + str(j + 1)
						var key_alt = "Pos" if j == 0 else "Pos" + str(j + 1)
						if pos_dict.has(key): vec3_array.append(pos_dict[key])
						elif pos_dict.has(key_alt): vec3_array.append(pos_dict[key_alt])
						else: vec3_array.append(Vector3.ZERO)
						
				while vec3_array.size() < count:
					vec3_array.append(Vector3.ZERO)
					
				uniform_assignments[u_name] = vec3_array

	# ====================================================
	# DYNAMISCHER PATH GENERATOR (Trail Logic)
	# ====================================================
	shader_code += "void get_curve_data(float t_elem_local, out vec3 out_pos, out vec4 out_color, out vec2 out_scale, out mat3 out_rot) {\n"
	shader_code += "\tout_rot = mat3(1.0); // Startet als neutrale Matrix\n"
	shader_code += "\tvec3 ctrl_offset = vec3(0.0);\n"
	shader_code += "\tfloat ctrl_rot_z = 0.0;\n"
	shader_code += "\tvec2 ctrl_scale_offset = vec2(0.0);\n"
	shader_code += "\tbool apply_path_dir = false;\n"
	shader_code += "\tvec3 path_align_forward = vec3(0.0, 0.0, 1.0);\n"
	
	# KORREKTUR: c_base_color statt v_base_color nutzen, um Kollisionen zu vermeiden!
	if has_kp0_color:
		shader_code += "\tvec4 c_base_color = KP_0_Color;\n"
	else:
		shader_code += "\tvec4 c_base_color = vec4(1.0);\n"

	var kp_bases_with_path = []
	for i in range(ctrl_methods.size()):
		if str(ctrl_methods[i].get("CtrlType")) == "110":
			kp_bases_with_path.append(ctrl_to_kp_basetime.get(i, 0.0))

	for i in range(ctrl_methods.size()):
		var child = ctrl_methods[i]
		var ctrl_type = str(child.get("CtrlType"))
		
		if ctrl_type in ["100", "101", "104", "105", "106", "107", "108", "109", "110", "111"]:
			var kp_base = ctrl_to_kp_basetime.get(i, 0.0)
			var kp_dur = ctrl_to_kp_duration.get(i, -1.0)
			var prefix = "CtrlMethod_" + str(i) + "_"
			
			shader_code += "\t{\n"
			shader_code += "\t\tfloat kp_time = max(0.0, t_elem_local - " + str(kp_base) + ");\n"
			shader_code += "\t\tfloat start = " + prefix + "StartTime;\n"
			shader_code += "\t\tfloat end = " + prefix + "EndTime;\n"
			shader_code += "\t\tfloat t_run = max(0.0, kp_time - start);\n"
			
			shader_code += "\t\tfloat duration = 0.0;\n"
			shader_code += "\t\tif (end != -1.0) {\n"
			shader_code += "\t\t\tduration = max(0.0001, end - start);\n"
			shader_code += "\t\t\tt_run = min(t_run, duration);\n"
			if kp_dur != -1.0:
				shader_code += "\t\t} else {\n"
				shader_code += "\t\t\tduration = max(0.0001, " + str(kp_dur) + " - start);\n"
				shader_code += "\t\t\tt_run = min(t_run, duration);\n"
			shader_code += "\t\t}\n"
			
			if ctrl_type in ["100", "101", "104"]:
				shader_code += "\t\tfloat vel = " + prefix + "Vel;\n"
				shader_code += "\t\tfloat acc = " + prefix + "Acc;\n"
			
			var blocked_by_110 = (kp_base in kp_bases_with_path)

			if ctrl_type == "100":
				shader_code += "\t\tvec3 dir = length(" + prefix + "Dir) > 0.0001 ? normalize(" + prefix + "Dir) : vec3(0.0);\n"
				shader_code += "\t\tfloat dist = (vel * t_run) + (0.5 * acc * t_run * t_run);\n"
				if not blocked_by_110:
					shader_code += "\t\tctrl_offset += dir * dist;\n"
			elif ctrl_type == "101":
				shader_code += "\t\tctrl_rot_z += (vel * t_run) + (0.5 * acc * t_run * t_run);\n"
			elif ctrl_type == "104":
				var origin_pos = "KP_0_Position" if has_kp0_position else "vec3(0.0)"
				shader_code += "\t\tvec3 diff = " + origin_pos + " - " + prefix + "Pos;\n"
				shader_code += "\t\tvec3 dir = length(diff) > 0.0001 ? normalize(diff) : vec3(0.0);\n"
				shader_code += "\t\tfloat dist = (vel * t_run) + (0.5 * acc * t_run * t_run);\n"
				if not blocked_by_110:
					shader_code += "\t\tctrl_offset += dir * dist;\n"
			elif ctrl_type == "105":
				shader_code += "\t\tvec4 c_delta = " + prefix + "ColorDelta;\n"
				shader_code += "\t\t// Fix: Blau (b) und Alpha (a) tauschen\n"
				shader_code += "\t\tc_delta = c_delta.rgab;\n"
				shader_code += "\t\tc_base_color += c_delta * t_run;\n"
				shader_code += "\t\tc_base_color.rgb = max(c_base_color.rgb, vec3(0.0));\n"
				shader_code += "\t\tc_base_color.a = clamp(c_base_color.a, 0.0, 1.0);\n"
			elif ctrl_type == "106":
				var scale_key = "ScaleChage" if child.get("ScaleChage") != null else "ScaleChange"
				shader_code += "\t\tvec3 sc = " + prefix + scale_key + ";\n"
				shader_code += "\t\tfloat ds = clamp(sc.x * t_run, sc.y - 1.0, sc.z - 1.0);\n"
				shader_code += "\t\tctrl_scale_offset.x += ds;\n"
				shader_code += "\t\tctrl_scale_offset.y += ds;\n"
			elif ctrl_type == "107":
				shader_code += "\t\tint octaves = int(" + prefix + "OctaveNum);\n"
				shader_code += "\t\tfloat persistence = " + prefix + "Persistence;\n"
				shader_code += "\t\tfloat wave_len = max(0.001, " + prefix + "WaveLen);\n"
				shader_code += "\t\tfloat amplitude = " + prefix + "Amplitude * 0.001;\n"
				shader_code += "\t\tfloat n = fbm1D(t_run * wave_len, octaves, persistence);\n"
				shader_code += "\t\tfloat flicker = max(0.0, 1.0 + (n - 0.5) * amplitude * 2.0);\n"
				shader_code += "\t\tc_base_color = " + prefix + "BaseColor * vec4(vec3(flicker), flicker);\n"
			elif ctrl_type == "108":
				shader_code += "\t\tint count = int(" + prefix + "Count);\n"
				shader_code += "\t\tfloat t_ms = t_run * 1000.0; float cur_time = 0.0; vec4 c_out = " + prefix + "Color;\n"
				shader_code += "\t\tif (count >= 1) { float ts = max(0.0001, " + prefix + "TimeSpan); if (t_ms <= cur_time + ts) c_out = mix(" + prefix + "Color, " + prefix + "Color_2, (t_ms - cur_time) / ts); cur_time += ts; }\n"
				shader_code += "\t\tif (count >= 2 && t_ms > cur_time - 0.0001) { float ts = max(0.0001, " + prefix + "TimeSpan_2); if (t_ms <= cur_time + ts) c_out = mix(" + prefix + "Color_2, " + prefix + "Color_3, (t_ms - cur_time) / ts); cur_time += ts; }\n"
				shader_code += "\t\tc_base_color = c_out;\n"
			elif ctrl_type == "109":
				shader_code += "\t\tfloat n = fbm1D((t_run * 1000.0) / max(0.001, " + prefix + "WaveLen), int(" + prefix + "OctaveNum), " + prefix + "Persistence);\n"
				shader_code += "\t\tfloat ds = n * " + prefix + "Amplitude;\n"
				shader_code += "\t\tctrl_scale_offset.x += ds;\n"
				shader_code += "\t\tctrl_scale_offset.y += ds;\n"
			elif ctrl_type == "110":
				var count = int(child.get("Count")) if "Count" in child else 0
				var has_calc_dir = ("CalcDir" in child) or (child.get("CalcDir") != null)
				var calc_dir_is_bool = has_calc_dir and typeof(child.get("CalcDir")) == TYPE_BOOL
				
				if count > 1:
					shader_code += "\t\tfloat progress = duration > 0.001 ? clamp(t_run / duration, 0.0, 1.0) : 0.0;\n"
					shader_code += "\t\tfloat f_idx = progress * " + str(count - 1) + ".0;\n"
					shader_code += "\t\tint i0 = int(floor(f_idx));\n"
					shader_code += "\t\tint i1 = min(i0 + 1, " + str(count - 1) + ");\n"
					shader_code += "\t\tvec3 p0 = " + prefix + "Type_110_Pos_Array[i0];\n"
					shader_code += "\t\tvec3 p1 = " + prefix + "Type_110_Pos_Array[i1];\n"
					shader_code += "\t\tctrl_offset += mix(p0, p1, fract(f_idx));\n"
					
					if has_calc_dir:
						var condition = prefix + "CalcDir" if calc_dir_is_bool else prefix + "CalcDir > 0"
						shader_code += "\t\tif (" + condition + ") {\n"
						shader_code += "\t\t\tvec3 p_dir = p1 - p0;\n"
						shader_code += "\t\t\tif (length(p_dir) > 0.001) { apply_path_dir = true; path_align_forward = normalize(p_dir); }\n"
						shader_code += "\t\t}\n"
			elif ctrl_type == "111":
				shader_code += "\t\tint count = int(" + prefix + "Count);\n"
				shader_code += "\t\tfloat t_ms = t_run * 1000.0; float cur_time = 0.0; float s_out = " + prefix + "Scale;\n"
				shader_code += "\t\tif (count >= 1) { float ts = max(0.0001, " + prefix + "TimeSpan); if (t_ms <= cur_time + ts) s_out = mix(" + prefix + "Scale, " + prefix + "Scale_2, (t_ms - cur_time) / ts); cur_time += ts; }\n"
				shader_code += "\t\tfloat ds = s_out - 1.0;\n"
				shader_code += "\t\tctrl_scale_offset.x += ds;\n"
				shader_code += "\t\tctrl_scale_offset.y += ds;\n"
			shader_code += "\t}\n"

	if has_kp0_position:
		shader_code += "\n\tvec3 target_pos = KP_0_Position;\n"
	else:
		shader_code += "\n\tvec3 target_pos = vec3(0.0);\n"

	shader_code += "\t// FIX: Lineare Bewegung VOR der Orbit-Rotation anwenden (verhindert Ellipsen)\n"
	shader_code += "\ttarget_pos += ctrl_offset;\n"

	var has_ctrl_102_103 = false
	for child in ctrl_methods:
		if str(child.get("CtrlType")) in ["102", "103"]:
			has_ctrl_102_103 = true
			break
			
	if has_ctrl_102_103:
		shader_code += "\n\t// --- 3D ORBIT KORREKTUR (NUR TARGET POS) ---\n"
		for i in range(ctrl_methods.size()):
			var child = ctrl_methods[i]
			var ct = str(child.get("CtrlType"))
			if ct in ["102", "103"]:
				var kp_base = ctrl_to_kp_basetime.get(i, 0.0)
				var kp_dur = ctrl_to_kp_duration.get(i, -1.0)
				var prefix = "CtrlMethod_" + str(i) + "_"
				
				shader_code += "\t{\n"
				shader_code += "\t\tfloat kp_time = max(0.0, t_elem_local - " + str(kp_base) + ");\n"
				shader_code += "\t\tfloat start = " + prefix + "StartTime;\n"
				shader_code += "\t\tfloat end = " + prefix + "EndTime;\n"
				shader_code += "\t\tfloat t_run = max(0.0, kp_time - start);\n"
				
				shader_code += "\t\tif (end != -1.0) t_run = min(t_run, max(0.0, end - start));\n"
				if kp_dur != -1.0:
					shader_code += "\t\telse t_run = min(t_run, max(0.0, " + str(kp_dur) + " - start));\n"
				
				shader_code += "\t\tfloat angle = (" + prefix + "Vel * t_run) + (0.5 * " + prefix + "Acc * t_run * t_run);\n"
				shader_code += "\t\tvec3 pivot = " + prefix + "Pos; vec3 axis = " + prefix + "Axis;\n"
				
				shader_code += "\t\tif (length(axis) > 0.0001 && abs(angle) > 0.0001) {\n"
				shader_code += "\t\t\tvec3 k = normalize(axis); float c = cos(angle); float s = sin(angle);\n"
				shader_code += "\t\t\t// Rodrigues-Rotationsmatrix generieren\n"
				shader_code += "\t\t\tmat3 rot_m = mat3(\n"
				shader_code += "\t\t\t\tvec3(c + k.x*k.x*(1.0-c), k.y*k.x*(1.0-c) + k.z*s, k.z*k.x*(1.0-c) - k.y*s),\n"
				shader_code += "\t\t\t\tvec3(k.x*k.y*(1.0-c) - k.z*s, c + k.y*k.y*(1.0-c), k.z*k.y*(1.0-c) + k.x*s),\n"
				shader_code += "\t\t\t\tvec3(k.x*k.z*(1.0-c) + k.y*s, k.y*k.z*(1.0-c) - k.x*s, c + k.z*k.z*(1.0-c))\n"
				shader_code += "\t\t\t);\n"
				shader_code += "\t\t\tout_rot = rot_m * out_rot; // Matrix auf die Gesamtausrichtung multiplizieren\n"
				shader_code += "\t\t\tvec3 v_center = target_pos - pivot;\n"
				shader_code += "\t\t\ttarget_pos = rot_m * v_center + pivot;\n"
				shader_code += "\t\t}\n\t}\n"

	shader_code += "\n\tout_pos = target_pos;\n"
	shader_code += "\tout_color = c_base_color;\n"
	shader_code += "\tout_scale = ctrl_scale_offset;\n"
	shader_code += "\t// Z-Rotation noch einarbeiten (falls vorhanden)\n"
	shader_code += "\tfloat cz = cos(ctrl_rot_z); float sz = sin(ctrl_rot_z);\n"
	shader_code += "\tout_rot = out_rot * mat3(vec3(cz, sz, 0.0), vec3(-sz, cz, 0.0), vec3(0.0, 0.0, 1.0));\n"
	shader_code += "}\n\n"
	
	# ====================================================
	# VERTEX SHADER - TRAIL RENDERING
	# ====================================================
	shader_code += "void vertex() {\n"
	
	shader_code += "\t// --- ZEIT BERECHNUNG ---\n"
	shader_code += "\tfloat active_time = Time_Manual ? Time : (TIME * 1000.0);\n"
	shader_code += "\tv_current_time = 0.0;\n\n"
	
	shader_code += "\tfloat f_repeat = float(RepeatCount);\n"
	shader_code += "\tfloat f_delay = float(RepeatDelay);\n\n"
	
	shader_code += "\tfloat loop_active_duration = max(0.001, LocalTotalTime - StartTime);\n"
	shader_code += "\tfloat loop_full_duration = loop_active_duration + max(0.0, f_delay);\n\n"
	
	shader_code += "\tif (LocalTotalTime <= 0.0) {\n"
	shader_code += "\t\tv_current_time = active_time;\n"
	shader_code += "\t} else {\n"
	shader_code += "\t\tfloat t_global = active_time;\n"
	shader_code += "\t\tif (f_repeat >= 0.0) {\n"
	shader_code += "\t\t\tt_global = mod(active_time, max(0.001, GlobalLoopTime));\n"
	shader_code += "\t\t}\n"
	shader_code += "\t\tfloat t_since_start = t_global - StartTime;\n\n"
	shader_code += "\t\tif (t_since_start < 0.0) {\n"
	shader_code += "\t\t\tv_current_time = t_global;\n"
	shader_code += "\t\t} else {\n"
	shader_code += "\t\t\tfloat current_loop = floor(t_since_start / loop_full_duration);\n"
	shader_code += "\t\t\tif (f_repeat >= 0.0 && current_loop >= f_repeat) {\n"
	shader_code += "\t\t\t\tv_current_time = t_global;\n"
	shader_code += "\t\t\t} else {\n"
	shader_code += "\t\t\t\tfloat t_in_loop = mod(t_since_start, loop_full_duration);\n"
	shader_code += "\t\t\t\tv_current_time = StartTime + t_in_loop;\n"
	shader_code += "\t\t\t}\n"
	shader_code += "\t\t}\n"
	shader_code += "\t}\n\n"
	
	shader_code += "\t// --- FAKE TRAIL AUSWERTUNG --- \n"
	shader_code += "\tfloat active_dur_sec = max(0.001, (LocalTotalTime - LocalStartTime) * 0.001);\n"
	shader_code += "\tfloat eval_t_local = UV.x * active_dur_sec;\n"

	shader_code += "\tvec3 curve_pos; vec4 c_col; vec2 c_scale; mat3 c_rot;\n"
	shader_code += "\tget_curve_data(eval_t_local, curve_pos, c_col, c_scale, c_rot);\n"

	# ====================================================
	# VERTEX SHADER - TRAIL RENDERING (Aktualisiert mit KP_0_Direction & q_base)
	# ====================================================
	shader_code += "\t// --- TANGENTE BERECHNEN ---\n"
	shader_code += "\tfloat dt = 0.01 * active_dur_sec;\n"
	shader_code += "\tvec3 pos_next; vec4 dummy_col1; vec2 dummy_s1; mat3 dummy_rot1;\n"
	shader_code += "\tget_curve_data(clamp(eval_t_local + dt, 0.0, active_dur_sec), pos_next, dummy_col1, dummy_s1, dummy_rot1);\n"
	shader_code += "\tvec3 pos_prev; vec4 dummy_col2; vec2 dummy_s2; mat3 dummy_rot2;\n"
	shader_code += "\tget_curve_data(clamp(eval_t_local - dt, 0.0, active_dur_sec), pos_prev, dummy_col2, dummy_s2, dummy_rot2);\n"

	shader_code += "\tvec3 tangent = normalize(pos_next - pos_prev);\n"
	shader_code += "\tif (length(pos_next - pos_prev) < 0.0001) tangent = vec3(0.0, 0.0, 1.0);\n"

	shader_code += "\t// --- BASIS LOKALE FORM (OrgPos1 & OrgPos2) ---\n"
	shader_code += "\tfloat dynamic_width = 1.0 + c_scale.x;\n"
	shader_code += "\tvec3 local_pos;\n"
	shader_code += "\t\n"
	shader_code += "\t// Wenn OrgPos1 und OrgPos2 definiert sind, formen sie die linke und rechte Kante des Trails\n"
	shader_code += "\tif (length(OrgPos1) > 0.001 || length(OrgPos2) > 0.001) {\n"
	shader_code += "\t\t// OrgPos1 und 2 vertauschen UND X mit Z vertauschen (.zyx Swizzle)\n"
	shader_code += "\t\tvec3 p1 = OrgPos2.zyx;\n"
	shader_code += "\t\tvec3 p2 = OrgPos1.zyx;\n"
	shader_code += "\t\tlocal_pos = mix(p1, p2, UV.y) * dynamic_width;\n"
	shader_code += "\t} else {\n"
	shader_code += "\t\t// Fallback, falls die Vektoren fehlen\n"
	shader_code += "\t\tlocal_pos = vec3(0.0, (0.5 - UV.y) * dynamic_width, (UV.x - 0.5) * dynamic_width);\n"
	shader_code += "\t}\n"

	shader_code += "\t// --- BASE ROTATION FIX FÜR ID 110 (Angelica-Achsen) ---\n"
	shader_code += "\tvec4 q_base = vec4(0.5, 0.5, 0.5, 0.5);\n"
	shader_code += "\tlocal_pos = local_pos + 2.0 * cross(q_base.xyz, cross(q_base.xyz, local_pos) + q_base.w * local_pos);\n"

	if has_kp0_direction:
		shader_code += "\t// --- KEYPOINT 0 DIRECTION ROTATION ---\n"
		shader_code += "\tvec4 q = KP_0_Direction;\n"
		shader_code += "\t// Korrektur: Wenn die Rotation auf Standard (0,0,0,1) steht, richte sie auf X=0.7, W=0.7 aus\n"
		shader_code += "\tif (length(q.xyz) < 0.001) {\n"
		shader_code += "\t\tq = vec4(0.707106, 0.0, 0.0, 0.707106);\n"
		shader_code += "\t}\n"
		shader_code += "\tlocal_pos = local_pos + 2.0 * cross(q.xyz, cross(q.xyz, local_pos) + q.w * local_pos);\n"
	else:
		shader_code += "\t// --- STANDARD ROTATION (Falls kein KeyPoint 0 Direction vorhanden ist) ---\n"
		shader_code += "\tvec4 q_fallback = vec4(0.707106, 0.0, 0.0, 0.707106);\n"
		shader_code += "\tlocal_pos = local_pos + 2.0 * cross(q_fallback.xyz, cross(q_fallback.xyz, local_pos) + q_fallback.w * local_pos);\n"

	shader_code += "\t// --- ORBIT ROTATION AUF DAS GEWEBE ANWENDEN (Tornado-Fix) ---\n"
	shader_code += "\tlocal_pos = c_rot * local_pos;\n"

	shader_code += "\t// --- NORMALE AUSRICHTUNG ---\n"
	shader_code += "\t// Ausrichtung erfolgt bereits stabil ueber q_base und KP_0_Direction.\n"
	shader_code += "\t// (Keine fehleranfaellige Frenet-Matrix noetig)\n"
	
	shader_code += "\tVERTEX = curve_pos + local_pos;\n"
	
	if has_kp0_scale:
		shader_code += "\tVERTEX *= KP_0_Scale;\n"

	shader_code += "\tv_base_color = c_col;\n"
	shader_code += "}\n\n"
	
	# ====================================================
	# FRAGMENT SHADER
	# ====================================================
	shader_code += "void fragment() {\n"
	shader_code += "\tif (!Is_Endless && (v_current_time < LocalStartTime || v_current_time > LocalTotalTime)) {\n"
	shader_code += "\t\tdiscard;\n"
	shader_code += "\t}\n\n"
	
	shader_code += "\t// --- PHYSIKALISCHES TRAIL TIMING (Angelica Engine) ---\n"
	shader_code += "\tfloat seg_life_sec = max(0.001, float(SegLife) / 1000.0);\n"
	shader_code += "\tfloat active_dur_sec = max(0.001, (LocalTotalTime - LocalStartTime) * 0.001);\n"
	shader_code += "\tfloat current_t_sec = max(0.0, (v_current_time - LocalStartTime) * 0.001);\n"
	shader_code += "\t\n"
	shader_code += "\t// UV.x repräsentiert die physikalische 'Geburtszeit' (birth time) dieses Vertex in Sekunden\n"
	shader_code += "\tfloat birth_t_sec = UV.x * active_dur_sec;\n"
	shader_code += "\t\n"
	shader_code += "\t// Der Kopf des Trails liegt bei der aktuellen Zeit, der Schwanz stirbt nach SegLife\n"
	shader_code += "\tfloat head_t = current_t_sec;\n"
	shader_code += "\tfloat tail_t = current_t_sec - seg_life_sec;\n"
	shader_code += "\t\n"
	shader_code += "\t// Ein- und Ausblenden an den Rändern\n"
	shader_code += "\tfloat fade_sec = max(0.001, FadeLength * seg_life_sec);\n"
	shader_code += "\t\n"
	shader_code += "\t// Die Maske prüft, ob der Vertex gerade am Leben ist (zwischen Tail und Head liegt)\n"
	shader_code += "\tfloat mask = smoothstep(tail_t, tail_t + fade_sec, birth_t_sec) * smoothstep(head_t, head_t - fade_sec, birth_t_sec);\n"
	shader_code += "\t\n"
	shader_code += "\t// Die Textur gleitet korrekt physikalisch mit (0.0 am Schwanz, 1.0 am Kopf)\n"
	shader_code += "\tfloat mapped_u = (birth_t_sec - tail_t) / seg_life_sec;\n"
	shader_code += "\tmapped_u = clamp(mapped_u, 0.0, 1.0);\n"
	shader_code += "\t\n"
	shader_code += "\tvec2 final_uv = vec2(UV.y, mapped_u);\n\n"
	
	var p_main = parsed_data.get("MainParameters", {}) if typeof(parsed_data.get("MainParameters")) == TYPE_DICTIONARY else {}
	
	if parsed_data.has("UVExchg") or p_main.has("UVExchg"): shader_code += "\tif (UVExchg) final_uv = final_uv.yx;\n"
	if parsed_data.has("UReverse") or p_main.has("UReverse"): shader_code += "\tif (UReverse) final_uv.x = 1.0 - final_uv.x;\n"
	if parsed_data.has("VReverse") or p_main.has("VReverse"): shader_code += "\tif (VReverse) final_uv.y = 1.0 - final_uv.y;\n"
		
	var has_texcol = parsed_data.has("TexCol") or p_main.has("TexCol")
	var has_texrow = parsed_data.has("TexRow") or p_main.has("TexRow")
	var has_tile = parsed_data.has("TileMode") or p_main.has("TileMode")
	var has_speed1 = parsed_data.has("TexSpeed_1") or p_main.has("TexSpeed_1")
	var has_speed2 = parsed_data.has("TexSpeed_2") or p_main.has("TexSpeed_2")

	if has_texcol or has_texrow or has_tile or has_speed1 or has_speed2:
		var col_str = "float(TexCol)" if has_texcol else "1.0"
		var row_str = "float(TexRow)" if has_texrow else "1.0"
		var int_str = "float(TexInterval)" if (parsed_data.has("TexInterval") or p_main.has("TexInterval")) else "50.0"
		
		shader_code += "\tfloat f_cols = max(1.0, " + col_str + ");\n"
		shader_code += "\tfloat f_rows = max(1.0, " + row_str + ");\n"
		shader_code += "\tfloat f_interval = max(1.0, " + int_str + ");\n\n"
		
		if has_tile:
			shader_code += "\tif (TileMode) {\n"
			shader_code += "\t\tfinal_uv.x *= f_cols; final_uv.y *= f_rows;\n"
			var ts1_str = "float(TexSpeed_1)" if has_speed1 else "0.0"
			var ts2_str = "float(TexSpeed_2)" if has_speed2 else "0.0"
			shader_code += "\t\tfinal_uv.x += (v_current_time / 1000.0) * " + ts1_str + ";\n"
			shader_code += "\t\tfinal_uv.y += (v_current_time / 1000.0) * " + ts2_str + ";\n"
			shader_code += "\t} else {\n"
		else:
			shader_code += "\t{\n"
			
		shader_code += "\t\tif (f_cols > 1.0 || f_rows > 1.0) {\n"
		shader_code += "\t\t\tfloat total_frames = f_cols * f_rows;\n"
		shader_code += "\t\t\tfloat current_frame = mod(floor(v_current_time / f_interval), total_frames);\n"
		shader_code += "\t\t\tfloat frame_x = mod(current_frame, f_cols);\n"
		shader_code += "\t\t\tfloat frame_y = floor(current_frame / f_cols);\n"
		shader_code += "\t\t\tfinal_uv.x = (final_uv.x / f_cols) + (frame_x / f_cols);\n"
		shader_code += "\t\t\tfinal_uv.y = (final_uv.y / f_rows) + (frame_y / f_rows);\n"
		shader_code += "\t\t}\n\t}\n"

	shader_code += "\n\tvec4 tex_color = texture(TexFile, final_uv);\n"
	
	#// --- STANDARD FARBAUSGABE (Warp komplett ignoriert) ---
	shader_code += "\ttex_color *= v_base_color;\n"
	if render_blend_mode == "blend_mix": 
		shader_code += "\ttex_color.a *= 0.70;\n"
	shader_code += "\tALBEDO = tex_color.rgb;\n"
	shader_code += "\tALPHA = tex_color.a * mask;\n"
		
	shader_code += "}\n"
		
	shader.code = preload("gfx_parser.gd").add_gfx_alpha(shader_code)
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
	
	mat.render_priority = priority_val
	mesh_instance.material_override = mat
	
	var sprite_index = 0
	var p_name = str(parent_node.name)
	if p_name.begins_with("Element_"):
		var parts = p_name.split("_")
		if parts.size() > 1 and parts[1].is_valid_int():
			sprite_index = int(parts[1])
	else:
		sprite_index = parent_node.get_index()
		if sprite_index < 0: sprite_index = 0
			
	var face_dir = Vector3(0, 0, 1) 
	if uniform_assignments.has("KP_0_Direction"):
		var dir_val = uniform_assignments["KP_0_Direction"]
		var q = Quaternion(dir_val.x, dir_val.y, dir_val.z, dir_val.w)
		face_dir = q * Vector3(0, 0, 1)

	mesh_instance.position += face_dir.normalized() * (sprite_index * 0.001)

func _as_bool(value) -> bool:
	var s = str(value).strip_edges().to_lower()
	return s == "1" or s == "true"

func _godot_type_to_glsl(type: int) -> String:
	match type:
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_BOOL: return "bool"
		TYPE_VECTOR3: return "vec3"
		TYPE_VECTOR4: return "vec4"
		TYPE_COLOR: return "vec4" 
		_: return ""
