@tool
extends Object

func execute(root_node: Node):
	var target_nodes = _find_id_101_nodes(root_node)
	
	if target_nodes.is_empty():
		push_warning("Keine Nodes mit der ID 101 gefunden!")
		return
		
	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Create Sprite3D for ID_101")
	
	# 1. Nodes nach Parent (Header, z.B. "八卦绿") gruppieren
	var header_groups = {}
	for node in target_nodes:
		var parent = node.get_parent()
		if not header_groups.has(parent):
			header_groups[parent] = []
		header_groups[parent].append(node)
		
	# 2. Für jeden Header die max. Loop-Zeit berechnen und Shader generieren
	for parent in header_groups.keys():
		var group_nodes = header_groups[parent]
		
		# NEU: Wir rufen unsere Funktion auf, die ALLE "Element_"-Kinder prüft!
		var max_group_time = _get_max_time_for_header(parent)
		
		# Fallback, falls wirklich ALLE Effekte im Header endlos (-1) sind
		if max_group_time <= 0.0:
			max_group_time = 3000.0 
			
		# Sprites und Shader für die ID_100 Nodes mit der globalen Zeit erstellen
		for node in group_nodes:
			_create_sprite_with_shader(node, root_node, undo_redo, max_group_time)
			
	undo_redo.commit_action()
	print("Sprite3Ds und Shader-Materialien für ", target_nodes.size(), " ID_100-Nodes erstellt.")


# --- HIER IST DIE FUNKTION JETZT GANZ LINKS BÜNDIG ---
func _get_max_time_for_header(header_node: Node) -> float:
	var max_time = 0.0
	
	# Wir prüfen ALLE Kinder des Headers (z.B. ID_150, ID_123, ID_100)
	for child in header_node.get_children():
		if child.name.begins_with("Element_"):
			var t_start = 0.0
			var t_total = 0.0
			var is_endless = false
			
			# Variante A: Die Daten liegen (wie bei ID_100) in parsed_data
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
				# Variante B: Die Daten liegen direkt als Parameter auf dem Node3D
				if child.get("StartTime") != null:
					t_start = float(child.get("StartTime"))
					t_total = t_start
				
				# KeyPoints hochzählen (KeyPoint 0, KeyPoint 1, ...)
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
						break # Kein weiterer KeyPoint gefunden
						
			# Wenn das Element nicht endlos läuft und länger ist als das bisherige Maximum:
			if not is_endless and t_total > max_time:
				max_time = t_total
				
	return max_time
	
func _find_id_101_nodes(current_node: Node) -> Array:
	var results = []
	if current_node.name.contains("_ID_101"):
		results.append(current_node)
		
	for child in current_node.get_children():
		results.append_array(_find_id_101_nodes(child))
		
	return results

func _gather_ctrl_nodes(node: Node) -> Array:
	var results = []
	for child in node.get_children():
		if child.name == "Sprite3D_GFX": 
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
	return parent_node.get_node_or_null("Sprite3D_GFX")

