@tool
extends RefCounted

# ====================================================
# .gfx-Parser und Node-Aufbau, gemeinsam für pwe_manager.gd ("GFX Ausführen": GFX_Load -> Szene)
# und create_id_200.gd (Container: Unter-GFX aus den Spieldaten über gfx_sources.gd).
# Die .gfx dürfen GBK (Spieldaten) oder UTF-8 (eigene in GFX_Load) sein.
# Ein Datei-Node sieht immer gleich aus:
#   <Datei> (gfx_data_node.gd, Kopfzeile)
#     Element_<n>_ID_<id> (gfx_element_<id>.gd)
#       Affectors / CtrlMethods
#         Affector_<n>_Type_<typ> / CtrlMethod_<n>_Type_<typ> (gfx_ctrl_<typ>.gd)
# parsed_data wird nicht mit der Szene gespeichert, die Erstell-Skripte lesen es beim Erstellen.
# ====================================================

const LOAD_DIR = "res://GFX_Load/" # wird mit "GFX Ausführen" in die Szene geladen

var _dir = ""
static var _text = null # angelica_files.gd, nur zum Dekodieren


func _init() -> void:
	_dir = get_script().resource_path.get_base_dir()

# Baut den Datei-Node einer .gfx (nicht in der Szene). skipped_ids sammelt unbekannte Element-IDs.
func build_file_node(file_path: String, node_name: String, skipped_ids: Array = []) -> Node3D:
	var parsed_file = _parse_full_gfx_file_chunked(file_path)
	var file_node = Node3D.new()
	file_node.name = node_name
	file_node.set_script(load(_dir.path_join("gfx_data_node.gd")))
	file_node.parsed_data = parsed_file["header"]
	# Herkunft, z.B. für die .gphy daneben (ID 220)
	file_node.parsed_data["_file_path"] = file_path
	# DedaultScale: A3DGFXEx::CalcActualScale = DefScale * Scale -> Scale des Datei-Nodes
	var def_scale = float(str(file_node.parsed_data.get("DedaultScale", "1")))
	if def_scale != 1.0:
		file_node.scale = Vector3.ONE * def_scale

	var element_count = 1
	for element_dict in parsed_file["elements"]:
		var raw_id = element_dict.get("_system_id", "Unknown")
		var script_path = _dir.path_join("gfx_element_" + raw_id + ".gd")
		if not ResourceLoader.exists(script_path):
			skipped_ids.append(raw_id)
			continue

		var element_node = Node3D.new()
		element_node.name = "Element_" + String.num(element_count) + "_ID_" + raw_id
		element_count += 1
		element_node.set_script(load(script_path))
		element_node.parsed_data = element_dict
		file_node.add_child(element_node)

		_spawn_ctrl_nodes("Affector", element_dict.get("_affectors", []), element_node)
		_spawn_ctrl_nodes("CtrlMethod", element_dict.get("_ctrl_methods", []), element_node)
	return file_node

static func _decoder():
	if _text == null:
		_text = preload("../Data/angelica_files.gd").new()
	return _text

# Den Dekodierer freigeben (Ende eines Imports, Plugin entladen): als statische Variable hielte er
# sonst die Skripte bis zum Beenden fest ("resources still in use at exit")
static func release_decoder() -> void:
	_text = null

# GFX-Alpha (Header / Container): GeometryInstance3D.transparency wirkt bei eigenen Shadern nicht,
# daher bekommt jeder erzeugte Shader ein Uniform, das ALPHA am Ende von fragment() multipliziert.
# Ein Material-Uniform, kein Instanz-Uniform: jede Instanz mit Instanz-Uniforms belegt 16 Plätze im
# globalen Puffer (Standard 65536), Maps mit tausenden GFX liefen über ("Too many instances using
# shader instance variables"). Header und Container haben ohnehin eigene Material-Kopien je GFX.
static func add_gfx_alpha(code: String) -> String:
	var at = code.find("void fragment()")
	if at < 0 or "GFX_Alpha" in code:
		return code
	# Funktionsende: "}" am Zeilenanfang (Blöcke darin sind eingerückt)
	var end = code.find("\n}", at)
	if end < 0:
		return code
	code = code.substr(0, end + 1) + "\tALPHA *= GFX_Alpha;\n" + code.substr(end + 1)
	return code.substr(0, at) + "// GFX-Alpha (Header / Container), je GFX gesetzt\nuniform float GFX_Alpha = 1.0;\n\n" + code.substr(at)

# Alpha der ganzen GFX an einem Node: GFX_Alpha, sonst transparency (StandardMaterial / ältere Shader)
static func set_gfx_alpha(g: GeometryInstance3D, a: float) -> void:
	var m = g.material_override
	if m is ShaderMaterial and m.shader != null and "GFX_Alpha" in m.shader.code:
		if "instance uniform float GFX_Alpha" in m.shader.code: # vor dem Umbau importierte Szenen
			g.set_instance_shader_parameter("GFX_Alpha", a)
		else:
			m.set_shader_parameter("GFX_Alpha", a)
	else:
		g.transparency = clampf(1.0 - a, 0.0, 1.0)

# 2DRender der GFX (Datei-Node über dem Element): A3DGFXEx::IsZTestEnable() = !2DRender
static func gfx_2d_render(element: Node) -> bool:
	var header = element.get_parent() if element != null else null
	var data = header.get("parsed_data") if header != null else null
	return typeof(data) == TYPE_DICTIONARY and str(data.get("2DRender", "0")).strip_edges() == "1"

# Tiefentest eines Elements: m_pGfx->IsZTestEnable() && m_bZEnable
static func z_test_enabled(element: Node, parsed_data: Dictionary) -> bool:
	var z = str(parsed_data.get("ZEnable", "1")).strip_edges().to_lower() in ["1", "true"]
	return z and not gfx_2d_render(element)

func _spawn_ctrl_nodes(group_name: String, data_list: Array, parent_node: Node) -> void:
	if data_list.is_empty(): return

	var container = Node3D.new()
	container.name = group_name + "s"
	parent_node.add_child(container)

	var count = 1
	for data in data_list:
		var type_id = data.get("CtrlType", "Unknown")
		var node = Node3D.new()
		node.name = group_name + "_" + str(count) + "_Type_" + type_id
		count += 1

		var script_path = _dir.path_join("gfx_ctrl_" + type_id + ".gd")
		if ResourceLoader.exists(script_path):
			node.set_script(load(script_path))
			node.parsed_data = data
		else:
			push_warning("PWE-Manager: Skript fehlt für CtrlType " + type_id)
		container.add_child(node)

# ---- DATEIEN SAMMELN ----
func get_all_gfx_files_recursively(current_dir: String, relative_path: String) -> Array:
	var result = []
	var d = DirAccess.open(current_dir)
	if not d: return result
	d.list_dir_begin()
	var item = d.get_next()
	while item != "":
		if not item in [".", ".."]:
			if d.current_is_dir(): result.append_array(get_all_gfx_files_recursively(current_dir+"/"+item, relative_path+item+"/"))
			elif item.get_extension().to_lower() == "gfx": result.append(relative_path+item)
		item = d.get_next()
	return result

func _parse_full_gfx_file_chunked(file_path: String) -> Dictionary:
	var result = {"header": {}, "elements": []}
	if not _decoder().file_exists(file_path): return result

	# Spieldaten sind GBK, eigene .gfx in GFX_Load oft UTF-8 (angelica_files.gd erkennt beides)
	var lines = []
	for raw_line in _decoder().read_lines(file_path):
		var line = raw_line.strip_edges()
		if not line.is_empty(): lines.append(line)
		
	var header_lines = []
	var elements_chunks = []
	var current_chunk = null
	
	for line in lines:
		if line.begins_with("GFXELEMENTID:"):
			current_chunk = []
			elements_chunks.append(current_chunk)
			current_chunk.append(line)
		else:
			if current_chunk != null: current_chunk.append(line)
			else: header_lines.append(line)
			
	var h_tracker = {}
	for line in header_lines:
		_parse_single_line(line, result["header"], h_tracker)
		
	for chunk in elements_chunks:
		result["elements"].append(_parse_element_chunk(chunk))
		
	return result