# undo_redo = null: direkt anhängen statt über UndoRedo
func _create_sprite_with_shader(parent_node: Node3D, root_node: Node, undo_redo, max_group_time: float):
	if parent_node.has_node("Sprite3D_GFX"):
		return
		
	var sprite = Sprite3D.new()
	sprite.name = "Sprite3D_GFX"
	
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sprite.extra_cull_margin = 1000.0
	
	if undo_redo != null:
		undo_redo.add_do_method(parent_node, "add_child", sprite)
		undo_redo.add_do_property(sprite, "owner", root_node) 
		undo_redo.add_undo_method(parent_node, "remove_child", sprite)
		undo_redo.add_do_reference(sprite)
	else:
		parent_node.add_child(sprite)
	
	var parsed_data = parent_node.get("parsed_data")
	var param_types = parent_node.get("PARAM_TYPES")
	
	if typeof(parsed_data) != TYPE_DICTIONARY or typeof(param_types) != TYPE_DICTIONARY:
		return
		
	var mat = ShaderMaterial.new()
	var shader = Shader.new()
	# ====================================================
	# 0. RENDER MODE, DESTBLEND & PRIORITY MAPPING
	# ====================================================
	var render_blend_mode = "blend_mix" # Standard-Fallback
	var priority_val = 0 # Standard Priority
	var repeat_count_val = 1.0 # Standard ist 1 Durchlauf
	
	# DestBlend auslesen
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
		
	# --- NEU: Priority auslesen ---
	if parsed_data.has("Priority"):
		priority_val = int(parsed_data["Priority"])
	elif parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY:
		if parsed_data["MainParameters"].has("Priority"):
			priority_val = int(parsed_data["MainParameters"]["Priority"])
	
	

	
	
	
	# 1. WARP CHECK VOR DEM SHADER-START!
	var has_warp = false
	var warp_active = false
	if parsed_data.has("Warp"):
		has_warp = true
		warp_active = _as_bool(parsed_data["Warp"])
	elif parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY and parsed_data["MainParameters"].has("Warp"):
		has_warp = true
		warp_active = _as_bool(parsed_data["MainParameters"]["Warp"])
		
	# Jedes Element hat eine "Warp:"-Zeile -> nur ein AKTIVER Warp (Warp: 1) erzwingt blend_mix.
	# has_warp (Schlüssel vorhanden) bleibt für den Shader-Zweig, damit Warp im Inspektor umschaltbar bleibt.
	if warp_active:
		# WICHTIG GEGEN DAS HELLE LEUCHTEN: Warp MUSS blend_mix sein!
		# Auf blend_add würde der Bildschirm auf den Bildschirm addiert werden = extremes Leuchten.
		render_blend_mode = "blend_mix"

	# 2. SHADER KOPF GENERIEREN
	var shader_code = "shader_type spatial;\n"
	shader_code += "render_mode " + render_blend_mode + ", depth_draw_opaque, cull_disabled, unshaded"
	# 2DRender der GFX: ohne Tiefentest (A3DGFXEx::IsZTestEnable)
	if preload("gfx_parser.gd").gfx_2d_render(parent_node):
		shader_code += ", depth_test_disabled"
	shader_code += ";\n\n"
	
	if has_warp:
		shader_code += "uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;\n"
	# ====================================================

	# Variable zur Zeitübertragung vom Vertex- in den Fragment-Shader
	shader_code += "varying float v_current_time;\n\n"
	
	var uniform_assignments = {} 
	
	# ====================================================
	# VORBEREITUNG: Alle Affectors und CtrlMethods trennen
	# ====================================================
	var all_ctrl_nodes = _gather_ctrl_nodes(parent_node)
	var ctrl_methods = []
	var affectors = []
	
	for child in all_ctrl_nodes:
		if child.name.findn("Affector") != -1:
			affectors.append(child)
		else:
			ctrl_methods.append(child)
			
	var global_ctrl_idx = 0
	var global_aff_idx = 0
	
	# ====================================================
	# 0. ZEITEINSTELLUNGEN (TIME & KEYPOINT BERECHNUNG)
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
	# 1. HAUPT-PARAMETER 
	# ====================================================
	shader_code += "group_uniforms Main_Parameters;\n"
	for key in parsed_data.keys():
		if key.begins_with("_"): continue 
		
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
						
						if key in ["TexFile", "Tex File"]:
							sprite.texture = loaded_tex
			else:
				shader_code += "// String: " + key + " = " + str(parsed_data[key]) + "\n"
		else:
			var glsl_type = _godot_type_to_glsl(godot_type)
			if glsl_type != "":
				shader_code += "uniform " + glsl_type + " " + key + ";\n"
				uniform_assignments[key] = parent_node.get(key)
	shader_code += "group_uniforms;\n\n"
	
	# ====================================================
	# 2. KEYPOINTS UND EINGEBETTETE CTRL METHODS
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

	# ====================================================
	# 3. PS CONST BLOCKS UND EINGEBETTETE AFFECTORS
	# ====================================================
	if parsed_data.has("_ps_consts"):
		var ps_array = parsed_data["_ps_consts"]
		for p in range(ps_array.size()):
			shader_code += "group_uniforms PS_Const_Block_" + str(p) + ";\n"
			var ps_block = ps_array[p]
			
			for ps_key in ps_block.keys():
				if ps_key.begins_with("_"): continue
				
				var godot_type = param_types.get(ps_key, TYPE_STRING)
				var glsl_type = _godot_type_to_glsl(godot_type)
				var uniform_name = "PS_" + str(p) + "_" + ps_key
				
				if glsl_type != "":
					shader_code += "uniform " + glsl_type + " " + uniform_name + ";\n"
					var prop_path = "PS Const Block " + str(p) + "/" + ps_key
					uniform_assignments[uniform_name] = parent_node.get(prop_path)
					
			if ps_block.has("_targets"):
				var targets = ps_block["_targets"]
				for t in range(targets.size()):
					var target_block = targets[t]
					for t_key in target_block.keys():
						if t_key.begins_with("_"): continue
						var godot_type = param_types.get(t_key, TYPE_STRING)
						var glsl_type = _godot_type_to_glsl(godot_type)
						var uniform_name = "PS_" + str(p) + "_Target_" + str(t) + "_" + t_key
						
						if glsl_type != "":
							shader_code += "uniform " + glsl_type + " " + uniform_name + ";\n"
							var prop_path = "PS Const Block " + str(p) + "/Target " + str(t) + "/" + t_key
							uniform_assignments[uniform_name] = parent_node.get(prop_path)
							
			shader_code += "group_uniforms;\n\n"
			
			var aff_count = 0
			if ps_block.has("AffectorCount"):
				aff_count = int(ps_block["AffectorCount"])
				
			for i in range(aff_count):
				if global_aff_idx < affectors.size():
					var child = affectors[global_aff_idx]
					var params_dict = _get_node_params(child)
					
					if not params_dict.is_empty():
						var ctrl_type = child.get("CtrlType")
						if ctrl_type == null: ctrl_type = "Unknown"
						
						var group_name = "_" + str(global_aff_idx) + "_Affector_" + str(ctrl_type)
						var prefix = "Affector_" + str(global_aff_idx) + "_"
						
						shader_code += "group_uniforms " + group_name + ";\n"
						for param in params_dict.keys():
							var godot_type_aff = params_dict.get(param)
							var glsl_type_aff = _godot_type_to_glsl(godot_type_aff)
							if glsl_type_aff != "":
								var uniform_name_aff = prefix + param
								shader_code += "uniform " + glsl_type_aff + " " + uniform_name_aff + ";\n"
								uniform_assignments[uniform_name_aff] = child.get(param)
						shader_code += "group_uniforms;\n\n"
						
					global_aff_idx += 1

	# ====================================================
	# 4. ÜBRIGE AFFECTORS UND CTRL METHODS
	# ====================================================
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
		
	while global_aff_idx < affectors.size():
		var child = affectors[global_aff_idx]
		var params_dict = _get_node_params(child)
		if not params_dict.is_empty():
			var ctrl_type = child.get("CtrlType")
			if ctrl_type == null: ctrl_type = "Unknown"
			var group_name = "_" + str(global_aff_idx) + "_Affector_" + str(ctrl_type)
			var prefix = "Affector_" + str(global_aff_idx) + "_"
			shader_code += "group_uniforms " + group_name + ";\n"
			for param in params_dict.keys():
				var glsl_type = _godot_type_to_glsl(params_dict.get(param))
				if glsl_type != "":
					var uniform_name = prefix + param
					shader_code += "uniform " + glsl_type + " " + uniform_name + ";\n"
					uniform_assignments[uniform_name] = child.get(param)
			shader_code += "group_uniforms;\n\n"
		global_aff_idx += 1

	# ====================================================
	# 5. SHADER ABSCHLIESSEN UND VARIABLEN SETZEN
	# ====================================================
	
	# --- NEU: KeyPoint-Zeiten für CtrlMethods vorberechnen ---
	var ctrl_to_kp_basetime = {}
	var ctrl_to_kp_duration = {}
	var current_kp_time = 0.0
	var temp_ctrl_idx = 0

	if parsed_data.has("_keypoints"):
		var kp_array = parsed_data["_keypoints"]
		for k in range(kp_array.size()):
			var kp_block = kp_array[k]
			var ts = 0.0
			if kp_block.has("TimeSpan"):
				ts = float(kp_block["TimeSpan"])
			
			var ts_sec = -1.0 # -1.0 bedeutet endlos
			if ts != -1.0:
				ts_sec = ts * 0.001
			
			var c_count = 0
			if kp_block.has("CtrlMethodCount"):
				c_count = int(kp_block["CtrlMethodCount"])
				
			for c in range(c_count):
				ctrl_to_kp_basetime[temp_ctrl_idx] = current_kp_time
				ctrl_to_kp_duration[temp_ctrl_idx] = ts_sec
				temp_ctrl_idx += 1
				
			if ts > 0.0:
				current_kp_time += ts_sec
	# ---------------------------------------------------------

	# Prüfen, ob KeyPoint 0 bestimmte Startwerte hat
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

	# Wir übergeben nun die final berechnete Basis-Farbe an den Fragment-Shader
	shader_code += "varying vec4 v_base_color;\n\n"
	
	# --- NEU: Noise-Funktionen für CtrlType 107 & 109 (Flicker & Pulse) generieren ---
	var has_ctrl_noise = false
	for child in ctrl_methods:
		var ct = str(child.get("CtrlType"))
		if ct == "107" or ct == "109":
			has_ctrl_noise = true
			break
			
	if has_ctrl_noise:
		shader_code += "// --- NOISE FUNKTIONEN FÜR CTRL 107 & 109 ---\n"
		shader_code += "float hash12(float p) {\n"
		shader_code += "\treturn fract(sin(p * 12.9898) * 43758.5453);\n"
		shader_code += "}\n"
		shader_code += "float noise1D(float p) {\n"
		shader_code += "\tfloat i = floor(p);\n"
		shader_code += "\tfloat f = fract(p);\n"
		shader_code += "\treturn mix(hash12(i), hash12(i + 1.0), f * f * (3.0 - 2.0 * f));\n"
		shader_code += "}\n"
		shader_code += "float fbm1D(float x, int octaves, float persistence) {\n"
		shader_code += "\tfloat v = 0.0;\n"
		shader_code += "\tfloat a = 0.5;\n"
		shader_code += "\tfor (int i = 0; i < 8; ++i) {\n"
		shader_code += "\t\tif (i >= octaves) break;\n"
		shader_code += "\t\tv += a * noise1D(x);\n"
		shader_code += "\t\tx *= 2.0;\n"
		shader_code += "\t\ta *= persistence;\n"
		shader_code += "\t}\n"
		shader_code += "\treturn v;\n"
		shader_code += "}\n\n"
	# -------------------------------------------------------------------
	# --- PRE-PASS FÜR TYPE 110 (UNIFORM ARRAYS) ---
	for i in range(ctrl_methods.size()):
		var child = ctrl_methods[i]
		if str(child.get("CtrlType")) == "110":
			var count = int(child.get("Count")) if "Count" in child else 0
			if count > 0:
				var u_name = "CtrlMethod_" + str(i) + "_Type_110_Pos_Array"
				shader_code += "uniform vec3 " + u_name + "[" + str(count) + "];\n"
				
				var vec3_array = PackedVector3Array()
				
				# NEU: Wir suchen explizit nach "Pos_Array" (wie es im Inspector heißt) 
				# und nehmen "Pos" nur als Fallback.
				var pos_data = child.get("Pos_Array")
				if pos_data == null:
					pos_data = child.get("Pos")
				
				if typeof(pos_data) == TYPE_ARRAY or typeof(pos_data) == TYPE_PACKED_VECTOR3_ARRAY:
					for p in pos_data:
						vec3_array.append(p)
				else:
					# ECHTER FALLBACK, falls es doch Einzel-Variablen sind
					var props = child.get_property_list()
					var pos_dict = {}
					for p in props:
						if p.name.begins_with("Pos"):
							pos_dict[p.name] = child.get(p.name)
							
					for j in range(count):
						var key = "Pos" if j == 0 else "Pos_" + str(j + 1)
						var key_alt = "Pos" if j == 0 else "Pos" + str(j + 1)
						
						if pos_dict.has(key):
							vec3_array.append(pos_dict[key])
						elif pos_dict.has(key_alt):
							vec3_array.append(pos_dict[key_alt])
						else:
							vec3_array.append(Vector3.ZERO)
							
				# SICHERHEIT: Falls das ausgelesene Array kleiner ist als 'Count',
				# füllen wir den Rest mit Nullen auf, damit Godot das Array anstandslos zum Shader schickt.
				while vec3_array.size() < count:
					vec3_array.append(Vector3.ZERO)
					
				# Array der Material-Zuweisung übergeben
				uniform_assignments[u_name] = vec3_array
				
	# ====================================================
	# BIND-ELE CHECK (Synchronisation via Node-Tree)
	# ====================================================
	var bind_ele = parsed_data.get("BindEle", "")
	var is_bound = (bind_ele != "")
	
	# Standard: Wir nutzen die eigenen Uniforms des Shaders, falls nichts gebunden ist
	var b_total = "LocalTotalTime"
	var b_repeat = "float(RepeatCount)"
	var b_delay = "float(RepeatDelay)"
	var b_start = "StartTime"
	
	if is_bound:
		# Da das Sprite noch nicht im Baum ist, nutzen wir parent_node (Element_7)!
		# Der Header ist dessen Parent.
		var header_node = parent_node.get_parent()
		
		if header_node:
			var target_data = {}
			var target_node = null # NEU: Wir merken uns den GANZEN Node, nicht nur den Namen
			
			# Wir durchsuchen alle anderen Elemente unter diesem Header
			for child in header_node.get_children():
				var c_data = child.get("parsed_data")
				if typeof(c_data) == TYPE_DICTIONARY:
					if c_data.get("Name", "") == bind_ele:
						target_data = c_data
						target_node = child # <-- Treffer! Wir speichern uns das echte Node (Element 1)
						break
						
			if target_node and not target_data.is_empty():
				print("\n--- BIND-ELE GEFUNDEN ---")
				print("BindEle Match: ", parent_node.name, " synchronisiert sich mit ", bind_ele)
				print("Name: ", bind_ele, " gefunden in -> ", target_node.name)
				
				# ==========================================
				# 1. ZEIT-DATEN DES ZIELS AUSLESEN
				# ==========================================
				var t_main = target_data.get("MainParameters", {})
				var t_start = target_data.get("StartTime", t_main.get("StartTime", 0.0))
				var t_repeat = target_data.get("KeyPoint_0", {}).get("RepeatCount", -1.0)
				var t_delay = target_data.get("RepeatDelay", t_main.get("RepeatDelay", 0.0))
				
				# KeyPoints auslesen (mit -1 als Fallback)
				var kp0_time = target_data.get("KeyPoint_0", {}).get("TimeSpan", -1.0)
				var kp1_time = target_data.get("KeyPoint_1", {}).get("TimeSpan", -1.0)
				var kp2_time = target_data.get("KeyPoint_2", {}).get("TimeSpan", -1.0)
				
				# ==========================================
				# WICHTIG: HIER WEISEN WIR DIE VARIABLEN FÜR DEN SHADER ZU!
				# ==========================================
				b_start = str(float(t_start))
				b_total = str(float(kp0_time))
				b_repeat = str(float(t_repeat))
				b_delay = str(float(t_delay))
				# ==========================================
				
				print("Zeit-Daten des Ziels:")
				print("  - StartTime: ", t_start)
				print("  - RepeatCount: ", t_repeat)
				print("  - KeyPoint_0 TimeSpan: ", kp0_time)
				if target_data.has("KeyPoint_1"):
					print("  - KeyPoint_1 TimeSpan: ", kp1_time)
				if target_data.has("KeyPoint_2"):
					print("  - KeyPoint_2 TimeSpan: ", kp2_time)
				
				# ==========================================
				# 2. ZIEL-BEWEGUNGEN (ECHTE WERTE) AUSLESEN
				# ==========================================
				var target_ctrls = _gather_ctrl_nodes(target_node)
				print("Soll-Bewegungen des Ziels:")
				for ctrl in target_ctrls:
					var real_params = {}
					
					# Versuch A: Die echten Daten liegen in 'parsed_data'
					if ctrl.get("parsed_data") != null and typeof(ctrl.get("parsed_data")) == TYPE_DICTIONARY:
						real_params = ctrl.parsed_data
					else:
						# Versuch B: Wir nutzen das Schema nur für die Namen der Variablen 
						# und holen uns die ECHTEN Werte direkt aus dem Node (ctrl.get)
						var schema = _get_node_params(ctrl)
						for key in schema.keys():
							real_params[key] = ctrl.get(key)
							
					print("  - ", ctrl.name, " | Echte Parameter: ", real_params)
				print("-------------------------\n")
				
				# (Hier bereiten wir gleich die Shader-Variablen b_total, b_repeat etc. für Schritt 3 vor)
			else:
				print("WARNUNG: BindEle '", bind_ele, "' nicht im Header gefunden!")
	# ====================================================

	shader_code += "void vertex() {\n"
	# ====================================================
	# ZEIT-SYNCHRONISATION
	# ====================================================
	shader_code += "\t// --- ZEIT-SYNCHRONISATION ---\n"
	shader_code += "\tfloat active_time = Time_Manual ? Time : (TIME * 1000.0);\n"
	shader_code += "\tv_current_time = 0.0;\n\n"
	
	# NEU: Auch RepeatDelay explizit in ein Float umwandeln!
	shader_code += "\tfloat f_repeat = float(RepeatCount);\n"
	shader_code += "\tfloat f_delay = float(RepeatDelay);\n\n"
	
	# Die echte aktive Animationszeit ohne den initialen Delay
	shader_code += "\tfloat loop_active_duration = max(0.001, LocalTotalTime - StartTime);\n"
	# Ein voller Repeat-Zyklus ist die aktive Zeit + die anschließende Pause
	shader_code += "\tfloat loop_full_duration = loop_active_duration + max(0.0, f_delay);\n\n"
	
	# --- 1. SONDERFALL: UNENDLICH (TimeSpan = -1) ---
	shader_code += "\tif (LocalTotalTime <= 0.0) {\n"
	shader_code += "\t\tv_current_time = active_time;\n"
	
	shader_code += "\t} else {\n"
	# --- 2. REGULÄRER ABLAUF ---
	shader_code += "\t\tfloat t_global = active_time;\n"
	shader_code += "\t\tif (f_repeat >= 0.0) {\n"
	shader_code += "\t\t\tt_global = mod(active_time, max(0.001, GlobalLoopTime));\n"
	shader_code += "\t\t}\n"
	
	# Zeit, die seit dem Ablauf der anfänglichen StartTime vergangen ist
	shader_code += "\t\tfloat t_since_start = t_global - StartTime;\n\n"
	
	shader_code += "\t\tif (t_since_start < 0.0) {\n"
	shader_code += "\t\t\t// A: Initialer StartTime-Delay (passiert nur 1x pro Global-Loop!)\n"
	shader_code += "\t\t\tv_current_time = t_global;\n"
	shader_code += "\t\t} else {\n"
	shader_code += "\t\t\t// B: Wir sind in der aktiven Phase (Animation + RepeatDelay)\n"
	shader_code += "\t\t\tfloat current_loop = floor(t_since_start / loop_full_duration);\n\n"
	
	shader_code += "\t\t\tif (f_repeat >= 0.0 && current_loop >= f_repeat) {\n"
	shader_code += "\t\t\t\t// Wiederholungen sind aufgebraucht -> Zeit normal weiterlaufen lassen, Effekt endet.\n"
	shader_code += "\t\t\t\tv_current_time = t_global;\n"
	shader_code += "\t\t\t} else {\n"
	shader_code += "\t\t\t\t// C: Gültige Wiederholung! \n"
	shader_code += "\t\t\t\tfloat t_in_loop = mod(t_since_start, loop_full_duration);\n"
	shader_code += "\t\t\t\t// Wir springen IMMER auf StartTime zurück, nie auf 0! \n"
	shader_code += "\t\t\t\t// So wird der initiale Delay bei jedem neuen Repeat ignoriert.\n"
	shader_code += "\t\t\t\tv_current_time = StartTime + t_in_loop;\n"
	shader_code += "\t\t\t}\n"
	shader_code += "\t\t}\n"
	shader_code += "\t}\n\n"
	# Initiale Farbe direkt setzen, bevor die CtrlMethods sie manipulieren
	if has_kp0_color:
		shader_code += "\tv_base_color = KP_0_Color;\n"
	else:
		shader_code += "\tv_base_color = vec4(1.0);\n"
	
	# ====================================================
	# ZWEITE ZEITACHSE IN DEN SHADER SCHREIBEN
	# ====================================================
	shader_code += "\n\t// --- TRANSFORM ZEIT (FÜR BIND-ELE SYNCHRONISATION) ---\n"
	
	if is_bound and b_total != "LocalTotalTime":
		shader_code += "\tfloat fb_total = " + b_total + ";\n"
		shader_code += "\tfloat fb_start = " + b_start + ";\n"
		shader_code += "\tfloat fb_delay = " + b_delay + ";\n"
		shader_code += "\tfloat fb_repeat = " + b_repeat + ";\n\n"
		
		shader_code += "\tfloat v_transform_time = 0.0;\n"
		shader_code += "\tfloat b_loop_active = max(0.001, fb_total - fb_start);\n"
		shader_code += "\tfloat b_loop_full = b_loop_active + max(0.0, fb_delay);\n\n"
		
		shader_code += "\tif (fb_total <= 0.0) {\n"
		shader_code += "\t\tv_transform_time = active_time;\n"
		shader_code += "\t} else {\n"
		shader_code += "\t\tfloat bt_global = active_time;\n"
		shader_code += "\t\tif (fb_repeat >= 0.0) bt_global = mod(active_time, max(0.001, GlobalLoopTime));\n"
		shader_code += "\t\tfloat bt_since = bt_global - fb_start;\n"
		shader_code += "\t\tif (bt_since < 0.0) {\n"
		shader_code += "\t\t\tv_transform_time = bt_global;\n"
		shader_code += "\t\t} else {\n"
		shader_code += "\t\t\tfloat b_loop = floor(bt_since / b_loop_full);\n"
		shader_code += "\t\t\tif (fb_repeat >= 0.0 && b_loop >= fb_repeat) {\n"
		shader_code += "\t\t\t\tv_transform_time = bt_global;\n"
		shader_code += "\t\t\t} else {\n"
		shader_code += "\t\t\t\tfloat bt_in_loop = mod(bt_since, b_loop_full);\n"
		shader_code += "\t\t\t\tv_transform_time = fb_start + bt_in_loop;\n"
		shader_code += "\t\t\t}\n"
		shader_code += "\t\t}\n"
		shader_code += "\t}\n"
	else:
		shader_code += "\tfloat v_transform_time = v_current_time;\n"
	# ====================================================
	
	
	
	# ====================================================
	# 1. CTRLMETHODS VORBEREITUNG (100, 101, 104, 105, 106, 107 & 108)
	# ====================================================
	shader_code += "\t// --- CTRL METHODS BERECHNEN ---\n"
	shader_code += "\tvec3 ctrl_offset = vec3(0.0);\n"
	shader_code += "\tfloat ctrl_rot_z = 0.0;\n"
	shader_code += "\tvec2 ctrl_scale_offset = vec2(0.0);\n"
	
	# --- NEU: ZWEI ZEITEN STATT EINER! ---
	shader_code += "\tfloat t_elem_local = max(0.0, (v_current_time - LocalStartTime) * 0.001);\n"
	
	if is_bound and b_total != "LocalTotalTime":
		# WICHTIG: Wir ziehen hier 'b_start' (die korrigierte Ziel-Startzeit als String) ab!
		shader_code += "\tfloat t_transform_sec = max(0.0, v_transform_time * 0.001);\n"
		shader_code += "\tfloat t_elem_transform = max(0.0, t_transform_sec - (" + b_start + " * 0.001));\n\n"
	else:
		# Nicht gebunden? Dann normal die eigene Startzeit abziehen.
		shader_code += "\tfloat t_elem_transform = max(0.0, (v_transform_time - LocalStartTime) * 0.001);\n\n"

	# --- NEU: Globale Variablen für die Pfad-Ausrichtung (CalcDir) ---
	shader_code += "\tbool apply_path_dir = false;\n"
	shader_code += "\tvec3 path_align_forward = vec3(0.0, 0.0, 1.0);\n\n"
	
	# ====================================================
	# ERWEITERTE DEBUG AUSGABE FÜR DEN SHADER
	# ====================================================
	if is_bound or parent_node.name == "Element_1_0_ID_101":
		print("\n=== DEBUG: ", parent_node.name, " ===")
		if is_bound:
			print("  -> Zieht die Zeit von: ", bind_ele)
			print("  -> Ziel StartTime (b_start): ", b_start)
			print("  -> Ziel TotalTime (b_total): ", b_total)
			print("  -> Ziel RepeatDelay (b_delay): ", b_delay)
			
		print("  EIGENE CONTROLLER VON ", parent_node.name, ":")
		for i in range(ctrl_methods.size()):
			var child = ctrl_methods[i]
			var ct = str(child.get("CtrlType"))
			
			# Die echten Parameter auslesen (wie wir es beim Ziel gemacht haben)
			var real_params = {}
			if child.get("parsed_data") != null and typeof(child.get("parsed_data")) == TYPE_DICTIONARY:
				real_params = child.parsed_data
			else:
				var schema = _get_node_params(child)
				for key in schema.keys():
					real_params[key] = child.get(key)
					
			print("  -> Typ: ", ct, " | Echte Parameter: ", real_params)
		print("===================================\n")
	
	# --- NEU: Wir merken uns im GDScript, welche KeyPoints einen Pfad haben ---
	var kp_bases_with_path = []
	for i in range(ctrl_methods.size()):
		if str(ctrl_methods[i].get("CtrlType")) == "110":
			kp_bases_with_path.append(ctrl_to_kp_basetime.get(i, 0.0))
	# --------------------------------------------------------------------------
	# -------------------------------------------------------------

	for i in range(ctrl_methods.size()):
		var child = ctrl_methods[i]
		var ctrl_type = str(child.get("CtrlType"))
		
		# 106 WURDE ZUR LISTE HINZUGEFÜGT
		if ctrl_type in ["100", "101", "104", "105", "106", "107", "108", "109", "110", "111"]:
			var kp_base = ctrl_to_kp_basetime.get(i, 0.0)
			var kp_dur = ctrl_to_kp_duration.get(i, -1.0)
			var prefix = "CtrlMethod_" + str(i) + "_"
			
			var t_choice = "t_elem_local" if ctrl_type in ["105", "106", "107", "108", "109", "111"] else "t_elem_transform"
			
			# ====================================================
			# NEU: DER ENTSCHEIDENDE CLAMP-FIX!
			# Wenn dieses Movement an das Ziel gebunden ist, übernehmen 
			# wir die Lebensdauer des Ziels (damit es nicht einfriert!)
			# ====================================================
			if is_bound and b_total != "LocalTotalTime" and t_choice == "t_elem_transform":
				var target_dur = float(b_total)
				if target_dur <= 0.0:
					kp_dur = -1.0 # Endlos machen, genau wie das Ziel!
				else:
					kp_dur = target_dur / 1000.0
			# ====================================================
			
			shader_code += "\t{\n"
			# Da wir die Zeit schon im Shader oben auf 'active_time - fb_start' normiert haben,
			# ziehen wir hier nur noch die kp_base ab:
			shader_code += "\t\tfloat kp_time = max(0.0, " + t_choice + " - " + str(kp_base) + ");\n"
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
				if blocked_by_110:
					shader_code += "\t\t// Blockiert: Ein Type_110 existiert im selben KeyPoint!\n"
				else:
					shader_code += "\t\tctrl_offset += dir * dist;\n"
				
			elif ctrl_type == "101":
				shader_code += "\t\tctrl_rot_z += (vel * t_run) + (0.5 * acc * t_run * t_run);\n"
				
			elif ctrl_type == "104":
				var origin_pos = "KP_0_Position" if has_kp0_position else "vec3(0.0)"
				shader_code += "\t\tvec3 avoid_pos = " + prefix + "Pos;\n"
				shader_code += "\t\tvec3 diff = " + origin_pos + " - avoid_pos;\n"
				shader_code += "\t\tvec3 dir = length(diff) > 0.0001 ? normalize(diff) : vec3(0.0);\n"
				shader_code += "\t\tfloat dist = (vel * t_run) + (0.5 * acc * t_run * t_run);\n"
				if blocked_by_110:
					shader_code += "\t\t// Blockiert: Ein Type_110 existiert im selben KeyPoint!\n"
				else:
					shader_code += "\t\tctrl_offset += dir * dist;\n"
			elif ctrl_type == "105":
				shader_code += "\t\tvec4 c_delta = " + prefix + "ColorDelta;\n"
				shader_code += "\t\tv_base_color += vec4(c_delta.r, c_delta.g, c_delta.a, c_delta.b) * t_run;\n"
				shader_code += "\t\tv_base_color.rgb = max(v_base_color.rgb, vec3(0.0));\n"
				shader_code += "\t\tv_base_color.a = clamp(v_base_color.a, 0.0, 1.0);\n"
			elif ctrl_type == "106":
				# --- NEU: Logik für 106 Scale Change (mit Limits Y=Min und Z=Max) ---
				shader_code += "\t\t// --- CTRL TYPE 106: SCALE ---\n"
				
				# Prüfen, ob der Parameter mit oder ohne 'n' geschrieben wurde
				var scale_key = "ScaleChange"
				if "ScaleChage" in child or child.get("ScaleChage") != null:
					scale_key = "ScaleChage"
					
				shader_code += "\t\tvec3 scale_change = " + prefix + scale_key + ";\n"
				shader_code += "\t\tfloat ds = scale_change.x * t_run;\n"
				
				# --- NEU: Die Limits Y (Min) und Z (Max) anwenden ---
				# Da die Basis-Skalierung 1.0 ist, subtrahieren wir 1.0 von den Limits
				shader_code += "\t\tds = clamp(ds, scale_change.y - 1.0, scale_change.z - 1.0);\n"
				
				# --- GLOBALE NoScale-Prüfung ---
				var has_noscale_1 = uniform_assignments.has("NoScale_1") or parsed_data.has("NoScale_1")
				var has_noscale_2 = uniform_assignments.has("NoScale_2") or parsed_data.has("NoScale_2")
				
				if parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY:
					if parsed_data["MainParameters"].has("NoScale_1"): has_noscale_1 = true
					if parsed_data["MainParameters"].has("NoScale_2"): has_noscale_2 = true

				if has_noscale_1:
					shader_code += "\t\tif (!NoScale_1) ctrl_scale_offset.x += ds;\n"
				else:
					shader_code += "\t\tctrl_scale_offset.x += ds;\n"
					
				if has_noscale_2:
					shader_code += "\t\tif (!NoScale_2) ctrl_scale_offset.y += ds;\n"
				else:
					shader_code += "\t\tctrl_scale_offset.y += ds;\n"
					
					
			elif ctrl_type == "107":
				# --- NEU: Logik für 107 Color Flicker ---
				shader_code += "\t\t// --- CTRL TYPE 107: COLOR FLICKER ---\n"
				
				# Parameter auslesen (BufLen ignorieren wir, da wir prozedurales Noise nutzen)
				shader_code += "\t\tint octaves = int(" + prefix + "OctaveNum);\n"
				shader_code += "\t\tfloat persistence = " + prefix + "Persistence;\n"
				shader_code += "\t\tfloat wave_len = max(0.001, " + prefix + "WaveLen);\n"
				
				# 500 bedeutet meistens 0.5 in dieser Engine-Logik
				shader_code += "\t\tfloat amplitude = " + prefix + "Amplitude * 0.001;\n" 
				
				# BaseColor aus dem Parameter ziehen
				shader_code += "\t\tvec4 base_col = " + prefix + "BaseColor;\n"
				
				# FBM Noise generieren. Die Zeit multiplizieren wir mit der Welle für die Geschwindigkeit.
				# Noise gibt Werte ungefähr zwischen 0.0 und 1.0 zurück.
				shader_code += "\t\tfloat n = fbm1D(t_run * wave_len, octaves, persistence);\n"
				
				# Flackern berechnen: 
				# Mitte ist 1.0 (normale Farbe). Wir lassen es mit der Amplitude nach oben/unten ausschlagen.
				shader_code += "\t\tfloat flicker = 1.0 + (n - 0.5) * amplitude * 2.0;\n"
				shader_code += "\t\tflicker = max(0.0, flicker);\n" # Keine negative Helligkeit!
				
				# Farbe VOLLSTÄNDIG überschreiben und mit Flackern multiplizieren (RGB + Alpha)
				shader_code += "\t\tv_base_color = base_col * vec4(flicker, flicker, flicker, flicker);\n"
				shader_code += "\t\tv_base_color.rgb = max(v_base_color.rgb, vec3(0.0));\n"
				shader_code += "\t\tv_base_color.a = clamp(v_base_color.a, 0.0, 1.0);\n"
			elif ctrl_type == "108":
				shader_code += "\t\t// --- CTRL TYPE 108: FADE & OVERWRITE ---\n"
				shader_code += "\t\tint count = int(" + prefix + "Count);\n"
				shader_code += "\t\tfloat t_ms = t_run * 1000.0;\n" 
				shader_code += "\t\tvec4 c_out = " + prefix + "Color;\n"
				shader_code += "\t\tfloat cur_time = 0.0;\n\n"
				
				shader_code += "\t\tif (count >= 1) {\n"
				shader_code += "\t\t\tfloat ts = max(0.0001, " + prefix + "TimeSpan);\n"
				shader_code += "\t\t\tif (t_ms <= cur_time + ts) c_out = mix(" + prefix + "Color, " + prefix + "Color_2, (t_ms - cur_time) / ts);\n"
				shader_code += "\t\t\tcur_time += ts;\n"
				shader_code += "\t\t}\n"
				shader_code += "\t\tif (count >= 2 && t_ms > cur_time - 0.0001) {\n"
				shader_code += "\t\t\tfloat ts = max(0.0001, " + prefix + "TimeSpan_2);\n"
				shader_code += "\t\t\tif (t_ms <= cur_time + ts) c_out = mix(" + prefix + "Color_2, " + prefix + "Color_3, (t_ms - cur_time) / ts);\n"
				shader_code += "\t\t\tcur_time += ts;\n"
				shader_code += "\t\t}\n"
				shader_code += "\t\tif (count >= 3 && t_ms > cur_time - 0.0001) {\n"
				shader_code += "\t\t\tfloat ts = max(0.0001, " + prefix + "TimeSpan_3);\n"
				shader_code += "\t\t\tif (t_ms <= cur_time + ts) c_out = mix(" + prefix + "Color_3, " + prefix + "Color_4, (t_ms - cur_time) / ts);\n"
				shader_code += "\t\t\tcur_time += ts;\n"
				shader_code += "\t\t}\n"
				shader_code += "\t\tif (count >= 4 && t_ms > cur_time - 0.0001) {\n"
				shader_code += "\t\t\tfloat ts = max(0.0001, " + prefix + "TimeSpan_4);\n"
				shader_code += "\t\t\tif (t_ms <= cur_time + ts) c_out = mix(" + prefix + "Color_4, " + prefix + "Color_5, (t_ms - cur_time) / ts);\n"
				shader_code += "\t\t\tcur_time += ts;\n"
				shader_code += "\t\t}\n"
				shader_code += "\t\tif (count >= 5 && t_ms > cur_time - 0.0001) {\n"
				shader_code += "\t\t\tfloat ts = max(0.0001, " + prefix + "TimeSpan_5);\n"
				shader_code += "\t\t\tif (t_ms <= cur_time + ts) c_out = mix(" + prefix + "Color_5, " + prefix + "Color_6, (t_ms - cur_time) / ts);\n"
				shader_code += "\t\t\tcur_time += ts;\n"
				shader_code += "\t\t}\n\n"
				
				shader_code += "\t\tif (t_ms > cur_time) {\n"
				shader_code += "\t\t\tif (count == 0) c_out = " + prefix + "Color;\n"
				shader_code += "\t\t\telse if (count == 1) c_out = " + prefix + "Color_2;\n"
				shader_code += "\t\t\telse if (count == 2) c_out = " + prefix + "Color_3;\n"
				shader_code += "\t\t\telse if (count == 3) c_out = " + prefix + "Color_4;\n"
				shader_code += "\t\t\telse if (count == 4) c_out = " + prefix + "Color_5;\n"
				shader_code += "\t\t\telse if (count >= 5) c_out = " + prefix + "Color_6;\n"
				shader_code += "\t\t}\n\n"
				
				shader_code += "\t\tv_base_color = c_out;\n"
				shader_code += "\t\tv_base_color.rgb = max(v_base_color.rgb, vec3(0.0));\n"
				shader_code += "\t\tv_base_color.a = clamp(v_base_color.a, 0.0, 1.0);\n"
			elif ctrl_type == "109":
				# --- NEU: Logik für 109 Scale Pulse (FBM Noise) ---
				shader_code += "\t\t// --- CTRL TYPE 109: SCALE PULSE ---\n"
				
				shader_code += "\t\tint octaves = int(" + prefix + "OctaveNum);\n"
				shader_code += "\t\tfloat persistence = " + prefix + "Persistence;\n"
				shader_code += "\t\tfloat wave_len = max(0.001, " + prefix + "WaveLen);\n"
				shader_code += "\t\tfloat amplitude = " + prefix + "Amplitude;\n" 
				#Geschwindigkeit = t_run
				shader_code += "\t\tfloat n = fbm1D((t_run * 1000.0) / wave_len, octaves, persistence);\n"
				
				# --- DER WACHSTUMS-FIX ---
				# "Es gibt immer nur Wachstum" -> Das Delta (ds) darf NIE negativ sein!
				# Unsere Noise-Funktion liefert ohnehin nur positive Werte. 
				# Wir verzichten auf das Abziehen von 0.5 und multiplizieren einfach mit der Amplitude.
				# Dadurch wächst das Sprite, fällt danach aber wieder weich auf seine Ursprungsgröße (0.0) zurück.
				shader_code += "\t\tfloat ds = n * amplitude;\n"
				
				# --- GLOBALE NoScale-Prüfung ---
				var has_noscale_1 = uniform_assignments.has("NoScale_1") or parsed_data.has("NoScale_1")
				var has_noscale_2 = uniform_assignments.has("NoScale_2") or parsed_data.has("NoScale_2")
				
				if parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY:
					if parsed_data["MainParameters"].has("NoScale_1"): has_noscale_1 = true
					if parsed_data["MainParameters"].has("NoScale_2"): has_noscale_2 = true

				if has_noscale_1:
					shader_code += "\t\tif (!NoScale_1) ctrl_scale_offset.x += ds;\n"
				else:
					shader_code += "\t\tctrl_scale_offset.x += ds;\n"
					
				if has_noscale_2:
					shader_code += "\t\tif (!NoScale_2) ctrl_scale_offset.y += ds;\n"
				else:
					shader_code += "\t\tctrl_scale_offset.y += ds;\n"
					###################################################
			elif ctrl_type == "110":
				# --- CTRL TYPE 110: PATH MOVEMENT (UNIFORM ARRAY) ---
				shader_code += "\t\t// --- CTRL TYPE 110: PATH MOVEMENT ---\n"
				
				var count = 0
				if "Count" in child or child.get("Count") != null:
					count = int(child.get("Count"))
					
				# NEU: Wir prüfen nur, ob der Parameter existiert, werten ihn aber NICHT aus.
				# Wir merken uns nur, ob es ein Bool ist, um den Shader-Code korrekt zu formatieren.
				var has_calc_dir = ("CalcDir" in child) or (child.get("CalcDir") != null)
				var calc_dir_is_bool = has_calc_dir and typeof(child.get("CalcDir")) == TYPE_BOOL
				
				if count > 1:
					shader_code += "\t\tfloat progress = 0.0;\n"
					shader_code += "\t\tif (duration > 0.001) {\n"
					shader_code += "\t\t\tprogress = clamp(t_run / duration, 0.0, 1.0);\n" 
					shader_code += "\t\t}\n"
					
					shader_code += "\t\tfloat f_idx = progress * " + str(count - 1) + ".0;\n"
					shader_code += "\t\tint i0 = int(floor(f_idx));\n"
					shader_code += "\t\tint i1 = min(i0 + 1, " + str(count - 1) + ");\n"
					shader_code += "\t\tfloat fract_t = fract(f_idx);\n"
					
					shader_code += "\t\tvec3 p0 = " + prefix + "Type_110_Pos_Array[i0];\n"
					shader_code += "\t\tvec3 p1 = " + prefix + "Type_110_Pos_Array[i1];\n"
					shader_code += "\t\tvec3 current_path_pos = mix(p0, p1, fract_t);\n"
					
					shader_code += "\t\tctrl_offset += current_path_pos;\n"
					
					# --- LIVE-ABFRAGE DER UNIFORM IM SHADER ---
					if has_calc_dir:
						# Unterscheiden, ob der Shader "if (Wert)" oder "if (Wert > 0)" braucht
						var condition = prefix + "CalcDir" if calc_dir_is_bool else prefix + "CalcDir > 0"
						
						shader_code += "\t\tif (" + condition + ") {\n"
						shader_code += "\t\t\tvec3 p_dir = p1 - p0;\n"
						shader_code += "\t\t\tif (length(p_dir) < 0.001 && i0 > 0) {\n"
						shader_code += "\t\t\t\tp_dir = p0 - " + prefix + "Type_110_Pos_Array[i0 - 1];\n"
						shader_code += "\t\t\t}\n"
						
						shader_code += "\t\t\tif (length(p_dir) > 0.001) {\n"
						shader_code += "\t\t\t\tapply_path_dir = true;\n"
						shader_code += "\t\t\t\tpath_align_forward = normalize(p_dir);\n"
						shader_code += "\t\t\t}\n"
						shader_code += "\t\t}\n"
			####################################################
			elif ctrl_type == "111":
				# --- CTRL TYPE 111: MULTI-STAGE SCALE ---
				shader_code += "\t\t// --- CTRL TYPE 111: MULTI-STAGE SCALE ---\n"
				shader_code += "\t\tint count = int(" + prefix + "Count);\n"
				shader_code += "\t\tfloat t_ms = t_run * 1000.0;\n" 
				shader_code += "\t\tfloat s_out = " + prefix + "Scale;\n"
				shader_code += "\t\tfloat cur_time = 0.0;\n\n"
				
				# Transition 1 (Scale -> Scale_2)
				shader_code += "\t\tif (count >= 1) {\n"
				shader_code += "\t\t\tfloat ts = max(0.0001, " + prefix + "TimeSpan);\n"
				shader_code += "\t\t\tif (t_ms <= cur_time + ts) s_out = mix(" + prefix + "Scale, " + prefix + "Scale_2, (t_ms - cur_time) / ts);\n"
				shader_code += "\t\t\tcur_time += ts;\n"
				shader_code += "\t\t}\n"
				
				# Transition 2 (Scale_2 -> Scale_3)
				shader_code += "\t\tif (count >= 2 && t_ms > cur_time - 0.0001) {\n"
				shader_code += "\t\t\tfloat ts = max(0.0001, " + prefix + "TimeSpan_2);\n"
				shader_code += "\t\t\tif (t_ms <= cur_time + ts) s_out = mix(" + prefix + "Scale_2, " + prefix + "Scale_3, (t_ms - cur_time) / ts);\n"
				shader_code += "\t\t\tcur_time += ts;\n"
				shader_code += "\t\t}\n"
				
				# Transition 3 (Scale_3 -> Scale_4)
				shader_code += "\t\tif (count >= 3 && t_ms > cur_time - 0.0001) {\n"
				shader_code += "\t\t\tfloat ts = max(0.0001, " + prefix + "TimeSpan_3);\n"
				shader_code += "\t\t\tif (t_ms <= cur_time + ts) s_out = mix(" + prefix + "Scale_3, " + prefix + "Scale_4, (t_ms - cur_time) / ts);\n"
				shader_code += "\t\t\tcur_time += ts;\n"
				shader_code += "\t\t}\n"
				
				# Transition 4 (Scale_4 -> Scale_5)
				shader_code += "\t\tif (count >= 4 && t_ms > cur_time - 0.0001) {\n"
				shader_code += "\t\t\tfloat ts = max(0.0001, " + prefix + "TimeSpan_4);\n"
				shader_code += "\t\t\tif (t_ms <= cur_time + ts) s_out = mix(" + prefix + "Scale_4, " + prefix + "Scale_5, (t_ms - cur_time) / ts);\n"
				shader_code += "\t\t\tcur_time += ts;\n"
				shader_code += "\t\t}\n"
				
				# Transition 5 (Scale_5 -> Scale_6)
				shader_code += "\t\tif (count >= 5 && t_ms > cur_time - 0.0001) {\n"
				shader_code += "\t\t\tfloat ts = max(0.0001, " + prefix + "TimeSpan_5);\n"
				shader_code += "\t\t\tif (t_ms <= cur_time + ts) s_out = mix(" + prefix + "Scale_5, " + prefix + "Scale_6, (t_ms - cur_time) / ts);\n"
				shader_code += "\t\t\tcur_time += ts;\n"
				shader_code += "\t\t}\n\n"
				
				# Wenn wir am Ende angekommen sind, letzten Scale-Wert stur halten
				shader_code += "\t\tif (t_ms > cur_time) {\n"
				shader_code += "\t\t\tif (count == 0) s_out = " + prefix + "Scale;\n"
				shader_code += "\t\t\telse if (count == 1) s_out = " + prefix + "Scale_2;\n"
				shader_code += "\t\t\telse if (count == 2) s_out = " + prefix + "Scale_3;\n"
				shader_code += "\t\t\telse if (count == 3) s_out = " + prefix + "Scale_4;\n"
				shader_code += "\t\t\telse if (count == 4) s_out = " + prefix + "Scale_5;\n"
				shader_code += "\t\t\telse if (count >= 5) s_out = " + prefix + "Scale_6;\n"
				shader_code += "\t\t}\n\n"
				
				# --- Anwenden auf den Offset ---
				# Da unser Sprite standardmäßig Scale 1.0 hat, müssen wir -1.0 rechnen. 
				# (Wenn Scale 0.0 ist -> ds = -1.0 -> 1.0 + (-1.0) = 0.0)
				shader_code += "\t\tfloat ds = s_out - 1.0;\n"
				
				# --- GLOBALE NoScale-Prüfung (Wie bei 106 & 109) ---
				var has_noscale_1 = uniform_assignments.has("NoScale_1") or parsed_data.has("NoScale_1")
				var has_noscale_2 = uniform_assignments.has("NoScale_2") or parsed_data.has("NoScale_2")
				
				if parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY:
					if parsed_data["MainParameters"].has("NoScale_1"): has_noscale_1 = true
					if parsed_data["MainParameters"].has("NoScale_2"): has_noscale_2 = true

				if has_noscale_1:
					shader_code += "\t\tif (!NoScale_1) ctrl_scale_offset.x += ds;\n"
				else:
					shader_code += "\t\tctrl_scale_offset.x += ds;\n"
					
				if has_noscale_2:
					shader_code += "\t\tif (!NoScale_2) ctrl_scale_offset.y += ds;\n"
				else:
					shader_code += "\t\tctrl_scale_offset.y += ds;\n"
			shader_code += "\t}\n"

	# ====================================================
	# 2. MESH ERSTELLEN & SKALIEREN
	# ====================================================
	shader_code += "\n\t// --- INITIALE GRÖSSE ---\n"
	shader_code += "\tvec3 local_pos = VERTEX;\n"
	
	# ====================================================
	# ORG_PT (ORIGIN POINT / PIVOT) AUSLESEN & ANWENDEN
	# ====================================================
	# Wir prüfen, ob die Parameter existieren. Wenn nicht, ist der Standard 0.5 (Mitte)
	var has_org1 = parsed_data.has("OrgPt_1") or (parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY and parsed_data["MainParameters"].has("OrgPt_1"))
	var has_org2 = parsed_data.has("OrgPt_2") or (parsed_data.has("MainParameters") and typeof(parsed_data["MainParameters"]) == TYPE_DICTIONARY and parsed_data["MainParameters"].has("OrgPt_2"))
	
	var org1_str = "float(OrgPt_1)" if has_org1 else "0.5"
	var org2_str = "float(OrgPt_2)" if has_org2 else "0.5"
	
	if parsed_data.has("Width"): 
		shader_code += "\tlocal_pos.x = (UV.x - (1.0 - " + org1_str + ")) * (Width * 2.0);\n"
	if parsed_data.has("Height"): 
		shader_code += "\tlocal_pos.y = ((1.0 - " + org2_str + ") - UV.y) * (Height * 2.0);\n"
		
	if has_kp0_scale:
		shader_code += "\n\t// --- SKALIERUNG (KP 0 Scale) ---\n"
		shader_code += "\tlocal_pos *= KP_0_Scale;\n"

	# --- NEU: DYNAMISCHE SKALIERUNG ANWENDEN (Type 106) ---
	shader_code += "\n\t// --- DYNAMISCHE SKALIERUNG (CtrlType 106) ---\n"
	# min. 0.0 verhindert, dass sich das Sprite bei Über-Schrumpfung umkehrt
	shader_code += "\tlocal_pos.xy *= max(vec2(0.0), vec2(1.0) + ctrl_scale_offset);\n"

	# ====================================================
	# 3. TYP 101 & BASIS-ROTATION
	# ====================================================
	shader_code += "\n\t// --- LOKALE Z-ROTATION (CtrlType 101) ---\n"
	shader_code += "\tif (abs(ctrl_rot_z) > 0.0001) {\n"
	shader_code += "\t\tfloat s = sin(ctrl_rot_z);\n"
	shader_code += "\t\tfloat c = cos(ctrl_rot_z);\n"
	shader_code += "\t\tfloat nx = local_pos.x * c - local_pos.y * s;\n"
	shader_code += "\t\tfloat ny = local_pos.x * s + local_pos.y * c;\n"
	shader_code += "\t\tlocal_pos.x = nx;\n"
	shader_code += "\t\tlocal_pos.y = ny;\n"
	shader_code += "\t}\n"

	# --- NEU: Zuweisung der Rotation (Path-Alignment ODER KeyPoint-Direction) ---
	shader_code += "\n\t// --- ROTATION (Path CalcDir oder KP 0 Direction) ---\n"
	shader_code += "\tif (apply_path_dir) {\n"
	shader_code += "\t\t// Objekt auf den Pfad ausrichten\n"
	shader_code += "\t\tvec3 forward = path_align_forward;\n"
	shader_code += "\t\tvec3 up = vec3(0.0, 1.0, 0.0);\n"
	shader_code += "\t\tif (abs(dot(forward, up)) > 0.999) up = vec3(1.0, 0.0, 0.0);\n"
	shader_code += "\t\tvec3 right = normalize(cross(up, forward));\n"
	shader_code += "\t\tup = normalize(cross(forward, right));\n"
	shader_code += "\t\tlocal_pos = local_pos.x * right + local_pos.y * up + local_pos.z * forward;\n"
	shader_code += "\t}\n"


	if has_kp0_direction:
		shader_code += "\n\t// --- ROTATION (KP 0 Direction) ---\n"
		shader_code += "\tvec4 q = KP_0_Direction;\n"
		shader_code += "\tlocal_pos = local_pos + 2.0 * cross(q.xyz, cross(q.xyz, local_pos) + q.w * local_pos);\n"

	# ====================================================
	# 4. POSITIONIERUNG & ORBIT (CtrlType 102 & 103)
	# ====================================================
	shader_code += "\n\t// --- ZIELPOSITION STARTWERT ---\n"
	if has_kp0_position:
		shader_code += "\tvec3 target_pos = KP_0_Position;\n"
	else:
		shader_code += "\tvec3 target_pos = vec3(0.0);\n"

	var has_ctrl_102_103 = false
	for child in ctrl_methods:
		var ct = str(child.get("CtrlType"))
		if ct == "102" or ct == "103":
			has_ctrl_102_103 = true
			break
			
	if has_ctrl_102_103:
		shader_code += "\n\t// --- 3D ORBIT & ACHSENROTATION (CtrlType 102 & 103) ---\n"
		for i in range(ctrl_methods.size()):
			var child = ctrl_methods[i]
			var ct = str(child.get("CtrlType"))
			if ct == "102" or ct == "103":
				var kp_base = ctrl_to_kp_basetime.get(i, 0.0)
				var kp_dur = ctrl_to_kp_duration.get(i, -1.0)
				var prefix = "CtrlMethod_" + str(i) + "_"
				
				# ====================================================
				# NEU: CLAMP-FIX FÜR DIE ORBIT ROTATION!
				# ====================================================
				if is_bound and b_total != "LocalTotalTime":
					var target_dur = float(b_total)
					if target_dur <= 0.0:
						kp_dur = -1.0
					else:
						kp_dur = target_dur / 1000.0
				# ====================================================
				
				shader_code += "\t{\n"
				# Hier nehmen wir IMMER t_elem_transform, weil 102 und 103 immer Bewegungen sind!
				shader_code += "\t\tfloat kp_time = max(0.0, t_elem_transform - " + str(kp_base) + ");\n"
				shader_code += "\t\tfloat start = " + prefix + "StartTime;\n"
				shader_code += "\t\tfloat end = " + prefix + "EndTime;\n"
				shader_code += "\t\tfloat t_run = max(0.0, kp_time - start);\n"
				
				shader_code += "\t\tif (end != -1.0) {\n"
				shader_code += "\t\t\tt_run = min(t_run, max(0.0, end - start));\n"
				if kp_dur != -1.0:
					shader_code += "\t\t} else {\n"
					shader_code += "\t\t\tt_run = min(t_run, max(0.0, " + str(kp_dur) + " - start));\n"
				shader_code += "\t\t}\n"
				
				shader_code += "\t\tfloat vel = " + prefix + "Vel;\n"
				shader_code += "\t\tfloat acc = " + prefix + "Acc;\n"
				shader_code += "\t\tfloat angle = (vel * t_run) + (0.5 * acc * t_run * t_run);\n"
				
				shader_code += "\t\tvec3 pivot = " + prefix + "Pos;\n"
				shader_code += "\t\tvec3 axis = " + prefix + "Axis;\n"
				
				shader_code += "\t\tif (length(axis) > 0.0001 && abs(angle) > 0.0001) {\n"
				shader_code += "\t\t\tvec3 k = normalize(axis);\n"
				shader_code += "\t\t\tfloat c = cos(angle);\n"
				shader_code += "\t\t\tfloat s = sin(angle);\n"
				
				shader_code += "\t\t\t// 1. ORBIT (Für 102 und 103)\n"
				shader_code += "\t\t\tvec3 v_center = target_pos - pivot;\n"
				shader_code += "\t\t\ttarget_pos = v_center * c + cross(k, v_center) * s + k * dot(k, v_center) * (1.0 - c) + pivot;\n"
				
				if ct == "102":
					shader_code += "\t\t\t// 2. EIGENDREHUNG (Nur für 102)\n"
					shader_code += "\t\t\tvec3 v_axis = axis;\n"
					shader_code += "\t\t\tif (RotFromView) {\n"
					shader_code += "\t\t\t\tv_axis.y = 0.0;\n"
					shader_code += "\t\t\t}\n"
					shader_code += "\t\t\tif (length(v_axis) > 0.0001) {\n"
					shader_code += "\t\t\t\tvec3 vk = normalize(v_axis);\n"
					shader_code += "\t\t\t\tlocal_pos = local_pos * c + cross(vk, local_pos) * s + vk * dot(vk, local_pos) * (1.0 - c);\n"
					shader_code += "\t\t\t}\n"
				
				shader_code += "\t\t}\n"
				shader_code += "\t}\n"

	# ====================================================
	# 5. BILLBOARD (Z-Billboard via RotFromView ODER Normales Billboard)
	# ====================================================
	shader_code += "\n\t// --- BILLBOARDING ---\n"
	
	# Kameraposition im lokalen Raum brauchen wir für beide Varianten
	shader_code += "\tvec3 cam_pos_local = (inverse(MODEL_MATRIX) * vec4(INV_VIEW_MATRIX[3].xyz, 1.0)).xyz;\n\n"

	shader_code += "\tif (RotFromView) {\n"
	shader_code += "\t\t// --- Z-BILLBOARD (Richtet sich nach lokaler Z-Achse, rotiert durch KP_0_Direction) ---\n"
	shader_code += "\t\tvec3 look_dir = cam_pos_local - target_pos;\n"

	if has_kp0_direction:
		shader_code += "\t\tvec4 q = KP_0_Direction;\n"
		shader_code += "\t\tvec3 base_z = vec3(0.0, 0.0, 1.0);\n"
		shader_code += "\t\tvec3 new_z = base_z + 2.0 * cross(q.xyz, cross(q.xyz, base_z) + q.w * base_z);\n"
		shader_code += "\t\tvec3 base_y = vec3(0.0, 1.0, 0.0);\n"
		shader_code += "\t\tvec3 new_y = base_y + 2.0 * cross(q.xyz, cross(q.xyz, base_y) + q.w * base_y);\n"
		shader_code += "\t\tvec3 base_x = vec3(1.0, 0.0, 0.0);\n"
		shader_code += "\t\tvec3 new_x = base_x + 2.0 * cross(q.xyz, cross(q.xyz, base_x) + q.w * base_x);\n"
	else:
		shader_code += "\t\tvec3 new_z = vec3(0.0, 0.0, 1.0);\n"
		shader_code += "\t\tvec3 new_y = vec3(0.0, 1.0, 0.0);\n"
		shader_code += "\t\tvec3 new_x = vec3(1.0, 0.0, 0.0);\n"

	shader_code += "\t\t// Projektion der Kamerarichtung auf die Ebene senkrecht zur neuen Z-Achse\n"
	shader_code += "\t\tvec3 target_y = look_dir - new_z * dot(look_dir, new_z);\n"
	shader_code += "\t\tif (length(target_y) > 0.001) {\n"
	shader_code += "\t\t\ttarget_y = normalize(target_y);\n"
	shader_code += "\t\t\t// Die X-Achse steht senkrecht auf Y und Z (Kreuzprodukt)\n"
	shader_code += "\t\t\tvec3 target_x = normalize(cross(target_y, new_z));\n"
	shader_code += "\t\t\t\n"
	shader_code += "\t\t\t// local_pos zerlegen\n"
	shader_code += "\t\t\tfloat px = dot(local_pos, new_x);\n"
	shader_code += "\t\t\tfloat py = dot(local_pos, new_y);\n"
	shader_code += "\t\t\tfloat pz = dot(local_pos, new_z);\n"
	shader_code += "\t\t\t\n"
	shader_code += "\t\t\tlocal_pos = -px * target_x + py * new_z + pz * target_y;\n"
	shader_code += "\t\t}\n"
	
	shader_code += "\t} else {\n"
	shader_code += "\t\t// --- NORMALES BILLBOARD (Immer zur Kamera ausgerichtet) ---\n"
	shader_code += "\t\tvec3 look_dir = cam_pos_local - (target_pos + ctrl_offset);\n"
	shader_code += "\t\tif (length(look_dir) > 0.001) {\n"
	shader_code += "\t\t\tlook_dir = normalize(look_dir);\n"
	shader_code += "\t\t\tvec3 b_up = vec3(0.0, 1.0, 0.0);\n"
	shader_code += "\t\t\t// Fallback, falls die Kamera direkt von exakt oben/unten schaut\n"
	shader_code += "\t\t\tif (abs(dot(look_dir, b_up)) > 0.999) b_up = vec3(1.0, 0.0, 0.0);\n"
	shader_code += "\t\t\tvec3 b_right = normalize(cross(b_up, look_dir));\n"
	shader_code += "\t\t\tb_up = normalize(cross(look_dir, b_right));\n"
	shader_code += "\t\t\tlocal_pos = local_pos.x * b_right + local_pos.y * b_up + local_pos.z * look_dir;\n"
	shader_code += "\t\t}\n"
	shader_code += "\t}\n"

	shader_code += "\n\t// --- VERSCHIEBUNG (Orbit-Position + Translation aus Ctrl 100/104/110) ---\n"
	shader_code += "\tlocal_pos += target_pos + ctrl_offset;\n"
	
	shader_code += "\n\tVERTEX = local_pos;\n"
	shader_code += "}\n\n"
	
	shader_code += "void fragment() {\n"
	shader_code += "\t// --- SICHTBARKEITS-PRÜFUNG ---\n"
	shader_code += "\tif (!Is_Endless && (v_current_time < LocalStartTime || v_current_time > LocalTotalTime)) {\n"
	shader_code += "\t\tdiscard;\n"
	shader_code += "\t}\n\n"
	
	# ====================================================
	# UV MANIPULATION & ANIMATION (Mit Fallbacks)
	# ====================================================
	shader_code += "\n\t// --- UV MANIPULATION ---\n"
	shader_code += "\tvec2 final_uv = UV;\n"
	
	var p_main = parsed_data.get("MainParameters", {}) if typeof(parsed_data.get("MainParameters")) == TYPE_DICTIONARY else {}
	
	# UV Manipulation nur in den Shader schreiben, wenn sie existiert
	if parsed_data.has("UVExchg") or p_main.has("UVExchg"):
		shader_code += "\tif (UVExchg) {\n"
		shader_code += "\t\tfinal_uv = final_uv.yx;\n"
		shader_code += "\t}\n"
		
	if parsed_data.has("UReverse") or p_main.has("UReverse"):
		shader_code += "\tif (UReverse) {\n"
		shader_code += "\t\tfinal_uv.x = 1.0 - final_uv.x;\n"
		shader_code += "\t}\n"
		
	if parsed_data.has("VReverse") or p_main.has("VReverse"):
		shader_code += "\tif (VReverse) {\n"
		shader_code += "\t\tfinal_uv.y = 1.0 - final_uv.y;\n"
		shader_code += "\t}\n"
		
	# ====================================================
	# TILE MODE & SPRITE SHEET ANIMATION (Mit Fallbacks)
	# ====================================================
	var has_texcol = parsed_data.has("TexCol") or p_main.has("TexCol")
	var has_texrow = parsed_data.has("TexRow") or p_main.has("TexRow")
	
	var has_tile = parsed_data.has("TileMode") or p_main.has("TileMode")
	var has_speed1 = parsed_data.has("TexSpeed_1") or p_main.has("TexSpeed_1")
	var has_speed2 = parsed_data.has("TexSpeed_2") or p_main.has("TexSpeed_2")

	# Wir generieren den Block nur, wenn mindestens eines der Features genutzt wird
	if has_texcol or has_texrow or has_tile or has_speed1 or has_speed2:
		shader_code += "\n\t// --- TILE MODE & SPRITE ANIMATION ---\n"
		
		var col_str = "float(TexCol)" if has_texcol else "1.0"
		var row_str = "float(TexRow)" if has_texrow else "1.0"
		var int_str = "float(TexInterval)" if (parsed_data.has("TexInterval") or p_main.has("TexInterval")) else "50.0"
		
		shader_code += "\tfloat f_cols = max(1.0, " + col_str + ");\n"
		shader_code += "\tfloat f_rows = max(1.0, " + row_str + ");\n"
		shader_code += "\tfloat f_interval = max(1.0, " + int_str + ");\n\n"
		
		if has_tile:
			# TileMode wirkt als Schalter!
			shader_code += "\tif (TileMode) {\n"
			
			shader_code += "\t\t// --- 1. TILE MODE (Scrollen & Kacheln) ---\n"
			# UVs mit Spalten/Zeilen multiplizieren, um das Bild zu kacheln
			shader_code += "\t\tfinal_uv.x *= f_cols;\n"
			shader_code += "\t\tfinal_uv.y *= f_rows;\n"
			
			# Sicherstellen, dass der Shader nicht abstürzt, wenn Speed_1 oder 2 fehlt
			var ts1_str = "float(TexSpeed_1)" if has_speed1 else "0.0"
			var ts2_str = "float(TexSpeed_2)" if has_speed2 else "0.0"
			
			# Textur scrollen! v_current_time ist in ms, daher / 1000.0 für saubere Sekunden
			shader_code += "\t\tfinal_uv.x += (v_current_time / 1000.0) * " + ts1_str + ";\n"
			shader_code += "\t\tfinal_uv.y += (v_current_time / 1000.0) * " + ts2_str + ";\n"
			
			shader_code += "\t} else {\n"
		else:
			# Fallback, falls TileMode in dieser Datei gar nicht existiert
			shader_code += "\t{\n"
			
		shader_code += "\t\t// --- 2. NORMALE ANIMATION (Frames) ---\n"
		shader_code += "\t\tif (f_cols > 1.0 || f_rows > 1.0) {\n"
		shader_code += "\t\t\tfloat total_frames = f_cols * f_rows;\n"
		shader_code += "\t\t\tfloat current_frame = floor(v_current_time / f_interval);\n"
		shader_code += "\t\t\tcurrent_frame = mod(current_frame, total_frames);\n\n"
		
		shader_code += "\t\t\tfloat frame_x = mod(current_frame, f_cols);\n"
		shader_code += "\t\t\tfloat frame_y = floor(current_frame / f_cols);\n\n"
		
		shader_code += "\t\t\tfinal_uv.x = (final_uv.x / f_cols) + (frame_x / f_cols);\n"
		shader_code += "\t\t\tfinal_uv.y = (final_uv.y / f_rows) + (frame_y / f_rows);\n"
		shader_code += "\t\t}\n"
		
		shader_code += "\t}\n" # Schließt den if(TileMode) oder den Fallback-Block

	# 4. Textur auslesen (dieser Teil bleibt immer gleich)
	shader_code += "\n\tvec4 tex_color = texture(TexFile, final_uv);\n"
	#########################################################################
	# ====================================================
	# FARBAUSGABE ODER WARP-VERZERRUNG
	# ====================================================
	if has_warp:
		shader_code += "\n\t// --- WARP (HEAT DISTORTION / LINSE) ---\n"
		shader_code += "\tif (Warp) {\n"
		
		# 1. Normalmap entschlüsseln
		shader_code += "\t\tvec3 normal_map = tex_color.rgb * 2.0 - 1.0;\n"
		shader_code += "\t\tnormal_map = mix(vec3(0.0, 0.0, 1.0), normal_map, tex_color.a);\n"
		shader_code += "\t\tnormal_map = normalize(normal_map);\n"
		
		# 2. DIE ECHTE LINSEN-KRÜMMUNG (Refraction Math):
		# Indem wir durch Z teilen, bricht das Licht an den Kanten der Normalmap extrem stark.
		# Das erzeugt den perfekten, dreidimensionalen Lupen-Effekt!
		shader_code += "\t\tvec2 warp_dir = normal_map.xy / max(normal_map.z, 0.1);\n"
		
		# 3. OFFSET BERECHNEN:
		# v_base_color.a (Das Ein-/Ausblenden des Effekts) reduziert nur noch die STÄRKE,
		# macht das Objekt aber nicht mehr transparent! Das verhindert milchiges Ghosting.
		shader_code += "\t\tvec2 offset = warp_dir * 0.50 * v_base_color.a;\n"
		
		# 4. Verzerrten Hintergrund holen
		shader_code += "\t\tvec3 distorted_bg = texture(screen_texture, SCREEN_UV + offset).rgb;\n"
		shader_code += "\t\tALBEDO = distorted_bg;\n"
		
		# 5. ALPHA LÖSUNG:
		# Wir nutzen NUR noch die Form der Textur, damit der unsichtbare Rahmen weg bleibt.
		shader_code += "\t\tALPHA = tex_color.a;\n"
		
		shader_code += "\t} else {\n"
		shader_code += "\t\t// Warp ist aus -> Sprite GANZ NORMAL zeichnen\n"
		shader_code += "\t\ttex_color *= v_base_color;\n"
		
		if render_blend_mode == "blend_mix":
			shader_code += "\t\ttex_color.a *= 0.70;\n"
			
		shader_code += "\t\tALBEDO = tex_color.rgb;\n"
		shader_code += "\t\tALPHA = tex_color.a;\n"
		shader_code += "\t}\n"
		
	else:
		shader_code += "\n\t// --- NORMALE FARBANPASSUNG ---\n"
		shader_code += "\ttex_color *= v_base_color;\n\n"
		
		if render_blend_mode == "blend_mix":
			shader_code += "\t// Alpha leicht dämpfen, damit Mix-Sprites nicht zu massiv wirken\n"
			shader_code += "\ttex_color.a *= 0.70;\n\n"
			
		shader_code += "\tALBEDO = tex_color.rgb;\n"
		shader_code += "\tALPHA = tex_color.a;\n"
		
	shader_code += "}\n"
		
	
	shader.code = preload("gfx_parser.gd").add_gfx_alpha(shader_code)
	mat.shader = shader
	
	for uniform_name in uniform_assignments.keys():
		var val = uniform_assignments[uniform_name]
		if val != null:
			if val is Color:
				mat.set_shader_parameter(uniform_name, Vector4(val.r, val.g, val.b, val.a))
			elif typeof(val) == TYPE_STRING:
				if val.to_lower() == "true":
					mat.set_shader_parameter(uniform_name, true)
				elif val.to_lower() == "false":
					mat.set_shader_parameter(uniform_name, false)
				elif val.is_valid_int() and not "." in val:
					mat.set_shader_parameter(uniform_name, int(val))
				elif val.is_valid_float():
					mat.set_shader_parameter(uniform_name, float(val))
				else:
					mat.set_shader_parameter(uniform_name, val)
			else:
				mat.set_shader_parameter(uniform_name, val)
	
	# Priority an den Shader (für den Z-Achsen Offset)
	mat.render_priority = priority_val
	sprite.material_override = mat
	
	# ====================================================
	# NODE3D TRANSFORM OFFSET (Z-Fighting Fix)
	# ====================================================
	var sprite_index = 0
	
	# Wir lesen die Element-Nummer einfach direkt aus dem Namen des parent_node aus!
	# z.B. bei "Element_2_0_ID_100" holen wir uns die "2"
	var p_name = str(parent_node.name)
	if p_name.begins_with("Element_"):
		var parts = p_name.split("_")
		if parts.size() > 1 and parts[1].is_valid_int():
			sprite_index = int(parts[1])
	else:
		# Fallback, falls der Name mal anders ist
		sprite_index = parent_node.get_index()
		if sprite_index < 0: sprite_index = 0
			
	var face_dir = Vector3(0, 0, 1) 
	
	if uniform_assignments.has("KP_0_Direction"):
		var dir_val = uniform_assignments["KP_0_Direction"]
		var q = Quaternion(dir_val.x, dir_val.y, dir_val.z, dir_val.w)
		face_dir = q * Vector3(0, 0, 1)
		# print("Sprite_Index: ", sprite_index, " | Face-Achse: ", face_dir)

	# Sprite physisch verschieben (die Position wird im Arbeitsspeicher gesetzt 
	# und dann vom UndoRedo-Manager mitsamt dieser Position in die Szene geladen)
	sprite.position += face_dir.normalized() * (sprite_index * 0.001)
	# ====================================================
	
	
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