func _parse_element_chunk(lines: Array) -> Dictionary:
	var dict = {"_system_id": "", "_affectors": [], "_ctrl_methods": [], "_keypoints": [], "_ps_consts": []}
	var key_tracker = {}
	var i = 0
	
	while i < lines.size():
		var line = lines[i]
		
		# --- 1. ELEMENT ID KOPFDATEN ---
		if line.begins_with("GFXELEMENTID:"):
			var after_colon = line.split(":", true, 1)[1].strip_edges()
			var pure_number = ""
			for char in after_colon:
				if char >= "0" and char <= "9": pure_number += char
				else: break
			dict["_system_id"] = pure_number
			_parse_single_line(line, dict, key_tracker)
			i += 1
			continue
			
		# --- 2. PIXEL SHADER ARRAYS ---
		if line.begins_with("PSConstCount:"):
			_parse_single_line(line, dict, key_tracker)
			var ps_count = int(line.split(":", true, 1)[1].strip_edges())
			i += 1
			var ps_array = []
			for p in range(ps_count):
				if i >= lines.size(): break
				var ps_block = {"_targets": []}
				if i < lines.size() and lines[i].begins_with("PSConstIndex:"):
					ps_block["PSConstIndex"] = lines[i].split(":", true, 1)[1].strip_edges()
					i += 1
				if i < lines.size() and lines[i].begins_with("PSConstValue:"):
					ps_block["PSConstValue"] = lines[i].split(":", true, 1)[1].strip_edges()
					i += 1
				if i < lines.size() and lines[i].begins_with("PSLoopCount:"):
					ps_block["PSLoopCount"] = lines[i].split(":", true, 1)[1].strip_edges()
					i += 1
				if i < lines.size() and lines[i].begins_with("PSTargetCount:"):
					var t_count_str = lines[i].split(":", true, 1)[1].strip_edges()
					ps_block["PSTargetCount"] = t_count_str
					i += 1
					var target_count = int(t_count_str)
					for t in range(target_count):
						if i >= lines.size(): break
						var target_data = {}
						if i < lines.size() and lines[i].begins_with("PSInterval:"):
							target_data["PSInterval"] = lines[i].split(":", true, 1)[1].strip_edges()
							i += 1
						if i < lines.size() and lines[i].begins_with("PSConstValue:"):
							target_data["PSConstValue"] = lines[i].split(":", true, 1)[1].strip_edges()
							i += 1
						ps_block["_targets"].append(target_data)
				ps_array.append(ps_block)
			dict["_ps_consts"] = ps_array
			continue
			
		# --- 3. AFFECTORS ---
		if line.begins_with("AffectorCount:"):
			_parse_single_line(line, dict, key_tracker)
			var count = int(line.split(":", true, 1)[1].strip_edges())
			i += 1
			if count > 0:
				var current_ctrl = {}
				var ctrl_tracker = {}
				while i < lines.size():
					var sub_line = lines[i]
					# SCHRANKE: Bricht ab, wenn Fallback-Methoden oder der globale KeypointBlock startet:
					var is_kp_start = (sub_line.begins_with("StartTime:") and i+1 < lines.size() and lines[i+1].begins_with("KEYPOINTCOUNT:"))
					if sub_line.begins_with("CtrlMethodCount:") or is_kp_start:
						break
						
					if sub_line.begins_with("CtrlType:"):
						if not current_ctrl.is_empty(): dict["_affectors"].append(current_ctrl)
						current_ctrl = {}
						ctrl_tracker = {}
						_parse_single_line(sub_line, current_ctrl, ctrl_tracker)
					elif not current_ctrl.is_empty():
						_parse_single_line(sub_line, current_ctrl, ctrl_tracker)
					i += 1
				if not current_ctrl.is_empty(): dict["_affectors"].append(current_ctrl)
			continue
			
		# --- 4. KEYPOINTS (beinhaltet die eigenen CtrlMethods!) ---
		if line.begins_with("KEYPOINTCOUNT:"):
			_parse_single_line(line, dict, key_tracker)
			var kp_count = int(line.split(":", true, 1)[1].strip_edges())
			i += 1
			var kp_array = []
			for k in range(kp_count):
				if i >= lines.size(): break
				var kp_block = {"_ctrl_methods": []}
				var kp_tracker = {}
				
				while i < lines.size():
					var kp_line = lines[i]
					if kp_line.begins_with("CtrlMethodCount:"):
						kp_block["CtrlMethodCount"] = kp_line.split(":", true, 1)[1].strip_edges()
						i += 1
						var cm_count = int(kp_block["CtrlMethodCount"])
						if cm_count > 0:
							var current_ctrl = {}
							var ctrl_tracker = {}
							while i < lines.size():
								var cm_line = lines[i]
								# SCHRANKE: Bricht in der Methode NUR ab, wenn der nächste Keypoint anfängt!
								if cm_line.begins_with("InterpolateMode:"):
									break
									
								if cm_line.begins_with("CtrlType:"):
									if not current_ctrl.is_empty():
										kp_block["_ctrl_methods"].append(current_ctrl)
										dict["_ctrl_methods"].append(current_ctrl)
									current_ctrl = {}
									ctrl_tracker = {}
									_parse_single_line(cm_line, current_ctrl, ctrl_tracker)
								elif not current_ctrl.is_empty():
									_parse_single_line(cm_line, current_ctrl, ctrl_tracker)
								i += 1
							if not current_ctrl.is_empty():
								kp_block["_ctrl_methods"].append(current_ctrl)
								dict["_ctrl_methods"].append(current_ctrl)
						break # Das war das Ende DIESES Keypoints. Springe zum nächsten 'k'.
					else:
						_parse_single_line(kp_line, kp_block, kp_tracker)
						i += 1
				if not kp_block.is_empty():
					kp_array.append(kp_block)
			dict["_keypoints"] = kp_array
			continue

		# --- 5. STANDALONE CONTROL METHODS (Fallback für Elemente ohne Keypoints!) ---
		if line.begins_with("CtrlMethodCount:"):
			_parse_single_line(line, dict, key_tracker)
			var count = int(line.split(":", true, 1)[1].strip_edges())
			i += 1
			if count > 0:
				var current_ctrl = {}
				var ctrl_tracker = {}
				while i < lines.size():
					var sub_line = lines[i]
					# SCHRANKE: Bricht ab, wenn versehentlich danach noch Affectors oder Keypoints kommen!
					var is_kp_start = (sub_line.begins_with("StartTime:") and i+1 < lines.size() and lines[i+1].begins_with("KEYPOINTCOUNT:"))
					if sub_line.begins_with("AffectorCount:") or is_kp_start:
						break
						
					if sub_line.begins_with("CtrlType:"):
						if not current_ctrl.is_empty(): dict["_ctrl_methods"].append(current_ctrl)
						current_ctrl = {}
						ctrl_tracker = {}
						_parse_single_line(sub_line, current_ctrl, ctrl_tracker)
					elif not current_ctrl.is_empty():
						_parse_single_line(sub_line, current_ctrl, ctrl_tracker)
					i += 1
				if not current_ctrl.is_empty(): dict["_ctrl_methods"].append(current_ctrl)
			continue
		# --- 5.5 GRID ANIMATION LINES (Base64 Blöcke für 210/211) ---
		if line.begins_with("GridAnimationLines:"):
			var anim_count = int(line.split(":", true, 1)[1].strip_edges())
			i += 1
			
			# Wenn das Array noch nicht existiert, erstellen wir es
			if not dict.has("_grid_animations"):
				dict["_grid_animations"] = []
				
			# Wir lesen genau so viele Zeilen ein, wie 'anim_count' verlangt
			for a in range(anim_count):
				if i < lines.size():
					dict["_grid_animations"].append(lines[i])
					i += 1
			continue

		
		# --- 6. STANDARD PARAMETER (Der Rest) ---
		_parse_single_line(line, dict, key_tracker)
		i += 1
		
	return dict

func _parse_single_line(line: String, dict: Dictionary, tracker: Dictionary):
	var split = line.split(":", true, 1)
	if split.size() >= 2:
		var key = split[0].strip_edges()
		var val = split[1].strip_edges()
		if tracker.has(key):
			tracker[key] += 1
			dict[key + "_" + str(tracker[key])] = val
		else:
			tracker[key] = 1
			if key in ["Vec", "TexSpeed", "NoScale", "OrgPt"]: dict[key + "_1"] = val
			else: dict[key] = val
	else:
		var key = "GridVector"
		if tracker.has(key):
			tracker[key] += 1
			dict[key + "_" + str(tracker[key])] = line
		else:
			tracker[key] = 1
			dict[key + "_1"] = line
