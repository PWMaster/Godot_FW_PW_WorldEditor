@tool
extends Object

# ====================================================
# GFXELEMENTID 120 = ID_ELE_TYPE_PARTICLE_POINT
# (A3DParticleSystemEx + A3DPointEmitter aus Angelica_source)
# ====================================================
# Angelica simuliert jedes Partikel auf der CPU (m_LstAct / m_LstFree).
# Hier wird das System ZUSTANDSLOS im Vertex-Shader nachgebaut:
#  - Ein ArrayMesh enthält Pool_Size Quads (1 Quad = 1 Partikel-Slot, UV2.x = Slot-Index).
#  - Emission i startet bei t = (i + 1) / EmissionRate (GenEmissionCount) und
#    belegt Slot i % Pool_Size (FIFO wie m_LstFree -> m_LstAct).
#  - Quota begrenzt die GESAMTZAHL der Emissionen pro Loop (m_nEmissionCount).
#  - Affectors bekommen in Angelica das Partikel-ALTER als Zeit (ProcData.m_fTimeSpan = p->m_fTTL)
#    und werden deshalb analytisch über das Alter ausgewertet.
#  - IsBind: Partikel leben im Emitter-Space und folgen dem Emitter.
#    Sonst bleiben sie dort, wo der Emitter zur Emissionszeit war.
#
# Basis für 121–125: Diese erben per extends "create_id_120.gd" und überschreiben
# nur die EMITTER-HOOKS (_element_id, _gen_emitter_* usw., siehe unten).
#
# DummyEle: nennt es ein Element derselben GFX mit IsDummy (A3DGFXElement::SetDummyEle), zeichnet
# Angelica an jedem Partikel eine Kopie davon statt eines Quads (A3DParticleSystemEx::Render ->
# Render_Dummy). Dann bleiben die Quads weg (Mesh leer, Material bleibt für Zeit und Werte), und
# ein Kind "Dummy_Particles" (gfx_dummy_particles.gd) führt die Kopien: es rechnet die Partikel
# mit gfx_particle_eval.gd auf der CPU wie dieser Shader; den Aufbau dafür liefert cpu_info.
# ====================================================

const MESH_NODE_NAME = "Particles_GFX"
const DUMMY_NODE_NAME = "Dummy_Particles"
const DUMMY_DRIVER_SCRIPT = "gfx_dummy_particles.gd"
const MAX_QUOTA = 750 # _max_quota in A3DParticleSystemEx.cpp
# GLSL-Bezeichner dürfen nicht mit einer Ziffer beginnen
const UNIFORM_RENAMES = {"3DParticle": "Particle3D"}
# Affectors mit m_bHasAxis = true (RotAxis, Revol, CentriMove)
const AXIS_CTRL_TYPES = ["102", "103", "104"]
const EMITTER_CTRL_TYPES = ["100", "101", "104", "105", "106", "107", "108", "109", "110", "111"]
const AFFECTOR_CTRL_TYPES = ["100", "101", "102", "103", "104", "105", "106", "107", "108", "109", "110", "111"]

var _cpu_info = {} # cpu_info() des zuletzt gebauten Shaders

func execute(root_node: Node):
	var target_nodes = _find_target_nodes(root_node)

	if target_nodes.is_empty():
		push_warning("Keine Nodes mit der ID " + _element_id() + " gefunden!")
		return

	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Create Particles for ID_" + _element_id())

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
			_create_particles_with_shader(node, root_node, undo_redo, max_group_time)

	undo_redo.commit_action()
	print("Partikel-Meshes und Shader-Materialien für ", target_nodes.size(), " ID_", _element_id(), "-Nodes erstellt.")


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
		if child.name == MESH_NODE_NAME:
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
		if constants.has("KNOWN_PARAMS"): return constants["KNOWN_PARAMS"]
		if constants.has("PARAMS"): return constants["PARAMS"]
	return {}

func _create_particles_with_shader(parent_node: Node3D, root_node: Node, undo_redo: EditorUndoRedoManager, max_group_time: float):
	if parent_node.has_node(MESH_NODE_NAME):
		return

	var mesh_instance = build_particle_node(parent_node, max_group_time)
	if mesh_instance == null:
		return

	undo_redo.add_do_method(parent_node, "add_child", mesh_instance)
	undo_redo.add_do_property(mesh_instance, "owner", root_node)
	for child in mesh_instance.get_children():
		undo_redo.add_do_property(child, "owner", root_node)
	undo_redo.add_undo_method(parent_node, "remove_child", mesh_instance)
	undo_redo.add_do_reference(mesh_instance)


# ====================================================
# BAUT MESH + SHADER-MATERIAL (ohne Szene / UndoRedo -> auch für Tests nutzbar)
# ====================================================
func build_particle_node(parent_node: Node, max_group_time: float) -> MeshInstance3D:
	var parsed_data = parent_node.get("parsed_data")
	var param_types = parent_node.get("PARAM_TYPES")

	if typeof(parsed_data) != TYPE_DICTIONARY or typeof(param_types) != TYPE_DICTIONARY:
		return null

	var pool_size = _calc_pool_size(parsed_data)

	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = MESH_NODE_NAME
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.extra_cull_margin = 1000.0
	var dummy = _dummy_element(parent_node, parsed_data)
	if dummy == "":
		mesh_instance.mesh = _build_particle_quads(pool_size)

	var uniform_assignments = {}
	var shader = Shader.new()
	shader.code = preload("gfx_parser.gd").add_gfx_alpha(_build_shader_code(parent_node, parsed_data, param_types, max_group_time, pool_size, uniform_assignments))

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

	var priority_val = int(parsed_data.get("Priority", 0))
	mat.render_priority = clampi(priority_val, Material.RENDER_PRIORITY_MIN, Material.RENDER_PRIORITY_MAX)
	mesh_instance.material_override = mat
	if dummy != "":
		# Träger: statt der Quads die Dummy-Kopien an den Partikeln
		var driver = Node3D.new()
		driver.name = DUMMY_NODE_NAME
		driver.set_script(load(get_script().resource_path.get_base_dir().path_join(DUMMY_DRIVER_SCRIPT)))
		driver.info = _cpu_info
		driver.Dummy_Element = dummy
		mesh_instance.add_child(driver)
	return mesh_instance


# Name des Dummy-Elements (DummyEle), wenn es in derselben GFX steht und IsDummy hat, sonst ""
func _dummy_element(parent_node: Node, parsed_data: Dictionary) -> String:
	var dummy_name = str(parsed_data.get("DummyEle", "")).strip_edges()
	var header = parent_node.get_parent()
	if dummy_name == "" or header == null:
		return ""
	for sibling in header.get_children():
		var data = sibling.get("parsed_data")
		if sibling != parent_node and typeof(data) == TYPE_DICTIONARY and str(data.get("Name", "")).strip_edges() == dummy_name:
			return dummy_name if _as_bool(data.get("IsDummy", "0")) else ""
	return ""

# A3DParticleSystemEx::Play -> SetPoolSize
func _calc_pool_size(parsed_data: Dictionary) -> int:
	var rate = float(parsed_data.get("EmissionRate", 0.0))
	var ttl = float(parsed_data.get("TTL", 0.0))
	var quota = int(parsed_data.get("Quota", -1))

	var pool = int(ttl * rate) + 1
	if quota != -1 and pool > quota:
		pool = quota
	return clampi(pool, 0, MAX_QUOTA)


# Ein Quad pro Partikel-Slot. VERTEX.xy = Ecke (-1..1), UV2.x = Slot-Index
func _build_particle_quads(count: int) -> ArrayMesh:
	var verts = PackedVector3Array()
	var uvs = PackedVector2Array()
	var uv2s = PackedVector2Array()
	var indices = PackedInt32Array()
	var corners = [Vector2(-1, 1), Vector2(1, 1), Vector2(-1, -1), Vector2(1, -1)]

	for i in range(max(count, 1)):
		var base = verts.size()
		for c in corners:
			verts.append(Vector3(c.x, c.y, 0.0))
			uvs.append(Vector2(0.5 + 0.5 * c.x, 0.5 - 0.5 * c.y))
			uv2s.append(Vector2(float(i), 0.0))
		indices.append_array([base, base + 1, base + 2, base + 2, base + 1, base + 3])

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_shader_code(parent_node: Node, parsed_data: Dictionary, param_types: Dictionary, max_group_time: float, pool_size: int, uniform_assignments: Dictionary) -> String:
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

	# Jedes Element hat eine "Warp:"-Zeile -> wir werten den WERT aus, nicht nur die Existenz
	var has_warp = _as_bool(parsed_data.get("Warp", "0"))
	if has_warp:
		render_blend_mode = "blend_mix"

	# ZEnable des Elements und 2DRender der GFX
	var z_enable = preload("gfx_parser.gd").z_test_enabled(parent_node, parsed_data)
	var tile_mode = _as_bool(parsed_data.get("TileMode", "0"))

	var shader_code = "shader_type spatial;\n"
	shader_code += "render_mode " + render_blend_mode + ", depth_draw_opaque, cull_disabled, unshaded, skip_vertex_transform"
	if not z_enable:
		shader_code += ", depth_test_disabled"
	shader_code += ";\n\n"

	if has_warp:
		shader_code += "uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;\n"

	shader_code += "varying float v_current_time;\n"
	shader_code += "varying vec4 v_color;\n"
	shader_code += "varying vec2 v_uv;\n"
	shader_code += "varying float v_alive;\n\n"

	# ====================================================
	# VORBEREITUNG: Affectors und CtrlMethods trennen
	# ====================================================
	var all_ctrl_nodes = _gather_ctrl_nodes(parent_node)
	var ctrl_methods = []
	var affectors = []

	for child in all_ctrl_nodes:
		if child.name.findn("Affector") != -1:
			affectors.append(child)
		else:
			ctrl_methods.append(child)

	# Manche Emitter (125) bringen eigene CtrlMethods mit, die VOR den KeyPoint-CtrlMethods stehen
	var owned_count = clampi(_emitter_owned_ctrl_count(parsed_data), 0, ctrl_methods.size())
	var emitter_ctrls = ctrl_methods.slice(0, owned_count)
	ctrl_methods = ctrl_methods.slice(owned_count)

	# ====================================================
	# ZEITEINSTELLUNGEN
	# ====================================================
	var start_time = 0.0
	if parsed_data.has("StartTime"):
		start_time = float(parsed_data["StartTime"])

	var local_total_time = start_time
	var is_endless = false

	if parsed_data.has("_keypoints"):
		for kp_block in parsed_data["_keypoints"]:
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
	# HAUPT-PARAMETER (inkl. Emitter- & Partikel-Parameter)
	# ====================================================
	shader_code += "group_uniforms Main_Parameters;\n"
	for key in parsed_data.keys():
		if key.begins_with("_"): continue

		var godot_type = param_types.get(key, TYPE_STRING)

		if godot_type == TYPE_STRING:
			if key in ["TexFile", "ShaderTex"]:
				var hint = " : repeat_enable" if (key == "TexFile" and tile_mode) else ""
				shader_code += _declare(declared, "sampler2D", key, hint)

				var tex_path_raw = str(parsed_data[key])
				if tex_path_raw != "":
					# Textur aus den Spieldaten (gfx_sources.gd)
					var loaded_tex = preload("gfx_sources.gd").texture(tex_path_raw)
					if loaded_tex != null:
						uniform_assignments[key] = loaded_tex
			else:
				shader_code += "// String: " + key + " = " + str(parsed_data[key]).replace("\\", "/") + "\n"
		else:
			var glsl_type = _godot_type_to_glsl(godot_type)
			if glsl_type != "":
				var uniform_name = UNIFORM_RENAMES.get(key, key)
				shader_code += _declare(declared, glsl_type, uniform_name)
				uniform_assignments[uniform_name] = parent_node.get(key)

	if not declared.has("TexFile"):
		shader_code += _declare(declared, "sampler2D", "TexFile", " : hint_default_white")
	shader_code += "group_uniforms;\n\n"

	# ====================================================
	# KEYPOINTS UND EINGEBETTETE CTRL METHODS (bewegen den Emitter)
	# ====================================================
	var global_ctrl_idx = 0
	if parsed_data.has("_keypoints"):
		var kp_array = parsed_data["_keypoints"]
		for k in range(kp_array.size()):
			shader_code += "group_uniforms KeyPoint_" + str(k) + ";\n"
			var kp_block = kp_array[k]

			for kp_key in kp_block.keys():
				if kp_key.begins_with("_"): continue

				var glsl_type = _godot_type_to_glsl(param_types.get(kp_key, TYPE_STRING))
				var uniform_name = "KP_" + str(k) + "_" + kp_key

				if glsl_type != "":
					shader_code += _declare(declared, glsl_type, uniform_name)
					uniform_assignments[uniform_name] = parent_node.get("KeyPoint " + str(k) + "/" + kp_key)

			shader_code += "group_uniforms;\n\n"

			var ctrl_count = int(kp_block.get("CtrlMethodCount", 0))
			for i in range(ctrl_count):
				if global_ctrl_idx < ctrl_methods.size():
					var child = ctrl_methods[global_ctrl_idx]
					var group_name = "_" + str(global_ctrl_idx) + "_Ctrl_Methode_" + str(child.get("CtrlType"))
					shader_code += _declare_ctrl_uniforms(child, "CtrlMethod_" + str(global_ctrl_idx) + "_", group_name, declared, uniform_assignments)
					global_ctrl_idx += 1

	# Übrige CtrlMethods
	while global_ctrl_idx < ctrl_methods.size():
		var child = ctrl_methods[global_ctrl_idx]
		var group_name = "_" + str(global_ctrl_idx) + "_Ctrl_Methode_" + str(child.get("CtrlType"))
		shader_code += _declare_ctrl_uniforms(child, "CtrlMethod_" + str(global_ctrl_idx) + "_", group_name, declared, uniform_assignments)
		global_ctrl_idx += 1

	# ====================================================
	# PS CONST BLOCKS (nur als Parameter, wie bei ID_100)
	# ====================================================
	if parsed_data.has("_ps_consts"):
		var ps_array = parsed_data["_ps_consts"]
		for p in range(ps_array.size()):
			shader_code += "group_uniforms PS_Const_Block_" + str(p) + ";\n"
			var ps_block = ps_array[p]

			for ps_key in ps_block.keys():
				if ps_key.begins_with("_"): continue
				var glsl_type = _godot_type_to_glsl(param_types.get(ps_key, TYPE_STRING))
				var uniform_name = "PS_" + str(p) + "_" + ps_key
				if glsl_type != "":
					shader_code += _declare(declared, glsl_type, uniform_name)
					uniform_assignments[uniform_name] = parent_node.get("PS Const Block " + str(p) + "/" + ps_key)

			if ps_block.has("_targets"):
				var targets = ps_block["_targets"]
				for t in range(targets.size()):
					for t_key in targets[t].keys():
						if t_key.begins_with("_"): continue
						var glsl_type = _godot_type_to_glsl(param_types.get(t_key, TYPE_STRING))
						var uniform_name = "PS_" + str(p) + "_Target_" + str(t) + "_" + t_key
						if glsl_type != "":
							shader_code += _declare(declared, glsl_type, uniform_name)
							uniform_assignments[uniform_name] = parent_node.get("PS Const Block " + str(p) + "/Target " + str(t) + "/" + t_key)
			shader_code += "group_uniforms;\n\n"

	# ====================================================
	# AFFECTORS (wirken auf jedes einzelne Partikel)
	# ====================================================
	for i in range(affectors.size()):
		var child = affectors[i]
		var group_name = "_" + str(i) + "_Affector_" + str(child.get("CtrlType"))
		shader_code += _declare_ctrl_uniforms(child, "Affector_" + str(i) + "_", group_name, declared, uniform_assignments)

	# ====================================================
	# PARTIKEL-POOL
	# ====================================================
	shader_code += "group_uniforms Particle_Pool;\n"
	shader_code += "uniform int Pool_Size = " + str(pool_size) + ";\n"
	shader_code += "uniform int Random_Seed = " + str(hash(str(parent_node.name)) & 0xFFFF) + ";\n"
	declared["Pool_Size"] = true
	declared["Random_Seed"] = true

	# ParIniDir (Euler in Rad) -> m_qParticleDir = m_qParentDir * A3DQUATERNION(ParIniDir)
	var par_ini_q = Quaternion.IDENTITY
	if parsed_data.has("ParIniDir"):
		var v = parent_node.get("ParIniDir")
		if typeof(v) == TYPE_VECTOR3:
			par_ini_q = Quaternion.from_euler(v)
	shader_code += "uniform vec4 ParIniDir_Quat = vec4(" + _f(par_ini_q.x) + ", " + _f(par_ini_q.y) + ", " + _f(par_ini_q.z) + ", " + _f(par_ini_q.w) + ");\n"
	declared["ParIniDir_Quat"] = true
	shader_code += "uniform bool Emitter_Enabled = " + ("true" if _emitter_can_emit(parsed_data, emitter_ctrls) else "false") + ";\n"
	declared["Emitter_Enabled"] = true
	shader_code += "group_uniforms;\n\n"

	# Emitter-spezifische Uniforms (Hook)
	shader_code += _gen_emitter_uniforms(parent_node, parsed_data, declared, uniform_assignments, emitter_ctrls)

	# ====================================================
	# KEYPOINT-ZEITEN FÜR CTRLMETHODS VORBERECHNEN
	# ====================================================
	var ctrl_to_kp_basetime = {}
	var ctrl_to_kp_duration = {}
	var current_kp_time = 0.0
	var temp_ctrl_idx = 0

	if parsed_data.has("_keypoints"):
		for kp_block in parsed_data["_keypoints"]:
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

	# ====================================================
	# TYPE 110 POSITIONS-ARRAYS (CtrlMethods & Affectors)
	# ====================================================
	var path_counts = {}
	for i in range(ctrl_methods.size()):
		shader_code += _declare_path_array(ctrl_methods[i], "CtrlMethod_" + str(i) + "_", declared, uniform_assignments, path_counts)
	for i in range(affectors.size()):
		shader_code += _declare_path_array(affectors[i], "Affector_" + str(i) + "_", declared, uniform_assignments, path_counts)

	# ====================================================
	# HILFSFUNKTIONEN
	# ====================================================
	shader_code += "\n// --- ZUFALL (deterministisch pro Emission) ---\n"
	shader_code += "float rnd(float idx, float k) {\n"
	shader_code += "\tuint h = uint(idx) * 747796405u + uint(k) * 2891336453u + uint(Random_Seed) * 277803737u;\n"
	shader_code += "\th ^= h >> 16u; h *= 2246822519u; h ^= h >> 13u; h *= 3266489917u; h ^= h >> 16u;\n"
	shader_code += "\treturn float(h) / 4294967295.0;\n"
	shader_code += "}\n\n"

	shader_code += "// --- QUATERNIONEN (A3DQUATERNION a * b == quat_mul(a, b)) ---\n"
	shader_code += "vec4 quat_mul(vec4 a, vec4 b) {\n"
	shader_code += "\treturn vec4(a.w * b.xyz + b.w * a.xyz + cross(a.xyz, b.xyz), a.w * b.w - dot(a.xyz, b.xyz));\n"
	shader_code += "}\n"
	shader_code += "vec4 quat_axis(vec3 axis, float angle) {\n"
	shader_code += "\tfloat len = length(axis);\n"
	shader_code += "\tif (len < 0.000001) return vec4(0.0, 0.0, 0.0, 1.0);\n"
	shader_code += "\treturn vec4(axis / len * sin(angle * 0.5), cos(angle * 0.5));\n"
	shader_code += "}\n"
	shader_code += "vec3 quat_rot(vec4 q, vec3 v) {\n"
	shader_code += "\treturn v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);\n"
	shader_code += "}\n\n"

	shader_code += "// _SymmetricRandom(): -1..1\n"
	shader_code += "float srnd(float idx, float k) {\n"
	shader_code += "\treturn rnd(idx, k) * 2.0 - 1.0;\n"
	shader_code += "}\n\n"

	shader_code += "// A3DParticleEmitter::GenDirection: +Z, zufällig um bis zu angle gekippt\n"
	shader_code += "vec3 gen_direction(float e_idx, bool is_bind, vec4 parent_rot, float angle) {\n"
	shader_code += "\tvec3 d = vec3(0.0, 0.0, 1.0);\n"
	shader_code += "\tif (angle != 0.0) {\n"
	shader_code += "\t\tfloat az = rnd(e_idx, 1.0) * TAU;\n"
	shader_code += "\t\td = quat_rot(quat_axis(vec3(cos(az), sin(az), 0.0), rnd(e_idx, 2.0) * angle), d);\n"
	shader_code += "\t}\n"
	shader_code += "\treturn is_bind ? d : quat_rot(parent_rot, d);\n"
	shader_code += "}\n\n"

	var has_noise = false
	for child in ctrl_methods + affectors:
		var ct = str(child.get("CtrlType"))
		if ct == "107" or ct == "109":
			has_noise = true
			break

	if has_noise:
		shader_code += "// --- NOISE FUNKTIONEN FÜR CTRL 107 & 109 ---\n"
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

	var has_hsv = parsed_data.has("IsUseHSVInterp")
	if has_hsv:
		shader_code += "// --- HSV (A3DParticleEmitter::GenColor mit IsUseHSVInterp) ---\n"
		shader_code += "vec3 rgb2hsv(vec3 c) {\n"
		shader_code += "\tvec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);\n"
		shader_code += "\tvec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));\n"
		shader_code += "\tvec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));\n"
		shader_code += "\tfloat d = q.x - min(q.w, q.y);\n"
		shader_code += "\treturn vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 1.0e-10)), d / (q.x + 1.0e-10), q.x);\n"
		shader_code += "}\n"
		shader_code += "vec3 hsv2rgb(vec3 c) {\n"
		shader_code += "\tvec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);\n"
		shader_code += "\treturn c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);\n"
		shader_code += "}\n\n"

	# Emitter-spezifische Funktionen (Hook)
	shader_code += _gen_emitter_functions(declared)

	# ====================================================
	# EMITTER-ZUSTAND (KeyPoint 0 + CtrlMethods) ZU EINER BELIEBIGEN ZEIT
	# ====================================================
	shader_code += _gen_emitter_state(parsed_data, ctrl_methods, ctrl_to_kp_basetime, ctrl_to_kp_duration, declared, path_counts)

	# ====================================================
	# PARTIKEL-AUSWERTUNG (Emitter + Bewegung + Affectors)
	# ====================================================
	shader_code += _gen_eval_particle(affectors, declared, path_counts, has_hsv)

	# ====================================================
	# VERTEX SHADER
	# ====================================================
	var b_start = _u(declared, "StartTime", "LocalStartTime")
	var b_repeat = "float(" + _u(declared, "RepeatCount", "1") + ")"
	var b_delay = "float(" + _u(declared, "RepeatDelay", "0") + ")"

	shader_code += "void vertex() {\n"
	shader_code += "\t// --- ZEIT-SYNCHRONISATION (identisch zu ID_100) ---\n"
	shader_code += "\tfloat active_time = Time_Manual ? Time : (TIME * 1000.0);\n"
	shader_code += "\tv_current_time = 0.0;\n\n"
	shader_code += "\tfloat f_repeat = " + b_repeat + ";\n"
	shader_code += "\tfloat f_delay = " + b_delay + ";\n\n"
	shader_code += "\tfloat loop_active_duration = max(0.001, LocalTotalTime - " + b_start + ");\n"
	shader_code += "\tfloat loop_full_duration = loop_active_duration + max(0.0, f_delay);\n\n"
	shader_code += "\tif (LocalTotalTime <= 0.0) {\n"
	shader_code += "\t\tv_current_time = active_time;\n"
	shader_code += "\t} else {\n"
	shader_code += "\t\tfloat t_global = active_time;\n"
	shader_code += "\t\tif (f_repeat >= 0.0) {\n"
	shader_code += "\t\t\tt_global = mod(active_time, max(0.001, GlobalLoopTime));\n"
	shader_code += "\t\t}\n"
	shader_code += "\t\tfloat t_since_start = t_global - " + b_start + ";\n\n"
	shader_code += "\t\tif (t_since_start < 0.0) {\n"
	shader_code += "\t\t\tv_current_time = t_global;\n"
	shader_code += "\t\t} else {\n"
	shader_code += "\t\t\tfloat current_loop = floor(t_since_start / loop_full_duration);\n"
	shader_code += "\t\t\tif (f_repeat >= 0.0 && current_loop >= f_repeat) {\n"
	shader_code += "\t\t\t\tv_current_time = t_global;\n"
	shader_code += "\t\t\t} else {\n"
	shader_code += "\t\t\t\tfloat t_in_loop = mod(t_since_start, loop_full_duration);\n"
	shader_code += "\t\t\t\tv_current_time = " + b_start + " + t_in_loop;\n"
	shader_code += "\t\t\t}\n"
	shader_code += "\t\t}\n"
	shader_code += "\t}\n\n"

	shader_code += "\t// Sekunden seit Element-Start (= Emitter-Zeit)\n"
	shader_code += "\tfloat t_now = max(0.0, (v_current_time - LocalStartTime) * 0.001);\n"
	shader_code += "\tbool elem_active = Is_Endless || (v_current_time >= LocalStartTime && v_current_time <= LocalTotalTime);\n\n"

	shader_code += "\tvec2 corner = VERTEX.xy;\n"
	shader_code += "\tfloat slot = UV2.x;\n"
	shader_code += "\tvec3 view_pos = vec3(0.0);\n"
	shader_code += "\tv_alive = 0.0;\n"
	shader_code += "\tv_color = vec4(0.0);\n"
	shader_code += "\tv_uv = UV;\n\n"

	var u_rate = _u(declared, "EmissionRate", "0.0")
	var u_ttl = _u(declared, "TTL", "0.0")
	var u_quota = _u(declared, "Quota", "-1")
	var u_pw = _u(declared, "ParticleWidth", "1.0")
	var u_ph = _u(declared, "ParticleHeight", "1.0")
	var u_noscale1 = _u(declared, "NoScale_1", "false")
	var u_noscale2 = _u(declared, "NoScale_2", "false")
	var u_org1 = _u(declared, "OrgPt_1", "0.5")
	var u_org2 = _u(declared, "OrgPt_2", "0.5")
	var u_3d = _u(declared, "Particle3D", "false")
	var u_facing = _u(declared, "Facing", "false")

	shader_code += "\t// --- EMISSION -> SLOT ZUORDNUNG (GenEmissionCount + Quota + FIFO-Pool) ---\n"
	shader_code += "\tfloat rate = " + u_rate + ";\n"
	shader_code += "\tfloat ttl = " + u_ttl + ";\n"
	shader_code += "\tif (Emitter_Enabled && elem_active && Pool_Size > 0 && rate > 0.0 && ttl > 0.0) {\n"
	shader_code += "\t\tfloat pool = float(Pool_Size);\n"
	shader_code += "\t\tfloat emitted = floor(t_now * rate + 0.0001);\n"
	shader_code += "\t\tif (" + u_quota + " > 0) emitted = min(emitted, float(" + u_quota + "));\n"
	shader_code += "\t\tfloat e_last = emitted - 1.0;\n"
	shader_code += "\t\tif (e_last >= slot) {\n"
	shader_code += "\t\t\t// Jüngste Emission, die in diesem Slot liegt\n"
	shader_code += "\t\t\tfloat e_idx = slot + pool * floor((e_last - slot) / pool);\n"
	shader_code += "\t\t\tfloat t_emit = (e_idx + 1.0) / rate;\n"
	shader_code += "\t\t\tfloat age = t_now - t_emit;\n"
	shader_code += "\t\t\tif (age >= 0.0 && age < ttl) {\n"
	shader_code += "\t\t\t\tvec3 w_pos; vec3 w_move; vec3 w_ax_x; vec3 w_ax_y; float p_size; float p_rad; vec4 p_col; float k_scale; float k_alpha;\n"
	shader_code += "\t\t\t\teval_particle(e_idx, age, t_emit, t_now, w_pos, w_move, w_ax_x, w_ax_y, p_size, p_rad, p_col, k_scale, k_alpha);\n"
	shader_code += "\t\t\t\t// Partikel-Alpha * aktuelles KeyPoint-Alpha (GetCurAlpha), unter 5/255 wird nicht gezeichnet\n"
	shader_code += "\t\t\t\tfloat alpha = p_col.a * k_alpha;\n"
	shader_code += "\t\t\t\tif (alpha * 255.0 >= 5.0) {\n"
	shader_code += "\t\t\t\t\tfloat w_co = 1.0 - 2.0 * " + u_org1 + ";\n"
	shader_code += "\t\t\t\t\tfloat h_co = 1.0 - 2.0 * " + u_org2 + ";\n"
	shader_code += "\t\t\t\t\tvec2 cell_uv = UV;\n"
	shader_code += "\t\t\t\t\tif (!" + u_3d + ") {\n"
	shader_code += "\t\t\t\t\t\t// --- 2D PARTIKEL (Fill_Vert_2D): Kamera-Billboard, Rotation in der Bildebene ---\n"
	shader_code += "\t\t\t\t\t\tfloat fw = " + u_noscale1 + " ? " + u_pw + " : " + u_pw + " * p_size * k_scale;\n"
	shader_code += "\t\t\t\t\t\tfloat fh = " + u_noscale2 + " ? " + u_ph + " : " + u_ph + " * p_size * k_scale;\n"
	shader_code += "\t\t\t\t\t\tvec3 c_view = (MODELVIEW_MATRIX * vec4(w_pos, 1.0)).xyz;\n"
	shader_code += "\t\t\t\t\t\tvec2 off = vec2((corner.x + w_co) * fw, (corner.y - h_co) * fh);\n"
	shader_code += "\t\t\t\t\t\tfloat cs = cos(p_rad); float sn = sin(p_rad);\n"
	shader_code += "\t\t\t\t\t\tview_pos = c_view + vec3(off.x * cs - off.y * sn, off.x * sn + off.y * cs, 0.0);\n"
	if parsed_data.has("ZOffset"):
		shader_code += "\t\t\t\t\t\tview_pos.z += " + _f(float(parsed_data["ZOffset"])) + ";\n"
	shader_code += "\t\t\t\t\t} else if (" + u_facing + ") {\n"
	shader_code += "\t\t\t\t\t\t// --- 3D FACING (Fill_Vert_3D): entlang der Flugrichtung, zur Kamera gedreht ---\n"
	shader_code += "\t\t\t\t\t\tfloat age_prev = max(0.0, age - 0.02);\n"
	shader_code += "\t\t\t\t\t\tvec3 o_pos; vec3 o_move; vec3 o_ax; vec3 o_ay; float o_size; float o_rad; vec4 o_col; float o_scale; float o_alpha;\n"
	shader_code += "\t\t\t\t\t\teval_particle(e_idx, age_prev, t_emit, t_emit + age_prev, o_pos, o_move, o_ax, o_ay, o_size, o_rad, o_col, o_scale, o_alpha);\n"
	shader_code += "\t\t\t\t\t\t// Angelica: vMoveDir = OldPos - Pos\n"
	shader_code += "\t\t\t\t\t\tvec3 md = o_pos - w_pos;\n"
	shader_code += "\t\t\t\t\t\tif (length(md) < 0.000001) md = -w_move;\n"
	shader_code += "\t\t\t\t\t\tfloat fw = (" + u_noscale1 + " ? " + u_pw + " : " + u_pw + " * p_size) * k_scale;\n"
	shader_code += "\t\t\t\t\t\tfloat fh = (" + u_noscale2 + " ? " + u_ph + " : " + u_ph + " * p_size) * k_scale;\n"
	shader_code += "\t\t\t\t\t\tvec3 c_view = (MODELVIEW_MATRIX * vec4(w_pos, 1.0)).xyz;\n"
	shader_code += "\t\t\t\t\t\tvec3 md_view = normalize(mat3(MODELVIEW_MATRIX) * md);\n"
	shader_code += "\t\t\t\t\t\tvec3 up_view = cross(c_view, md_view);\n"
	shader_code += "\t\t\t\t\t\tup_view = length(up_view) > 0.000001 ? normalize(up_view) : vec3(0.0, 1.0, 0.0);\n"
	shader_code += "\t\t\t\t\t\tvec3 ax = md_view * fw;\n"
	shader_code += "\t\t\t\t\t\tvec3 ay = up_view * fh;\n"
	shader_code += "\t\t\t\t\t\tview_pos = c_view + ax * (corner.x + w_co) + ay * (corner.y + h_co);\n"
	shader_code += "\t\t\t\t\t\t// Angelica-Vertexreihenfolge: U läuft entlang -Y, V entlang -X\n"
	shader_code += "\t\t\t\t\t\tcell_uv = vec2(0.5 - 0.5 * corner.y, 0.5 - 0.5 * corner.x);\n"
	shader_code += "\t\t\t\t\t} else {\n"
	shader_code += "\t\t\t\t\t\t// --- 3D PARTIKEL (Fill_Vert_3D): Quad in der Partikel-Ausrichtung ---\n"
	shader_code += "\t\t\t\t\t\tfloat fw = " + u_noscale1 + " ? " + u_pw + " : " + u_pw + " * p_size;\n"
	shader_code += "\t\t\t\t\t\tfloat fh = " + u_noscale2 + " ? " + u_ph + " : " + u_ph + " * p_size;\n"
	shader_code += "\t\t\t\t\t\tvec3 ax = w_ax_x * fw;\n"
	shader_code += "\t\t\t\t\t\tvec3 ay = w_ax_y * fh;\n"
	shader_code += "\t\t\t\t\t\tvec3 center = w_pos + ax * w_co + ay * h_co;\n"
	shader_code += "\t\t\t\t\t\tview_pos = (MODELVIEW_MATRIX * vec4(center + ax * corner.x + ay * corner.y, 1.0)).xyz;\n"
	shader_code += "\t\t\t\t\t\tcell_uv = vec2(0.5 - 0.5 * corner.y, 0.5 - 0.5 * corner.x);\n"
	shader_code += "\t\t\t\t\t}\n\n"

	# ====================================================
	# UV: REVERSE, SPRITESHEET (global / pro Partikel), TILE MODE, UV-TAUSCH
	# ====================================================
	if declared.has("UReverse"): shader_code += "\t\t\t\t\tif (UReverse) cell_uv.x = 1.0 - cell_uv.x;\n"
	if declared.has("VReverse"): shader_code += "\t\t\t\t\tif (VReverse) cell_uv.y = 1.0 - cell_uv.y;\n"

	var u_cols = "float(" + _u(declared, "TexCol", "1") + ")"
	var u_rows = "float(" + _u(declared, "TexRow", "1") + ")"
	var u_interval = "float(" + _u(declared, "TexInterval", "50") + ")"
	var u_par_uv = _u(declared, "IsUseParUV", "false")
	var u_init_rand = _u(declared, "InitRandomTexture", "false")

	shader_code += "\t\t\t\t\tfloat f_cols = max(1.0, " + u_cols + ");\n"
	shader_code += "\t\t\t\t\tfloat f_rows = max(1.0, " + u_rows + ");\n"
	shader_code += "\t\t\t\t\tfloat f_interval = max(1.0, " + u_interval + ");\n"
	shader_code += "\t\t\t\t\tfloat total_frames = f_cols * f_rows;\n"
	shader_code += "\t\t\t\t\tfloat frame = 0.0;\n"
	shader_code += "\t\t\t\t\tif (" + u_par_uv + " || " + u_init_rand + ") {\n"
	shader_code += "\t\t\t\t\t\t// A3DParticle::InitParticleUV / CalcParticlesUV (eigene Animation pro Partikel)\n"
	shader_code += "\t\t\t\t\t\tif (" + u_init_rand + ") frame = min(floor(rnd(e_idx, 9.0) * f_rows), f_rows - 1.0) * f_cols + min(floor(rnd(e_idx, 10.0) * f_cols), f_cols - 1.0);\n"
	shader_code += "\t\t\t\t\t\tif (" + u_par_uv + ") frame = mod(frame + floor(age * 1000.0 / f_interval), total_frames);\n"
	shader_code += "\t\t\t\t\t} else {\n"
	shader_code += "\t\t\t\t\t\tframe = mod(floor(v_current_time / f_interval), total_frames);\n"
	shader_code += "\t\t\t\t\t}\n"
	shader_code += "\t\t\t\t\tvec2 final_uv = (vec2(mod(frame, f_cols), floor(frame / f_cols)) + cell_uv) / vec2(f_cols, f_rows);\n"
	if declared.has("TileMode"):
		var ts1_str = _u(declared, "TexSpeed_1", "0.0")
		var ts2_str = _u(declared, "TexSpeed_2", "0.0")
		shader_code += "\t\t\t\t\tif (TileMode) {\n"
		shader_code += "\t\t\t\t\t\tfinal_uv = cell_uv * vec2(f_cols, f_rows);\n"
		shader_code += "\t\t\t\t\t\tfinal_uv += (v_current_time / 1000.0) * vec2(" + ts1_str + ", " + ts2_str + ");\n"
		shader_code += "\t\t\t\t\t}\n"
	if declared.has("UVExchg"): shader_code += "\t\t\t\t\tif (UVExchg) final_uv = final_uv.yx;\n"
	shader_code += "\t\t\t\t\tv_uv = final_uv;\n"
	shader_code += "\t\t\t\t\tv_color = vec4(p_col.rgb, alpha);\n"
	shader_code += "\t\t\t\t\tv_alive = 1.0;\n"
	shader_code += "\t\t\t\t}\n"
	shader_code += "\t\t\t}\n"
	shader_code += "\t\t}\n"
	shader_code += "\t}\n"
	shader_code += "\t// Tote Slots kollabieren auf einen Punkt (keine Fläche -> kein Fragment)\n"
	shader_code += "\tVERTEX = view_pos;\n"
	shader_code += "}\n\n"

	# ====================================================
	# FRAGMENT SHADER
	# ====================================================
	shader_code += "void fragment() {\n"
	shader_code += "\tif (v_alive < 0.5) {\n"
	shader_code += "\t\tdiscard;\n"
	shader_code += "\t}\n\n"
	shader_code += "\tvec4 tex_color = texture(TexFile, v_uv);\n"

	if has_warp:
		shader_code += "\n\t// --- WARP (HEAT DISTORTION, wie ID_100) ---\n"
		shader_code += "\tvec3 normal_map = tex_color.rgb * 2.0 - 1.0;\n"
		shader_code += "\tnormal_map = normalize(mix(vec3(0.0, 0.0, 1.0), normal_map, tex_color.a));\n"
		shader_code += "\tvec2 warp_dir = normal_map.xy / max(normal_map.z, 0.1);\n"
		shader_code += "\tvec2 offset = warp_dir * 0.50 * v_color.a;\n"
		shader_code += "\tALBEDO = texture(screen_texture, SCREEN_UV + offset).rgb;\n"
		shader_code += "\tALPHA = tex_color.a;\n"
	else:
		shader_code += "\ttex_color *= v_color;\n"
		if render_blend_mode == "blend_mix":
			shader_code += "\t// Alpha leicht dämpfen, damit Mix-Sprites nicht zu massiv wirken (wie ID_100)\n"
			shader_code += "\ttex_color.a *= 0.70;\n"
		shader_code += "\tALBEDO = tex_color.rgb;\n"
		shader_code += "\tALPHA = tex_color.a;\n"
	shader_code += "}\n"

	_cpu_info = cpu_info(parsed_data, ctrl_methods, affectors, ctrl_to_kp_basetime, ctrl_to_kp_duration, declared, has_hsv)
	return shader_code


# Aufbau des Shaders für die CPU-Rechnung (gfx_particle_eval.gd): dieselbe Auswahl der
# CtrlMethods / Affectors wie _gen_emitter_state / _gen_eval_particle samt KeyPoint-Zeiten
func cpu_info(parsed_data: Dictionary, ctrl_methods: Array, affectors: Array, ctrl_to_kp_basetime: Dictionary, ctrl_to_kp_duration: Dictionary, declared: Dictionary, has_hsv: bool) -> Dictionary:
	var kp0 = parsed_data["_keypoints"][0] if parsed_data.has("_keypoints") and parsed_data["_keypoints"].size() > 0 else {}
	var bases_with_path = []
	for i in range(ctrl_methods.size()):
		if str(ctrl_methods[i].get("CtrlType")) == "110":
			bases_with_path.append(ctrl_to_kp_basetime.get(i, 0.0))
	var ctrls = []
	var orbits = []
	for i in range(ctrl_methods.size()):
		var ct = str(ctrl_methods[i].get("CtrlType"))
		var prefix = "CtrlMethod_" + str(i) + "_"
		if not declared.has(prefix + "StartTime"):
			continue
		var entry = {"p": prefix, "t": ct, "base": ctrl_to_kp_basetime.get(i, 0.0), "dur": ctrl_to_kp_duration.get(i, -1.0)}
		if ct in EMITTER_CTRL_TYPES:
			entry["blocked"] = entry["base"] in bases_with_path
			ctrls.append(entry)
		elif ct in ["102", "103"]:
			orbits.append(entry)
	var affs = []
	var axis_prefix = ""
	for i in range(affectors.size()):
		var ct = str(affectors[i].get("CtrlType"))
		var prefix = "Affector_" + str(i) + "_"
		if ct in AXIS_CTRL_TYPES and declared.has(prefix + "Pos"):
			axis_prefix = prefix
		if ct in AFFECTOR_CTRL_TYPES and declared.has(prefix + "StartTime"):
			affs.append({"p": prefix, "t": ct})
	return {"type": _element_id(), "origin_pos": kp0.has("Position") and declared.has("KP_0_Position"),
		"ctrls": ctrls, "orbits": orbits, "affectors": affs, "axis_prefix": axis_prefix, "hsv": has_hsv}


# ====================================================
# EMITTER: KP 0 + CtrlMethods als Funktion der Element-Zeit (Sekunden)
# ====================================================
func _gen_emitter_state(parsed_data: Dictionary, ctrl_methods: Array, ctrl_to_kp_basetime: Dictionary, ctrl_to_kp_duration: Dictionary, declared: Dictionary, path_counts: Dictionary) -> String:
	var kp0 = {}
	if parsed_data.has("_keypoints") and parsed_data["_keypoints"].size() > 0:
		kp0 = parsed_data["_keypoints"][0]

	var origin_pos = "KP_0_Position" if (kp0.has("Position") and declared.has("KP_0_Position")) else "vec3(0.0)"

	var c = "// --- EMITTER-ZUSTAND (GetCurKeyPoint) ZUR ELEMENT-ZEIT t_elem ---\n"
	c += "void emitter_state(float t_elem, out vec3 e_pos, out vec4 e_rot, out float e_scale, out float e_rad, out float e_alpha) {\n"
	c += "\te_pos = " + origin_pos + ";\n"
	c += "\te_rot = " + ("KP_0_Direction" if declared.has("KP_0_Direction") else "vec4(0.0, 0.0, 0.0, 1.0)") + ";\n"
	c += "\te_scale = " + ("KP_0_Scale" if declared.has("KP_0_Scale") else "1.0") + ";\n"
	c += "\te_rad = " + ("KP_0_Rad_2D" if declared.has("KP_0_Rad_2D") else "0.0") + ";\n"
	c += "\t// Partikel übernehmen vom KeyPoint nur das Alpha (UpdateEmitterAlpha / GetCurAlpha)\n"
	c += "\te_alpha = " + ("KP_0_Color.a" if declared.has("KP_0_Color") else "1.0") + ";\n"
	c += "\tvec3 ctrl_offset = vec3(0.0);\n"

	var kp_bases_with_path = []
	for i in range(ctrl_methods.size()):
		if str(ctrl_methods[i].get("CtrlType")) == "110":
			kp_bases_with_path.append(ctrl_to_kp_basetime.get(i, 0.0))

	for i in range(ctrl_methods.size()):
		var child = ctrl_methods[i]
		var ct = str(child.get("CtrlType"))
		var prefix = "CtrlMethod_" + str(i) + "_"
		if not ct in EMITTER_CTRL_TYPES or not declared.has(prefix + "StartTime"):
			continue

		var kp_base = ctrl_to_kp_basetime.get(i, 0.0)
		var kp_dur = ctrl_to_kp_duration.get(i, -1.0)

		c += "\t{\n"
		c += "\t\t// --- CTRL TYPE " + ct + " ---\n"
		c += _gen_ctrl_time(prefix, kp_base, kp_dur, ct == "110")

		var blocked_by_110 = (kp_base in kp_bases_with_path)

		if ct == "100":
			c += "\t\tvec3 dir = length(" + prefix + "Dir) > 0.0001 ? normalize(" + prefix + "Dir) : vec3(0.0);\n"
			if blocked_by_110:
				c += "\t\t// Blockiert: Ein Type_110 existiert im selben KeyPoint!\n"
			else:
				c += "\t\tctrl_offset += dir * (" + prefix + "Vel * t_run + 0.5 * " + prefix + "Acc * t_run * t_run);\n"
		elif ct == "101":
			c += "\t\te_rad += " + prefix + "Vel * t_run + 0.5 * " + prefix + "Acc * t_run * t_run;\n"
		elif ct == "104":
			c += "\t\tvec3 diff = " + origin_pos + " - " + prefix + "Pos;\n"
			c += "\t\tvec3 dir = length(diff) > 0.0001 ? normalize(diff) : vec3(0.0);\n"
			if blocked_by_110:
				c += "\t\t// Blockiert: Ein Type_110 existiert im selben KeyPoint!\n"
			else:
				c += "\t\tctrl_offset += dir * (" + prefix + "Vel * t_run + 0.5 * " + prefix + "Acc * t_run * t_run);\n"
		elif ct == "105":
			c += "\t\t// gfx_ctrl_105 legt 'R, G, B, A' als Color(G, B, A, R) ab -> .argb ergibt wieder RGBA\n"
			c += "\t\tvec4 c_delta = " + prefix + "ColorDelta.argb;\n"
			c += "\t\te_alpha = clamp(e_alpha + c_delta.a * t_run, 0.0, 1.0);\n"
		elif ct == "106":
			var scale_key = prefix + ("ScaleChage" if declared.has(prefix + "ScaleChage") else "ScaleChange")
			if declared.has(scale_key):
				c += "\t\tvec3 sc = " + scale_key + ";\n"
				c += "\t\te_scale = clamp(e_scale + sc.x * t_run, sc.y, sc.z);\n"
		elif ct == "107":
			c += "\t\tfloat n = fbm1D(t_run * max(0.001, " + prefix + "WaveLen), int(" + prefix + "OctaveNum), " + prefix + "Persistence);\n"
			c += "\t\tfloat flicker = max(0.0, 1.0 + (n - 0.5) * " + prefix + "Amplitude * 0.001 * 2.0);\n"
			c += "\t\te_alpha = clamp(" + prefix + "BaseColor.a * flicker, 0.0, 1.0);\n"
		elif ct == "108":
			var stage = _gen_stage_interp(prefix, "Color", "vec4", "t_run * 1000.0", "c_out", "\t\t", declared)
			if stage != "":
				c += stage
				c += "\t\tif (stage_cnt > 0) e_alpha = clamp(c_out.a, 0.0, 1.0);\n"
		elif ct == "109":
			c += "\t\tfloat n = fbm1D((t_run * 1000.0) / max(0.001, " + prefix + "WaveLen), int(" + prefix + "OctaveNum), " + prefix + "Persistence);\n"
			c += "\t\te_scale += n * " + prefix + "Amplitude;\n"
		elif ct == "110":
			var count = path_counts.get(prefix, 0)
			if count > 1:
				c += "\t\tfloat progress = duration > 0.001 ? clamp(t_run / duration, 0.0, 1.0) : 0.0;\n"
				c += "\t\tfloat f_idx = progress * " + str(count - 1) + ".0;\n"
				c += "\t\tint i0 = int(floor(f_idx));\n"
				c += "\t\tint i1 = min(i0 + 1, " + str(count - 1) + ");\n"
				c += "\t\tctrl_offset += mix(" + prefix + "Type_110_Pos_Array[i0], " + prefix + "Type_110_Pos_Array[i1], fract(f_idx));\n"
		elif ct == "111":
			var stage = _gen_stage_interp(prefix, "Scale", "float", "t_run * 1000.0", "s_out", "\t\t", declared)
			if stage != "":
				c += stage
				c += "\t\tif (stage_cnt > 0) e_scale = s_out;\n"
		c += "\t}\n"

	# --- 3D ORBIT & ACHSENROTATION (CtrlType 102 & 103) auf die Emitter-Position ---
	for i in range(ctrl_methods.size()):
		var child = ctrl_methods[i]
		var ct = str(child.get("CtrlType"))
		var prefix = "CtrlMethod_" + str(i) + "_"
		if not ct in ["102", "103"] or not declared.has(prefix + "StartTime"):
			continue

		var kp_base = ctrl_to_kp_basetime.get(i, 0.0)
		var kp_dur = ctrl_to_kp_duration.get(i, -1.0)

		c += "\t{\n"
		c += "\t\t// --- CTRL TYPE " + ct + " (ORBIT) ---\n"
		c += _gen_ctrl_time(prefix, kp_base, kp_dur, false)
		c += "\t\tfloat angle = " + prefix + "Vel * t_run + 0.5 * " + prefix + "Acc * t_run * t_run;\n"
		c += "\t\tvec4 q_orbit = quat_axis(" + prefix + "Axis, angle);\n"
		c += "\t\te_pos = quat_rot(q_orbit, e_pos - " + prefix + "Pos) + " + prefix + "Pos;\n"
		if ct == "102":
			c += "\t\t// RotAxis dreht zusätzlich die Ausrichtung\n"
			c += "\t\te_rot = quat_mul(q_orbit, e_rot);\n"
		c += "\t}\n"

	c += "\te_pos += ctrl_offset;\n"
	c += "}\n\n"
	return c


# Laufzeit einer CtrlMethod innerhalb ihres KeyPoints (wie ID_100)
func _gen_ctrl_time(prefix: String, kp_base: float, kp_dur: float, need_duration: bool) -> String:
	var c = "\t\tfloat kp_time = max(0.0, t_elem - " + _f(kp_base) + ");\n"
	c += "\t\tfloat start = " + prefix + "StartTime;\n"
	c += "\t\tfloat end = " + prefix + "EndTime;\n"
	c += "\t\tfloat t_run = max(0.0, kp_time - start);\n"
	if need_duration:
		c += "\t\tfloat duration = 0.0;\n"
	c += "\t\tif (end >= 0.0) {\n"
	if need_duration:
		c += "\t\t\tduration = max(0.0001, end - start);\n"
	c += "\t\t\tt_run = min(t_run, max(0.0, end - start));\n"
	if kp_dur != -1.0:
		c += "\t\t} else {\n"
		if need_duration:
			c += "\t\t\tduration = max(0.0001, " + _f(kp_dur) + " - start);\n"
		c += "\t\t\tt_run = min(t_run, max(0.0, " + _f(kp_dur) + " - start));\n"
	c += "\t\t}\n"
	return c


# ====================================================
# PARTIKEL: InitParticle (Emitter-Hook) + ApplyMotion + Affectors (analytisch über das Alter)
# ====================================================
func _gen_eval_particle(affectors: Array, declared: Dictionary, path_counts: Dictionary, has_hsv: bool) -> String:
	var u_bind = _u(declared, "IsBind", "true")
	var u_drag = _u(declared, "IsDrag", "false")
	var u_drag_pow = _u(declared, "DragPow", "1.0")
	var u_scale_no_off = _u(declared, "ScaleNoOff", "false")
	var u_speed = _u(declared, "Speed", "0.0")
	var u_par_acc = _u(declared, "ParAcc", "0.0")
	var u_acc = _u(declared, "Acc", "0.0")
	var u_acc_dir = _u(declared, "AccDir", "vec3(0.0, 0.0, -1.0)")
	var u_ttl = _u(declared, "TTL", "1.0")
	var u_col_min = _u(declared, "ColorMin", "vec4(1.0)")
	var u_col_max = _u(declared, "ColorMax", "vec4(1.0)")
	var u_scl_min = _u(declared, "ScaleMin", "1.0")
	var u_scl_max = _u(declared, "ScaleMax", "1.0")
	var u_rot_min = _u(declared, "RotMin", "0.0")
	var u_rot_max = _u(declared, "RotMax", "0.0")

	var c = "// --- EIN PARTIKEL (Emission e_idx, Alter in Sekunden) ---\n"
	c += "void eval_particle(float e_idx, float age, float t_emit, float t_now,\n"
	c += "\t\tout vec3 w_pos, out vec3 w_move, out vec3 w_ax_x, out vec3 w_ax_y,\n"
	c += "\t\tout float p_size, out float p_rad, out vec4 p_col, out float k_scale, out float k_alpha) {\n"
	c += "\t// Emitter zur Emissionszeit (ungebundene Partikel) und jetzt (Bind, Drag, Alpha, Scale)\n"
	c += "\tvec3 ee_pos; vec4 ee_rot; float ee_scale; float ee_rad; float ee_alpha;\n"
	c += "\temitter_state(t_emit, ee_pos, ee_rot, ee_scale, ee_rad, ee_alpha);\n"
	c += "\tvec3 en_pos; vec4 en_rot; float en_scale; float en_rad; float en_alpha;\n"
	c += "\temitter_state(t_now, en_pos, en_rot, en_scale, en_rad, en_alpha);\n"
	c += "\tk_scale = en_scale;\n"
	c += "\tk_alpha = en_alpha;\n"
	c += "\tbool is_bind = " + u_bind + ";\n"
	c += "\t// vEmitPos = matParent * (m_matSelfScale * kp.m_vPos) bzw. ohne Scale bei ScaleNoOff\n"
	c += "\tvec3 ee_world = " + u_scale_no_off + " ? ee_pos : ee_pos * ee_scale;\n"
	c += "\tvec3 en_world = " + u_scale_no_off + " ? en_pos : en_pos * en_scale;\n"
	c += "\tvec4 par_dir = quat_mul(ee_rot, ParIniDir_Quat);\n\n"

	c += "\t// --- InitParticle (Emitter-Hook, ID " + _element_id() + ") ---\n"
	c += "\t// p_rel = Startposition relativ zum Emitter, move_dir = Flugrichtung, p_rot = Ausrichtung\n"
	c += "\tvec3 move_dir;\n"
	c += "\tvec4 p_rot;\n"
	c += "\tvec3 p_rel;\n"
	c += _gen_emitter_init(declared)
	c += "\t// Lineare Verschiebung: verschiebt auch die Drehzentren (ProcData.m_vAxisOff)\n"
	c += "\tvec3 lin = vec3(0.0);\n"
	c += "\tp_size = mix(" + u_scl_min + ", " + u_scl_max + ", rnd(e_idx, 3.0));\n"
	c += "\tp_rad = mix(" + u_rot_min + ", " + u_rot_max + ", rnd(e_idx, 4.0));\n"
	c += "\tfloat p_noise = 0.0;\n\n"

	c += "\t// --- GenColor ---\n"
	if has_hsv:
		c += "\tif (IsUseHSVInterp) {\n"
		c += "\t\tfloat f = rnd(e_idx, 5.0);\n"
		c += "\t\tvec3 h_min = rgb2hsv(" + u_col_min + ".rgb);\n"
		c += "\t\tvec3 h_max = rgb2hsv(" + u_col_max + ".rgb);\n"
		c += "\t\tfloat hue = h_min.x > h_max.x ? fract(h_min.x * f + (1.0 + h_max.x) * (1.0 - f)) : h_min.x * f + h_max.x * (1.0 - f);\n"
		c += "\t\tvec2 sv = h_min.yz * f + h_max.yz * (1.0 - f);\n"
		c += "\t\tp_col = vec4(hsv2rgb(vec3(hue, sv)), " + u_col_min + ".a * f + " + u_col_max + ".a * (1.0 - f));\n"
		c += "\t} else {\n"
		c += "\t\tp_col = mix(" + u_col_min + ", " + u_col_max + ", vec4(rnd(e_idx, 5.0), rnd(e_idx, 6.0), rnd(e_idx, 7.0), rnd(e_idx, 8.0)));\n"
		c += "\t\tp_col.a *= ee_alpha;\n"
		c += "\t}\n\n"
	else:
		c += "\tp_col = mix(" + u_col_min + ", " + u_col_max + ", vec4(rnd(e_idx, 5.0), rnd(e_idx, 6.0), rnd(e_idx, 7.0), rnd(e_idx, 8.0)));\n"
		c += "\tp_col.a *= ee_alpha;\n\n"

	c += "\t// --- ApplyMotion: Eigengeschwindigkeit + Beschleunigung ---\n"
	c += "\tlin += move_dir * (" + u_speed + " * age + 0.5 * " + u_par_acc + " * age * age);\n"
	c += "\tlin += " + u_acc_dir + " * (0.5 * " + u_acc + " * age * age);\n\n"

	# Achs-Offset: m_vParAxisOff = Zentrum des LETZTEN Affectors mit Achse
	var last_axis_prefix = ""
	for i in range(affectors.size()):
		var prefix = "Affector_" + str(i) + "_"
		if str(affectors[i].get("CtrlType")) in AXIS_CTRL_TYPES and declared.has(prefix + "Pos"):
			last_axis_prefix = prefix
	if last_axis_prefix != "":
		c += "\t// vAxisOff = matWorld * m_vParAxisOff - m_vParAxisOff (nur ungebunden)\n"
		c += "\tvec3 axis_off = is_bind ? vec3(0.0) : quat_rot(ee_rot, " + last_axis_prefix + "Pos) - " + last_axis_prefix + "Pos;\n\n"

	for i in range(affectors.size()):
		var child = affectors[i]
		var ct = str(child.get("CtrlType"))
		var prefix = "Affector_" + str(i) + "_"
		if not ct in AFFECTOR_CTRL_TYPES or not declared.has(prefix + "StartTime"):
			continue

		c += "\t// --- AFFECTOR " + str(i) + ": CTRL TYPE " + ct + " ---\n"
		c += "\tif (age >= " + prefix + "StartTime && (" + prefix + "EndTime < 0.0 || " + prefix + "StartTime <= " + prefix + "EndTime)) {\n"
		c += "\t\tfloat a0 = " + prefix + "StartTime;\n"
		c += "\t\tfloat a1 = " + prefix + "EndTime < 0.0 ? age : min(age, " + prefix + "EndTime);\n"

		if ct in ["100", "101", "102", "103", "104"]:
			c += "\t\t// CalcDist: v(t) = Vel + Acc * Alter\n"
			c += "\t\tfloat dist = " + prefix + "Vel * (a1 - a0) + 0.5 * " + prefix + "Acc * (a1 * a1 - a0 * a0);\n"

		if ct == "100":
			c += "\t\tlin += " + prefix + "Dir * dist;\n"
		elif ct == "101":
			c += "\t\tp_rad += dist;\n"
		elif ct in ["102", "103"]:
			c += "\t\tvec3 ctr = " + prefix + "Pos + axis_off;\n"
			c += "\t\tvec4 q_axis = quat_axis(" + prefix + "Axis, dist);\n"
			c += "\t\tp_rel = quat_rot(q_axis, p_rel - ctr) + ctr;\n"
			if ct == "102":
				c += "\t\tp_rot = quat_mul(q_axis, p_rot);\n"
		elif ct == "104":
			c += "\t\tif (" + prefix + "Vel != 0.0) {\n"
			c += "\t\t\tvec3 ctr = " + prefix + "Pos + axis_off;\n"
			c += "\t\t\tvec3 r = p_rel - ctr;\n"
			c += "\t\t\tfloat r_len = length(r);\n"
			c += "\t\t\tif (r_len > 0.000001) p_rel = ctr + r / r_len * max(0.0, r_len + dist);\n"
			c += "\t\t}\n"
		elif ct == "105":
			c += "\t\t// gfx_ctrl_105 legt 'R, G, B, A' als Color(G, B, A, R) ab -> .argb ergibt wieder RGBA\n"
			c += "\t\tp_col = clamp(p_col + " + prefix + "ColorDelta.argb * (a1 - a0), 0.0, 1.0);\n"
		elif ct == "106":
			var scale_key = prefix + ("ScaleChage" if declared.has(prefix + "ScaleChage") else "ScaleChange")
			if declared.has(scale_key):
				c += "\t\tvec3 sc = " + scale_key + ";\n"
				c += "\t\tp_size = clamp(p_size + sc.x * (a1 - a0), sc.y, sc.z);\n"
		elif ct == "107":
			c += "\t\tfloat n = fbm1D(a1 * 1000.0 / max(1.0, " + prefix + "WaveLen), int(" + prefix + "OctaveNum), " + prefix + "Persistence);\n"
			c += "\t\tvec4 base_col = " + prefix + "BaseColor;\n"
			c += "\t\tp_col = vec4(base_col.rgb, clamp(base_col.a + (n * 2.0 - 1.0) * " + prefix + "Amplitude / 255.0, 0.0, 1.0));\n"
		elif ct == "108":
			var stage = _gen_stage_interp(prefix, "Color", "vec4", "a1 * 1000.0", "c_out", "\t\t", declared)
			if stage != "":
				c += stage
				c += "\t\tif (stage_cnt > 0) {\n"
				if declared.has(prefix + "AlphaOnly"):
					c += "\t\t\tif (" + prefix + "AlphaOnly) p_col.a = c_out.a; else p_col = c_out;\n"
				else:
					c += "\t\t\tp_col = c_out;\n"
				c += "\t\t}\n"
		elif ct == "109":
			c += "\t\tp_noise = fbm1D(a1 * 1000.0 / max(0.001, " + prefix + "WaveLen), int(" + prefix + "OctaveNum), " + prefix + "Persistence) * " + prefix + "Amplitude;\n"
		elif ct == "110":
			var count = path_counts.get(prefix, 0)
			if count > 0:
				c += "\t\t// Affector-CurveMove: m_fTimeSpan bleibt 0 (kein Update()) -> Ratio 1 = letzter Punkt\n"
				c += "\t\tp_rel = " + prefix + "Type_110_Pos_Array[" + str(count - 1) + "] - (is_bind ? vec3(0.0) : ee_world);\n"
				c += "\t\tlin = vec3(0.0);\n"
		elif ct == "111":
			var stage = _gen_stage_interp(prefix, "Scale", "float", "a1 * 1000.0", "s_out", "\t\t", declared)
			if stage != "":
				c += stage
				c += "\t\tif (stage_cnt > 0) p_size = s_out;\n"
		c += "\t}\n"

	c += "\n\t// --- WELT-POSITION & AUSRICHTUNG ---\n"
	c += "\tvec3 p_local = p_rel + lin;\n"
	c += "\tvec4 q3 = quat_mul(p_rot, quat_axis(vec3(0.0, 0.0, 1.0), p_rad));\n"
	c += "\tvec3 ax_x = quat_rot(q3, vec3(1.0, 0.0, 0.0));\n"
	c += "\tvec3 ax_y = quat_rot(q3, vec3(0.0, 1.0, 0.0));\n"
	c += "\tif (is_bind) {\n"
	c += "\t\t// GetBindTranMat: KeyPoint-Transform (inkl. Rad_2D um Z) * Scale\n"
	c += "\t\tvec4 bind_rot = quat_mul(en_rot, quat_axis(vec3(0.0, 0.0, 1.0), en_rad));\n"
	c += "\t\tw_pos = " + u_scale_no_off + " ? (quat_rot(bind_rot, p_local * en_scale) + en_pos) : ((quat_rot(bind_rot, p_local) + en_pos) * en_scale);\n"
	c += "\t\tw_move = quat_rot(bind_rot, move_dir);\n"
	c += "\t\tax_x = quat_rot(bind_rot, ax_x) * en_scale;\n"
	c += "\t\tax_y = quat_rot(bind_rot, ax_y) * en_scale;\n"
	c += "\t} else {\n"
	c += "\t\tw_pos = ee_world + p_local;\n"
	c += "\t\tif (" + u_drag + ") {\n"
	c += "\t\t\t// IsDrag: Partikel wird mit abnehmender Stärke vom Emitter mitgezogen\n"
	c += "\t\t\tfloat portion = pow(max(0.00001, clamp(age / max(0.0001, " + u_ttl + "), 0.0, 1.0)), " + u_drag_pow + ");\n"
	c += "\t\t\tw_pos += (1.0 - portion) * (en_world - ee_world);\n"
	c += "\t\t}\n"
	c += "\t\tw_move = move_dir;\n"
	c += "\t}\n"
	c += "\tw_ax_x = ax_x;\n"
	c += "\tw_ax_y = ax_y;\n"
	c += "\t// fScale = m_fScale + m_fScaleNoise\n"
	c += "\tp_size = p_size + p_noise;\n"
	c += "}\n\n"
	return c


# Mehrstufige Übergänge (CtrlType 108 Farbe / 111 Scale), Zeit in Millisekunden
func _gen_stage_interp(prefix: String, base: String, glsl_type: String, t_ms_expr: String, out_var: String, indent: String, declared: Dictionary) -> String:
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
		c += indent + "\tfloat ts = max(0.0001, " + times[s] + ");\n"
		c += indent + "\tif (t_ms <= stage_t + ts) { " + out_var + " = mix(" + vals[s] + ", " + vals[s + 1] + ", clamp((t_ms - stage_t) / ts, 0.0, 1.0)); stage_done = true; }\n"
		c += indent + "\tstage_t += ts;\n"
		c += indent + "}\n"
	if stages > 0:
		c += indent + "// Hinter dem letzten Segment bleibt der letzte Zielwert stehen\n"
		c += indent + "if (!stage_done) {\n"
		for s in range(stages):
			c += indent + "\tif (stage_cnt == " + str(s + 1) + ") " + out_var + " = " + vals[s + 1] + ";\n"
		c += indent + "\tif (stage_cnt > " + str(stages) + ") " + out_var + " = " + vals[stages] + ";\n"
		c += indent + "}\n"
	return c


# ====================================================
# EMITTER-HOOKS (Standard = A3DPointEmitter, überschrieben von create_id_121 … 125)
# ====================================================
func _element_id() -> String:
	return "120"

# Anzahl CtrlMethods am Listenanfang, die dem Emitter selbst gehören (nicht den KeyPoints)
func _emitter_owned_ctrl_count(_parsed_data: Dictionary) -> int:
	return 0

# false = GetEmissionCount liefert immer 0
func _emitter_can_emit(_parsed_data: Dictionary, _emitter_ctrls: Array) -> bool:
	return true

# Zusätzliche Uniforms des Emitters
func _gen_emitter_uniforms(_parent_node: Node, _parsed_data: Dictionary, _declared: Dictionary, _uniform_assignments: Dictionary, _emitter_ctrls: Array) -> String:
	return ""

# Zusätzliche GLSL-Funktionen des Emitters (nach rnd/quat/gen_direction eingefügt)
func _gen_emitter_functions(_declared: Dictionary) -> String:
	return ""

# InitParticle: muss p_rel, move_dir und p_rot setzen.
# Verfügbar: e_idx, is_bind, ee_rot, ee_scale, ee_world, par_dir
func _gen_emitter_init(declared: Dictionary) -> String:
	var u_angle = _u(declared, "Angle", "0.0")
	var c = "\t// A3DPointEmitter::InitParticle\n"
	c += "\tif (" + _u(declared, "IsSurface", "false") + ") {\n"
	c += "\t\t// Partikel exakt auf dem Kegelmantel mit Öffnungswinkel Angle\n"
	c += "\t\tfloat r_az = rnd(e_idx, 1.0) * TAU;\n"
	c += "\t\tvec3 up = vec3(cos(r_az), sin(r_az), 0.0);\n"
	c += "\t\tvec4 q = quat_mul(quat_axis(up, PI * 0.5 - " + u_angle + "), quat_axis(vec3(0.0, 0.0, 1.0), r_az));\n"
	c += "\t\tp_rot = is_bind ? q : quat_mul(par_dir, q);\n"
	c += "\t\tmove_dir = quat_rot(p_rot, vec3(0.0, 1.0, 0.0));\n"
	c += "\t} else {\n"
	c += "\t\tmove_dir = gen_direction(e_idx, is_bind, ee_rot, " + u_angle + ");\n"
	c += "\t\tp_rot = is_bind ? vec4(0.0, 0.0, 0.0, 1.0) : par_dir;\n"
	c += "\t}\n"
	c += "\t// Start 0.001 vor dem Emitter (_init_delta)\n"
	c += "\tp_rel = move_dir * 0.001;\n"
	return c


# ====================================================
# GEMEINSAME BAUSTEINE FÜR DIE ABGELEITETEN EMITTER
# ====================================================
# A3DAreaEmitter (121, 123, 124)
func _area_offset_glsl() -> String:
	var c = "// A3DAreaEmitter::UpdateEmitterScale: X/Y/ZRange = Achse * AreaSize / 2\n"
	c += "// (ungebunden zusätzlich mit der Emitter-Richtung gedreht und mit dem KeyPoint-Scale skaliert)\n"
	c += "vec3 area_offset(vec3 u, vec3 area_size, bool is_bind, vec4 parent_rot, float parent_scale) {\n"
	c += "\tvec3 local_off = u * area_size * 0.5;\n"
	c += "\treturn is_bind ? local_off : quat_rot(parent_rot, local_off * parent_scale);\n"
	c += "}\n\n"
	return c

# p_rel aus den Range-Faktoren + initParticlePosDirByBindAndDragProperty (+ GenDirection)
func _area_finish(declared: Dictionary, u_var: String, gen_dir: bool) -> String:
	var c = "\tp_rel = area_offset(" + u_var + ", " + _u(declared, "AreaSize", "vec3(1.0)") + ", is_bind, ee_rot, ee_scale);\n"
	c += "\t// initParticlePosDirByBindAndDragProperty: ungebunden übernimmt das Partikel m_qParticleDir\n"
	c += "\tp_rot = is_bind ? vec4(0.0, 0.0, 0.0, 1.0) : par_dir;\n"
	if gen_dir:
		c += "\tmove_dir = gen_direction(e_idx, is_bind, ee_rot, " + _u(declared, "Angle", "0.0") + ");\n"
	return c

# CalcVertVec (A3DGFXKeyPoint.h) für 122 und 125
func _calc_vert_vec_glsl() -> String:
	var c = "// CalcVertVec: beliebiger Vektor senkrecht zu d\n"
	c += "vec3 calc_vert_vec(vec3 d) {\n"
	c += "\tvec3 v = abs(d.y) > 0.999 ? cross(d, vec3(1.0, 0.0, 0.0)) : cross(vec3(0.0, 1.0, 0.0), d);\n"
	c += "\treturn length(v) > 0.000001 ? normalize(v) : vec3(1.0, 0.0, 0.0);\n"
	c += "}\n\n"
	return c

# IsAvgGen (123/124): Winkel pro Ring. Angelica zählt alpha += 2PI / AlphaSeg in float32,
# bis alpha > 2PI ist – je nach Rundung entstehen AlphaSeg oder AlphaSeg + 1 Punkte.
func _avg_ring_count(alpha_seg: int) -> int:
	var two_pi = _f32(TAU)
	var delta = _f32(two_pi / float(max(alpha_seg, 1)))
	var alpha = 0.0
	var count = 0
	while count < 100000:
		count += 1
		alpha = _f32(alpha + delta)
		if alpha > two_pi:
			break
	return count

# float32-Rundung wie in der C++-Engine
func _f32(value: float) -> float:
	return PackedFloat32Array([value])[0]

func _declare_ctrl_uniforms(child: Node, prefix: String, group_name: String, declared: Dictionary, uniform_assignments: Dictionary) -> String:
	var params_dict = _get_node_params(child)
	if params_dict.is_empty():
		return ""

	var c = "group_uniforms " + group_name + ";\n"
	for param in params_dict.keys():
		var glsl_type = _godot_type_to_glsl(params_dict.get(param))
		if glsl_type != "":
			var uniform_name = prefix + param
			c += _declare(declared, glsl_type, uniform_name)
			uniform_assignments[uniform_name] = child.get(param)
	c += "group_uniforms;\n\n"
	return c


# CtrlType 110: Pos, Pos_2, ... als vec3-Array-Uniform (wie ID_100)
func _declare_path_array(child: Node, prefix: String, declared: Dictionary, uniform_assignments: Dictionary, path_counts: Dictionary) -> String:
	if str(child.get("CtrlType")) != "110":
		return ""
	var count = int(child.get("Count")) if child.get("Count") != null else 0
	if count <= 0:
		return ""

	var vec3_array = PackedVector3Array()
	var pos_data = child.get("Pos_Array")
	if typeof(pos_data) == TYPE_ARRAY or typeof(pos_data) == TYPE_PACKED_VECTOR3_ARRAY:
		for p in pos_data:
			vec3_array.append(p if typeof(p) == TYPE_VECTOR3 else Vector3.ZERO)
	while vec3_array.size() < count:
		vec3_array.append(Vector3.ZERO)
	vec3_array.resize(count)

	var u_name = prefix + "Type_110_Pos_Array"
	uniform_assignments[u_name] = vec3_array
	path_counts[prefix] = count
	declared[u_name] = true
	return "uniform vec3 " + u_name + "[" + str(count) + "];\n"


func _declare(declared: Dictionary, glsl_type: String, uniform_name: String, hint: String = "") -> String:
	if declared.has(uniform_name):
		return ""
	declared[uniform_name] = true
	return "uniform " + glsl_type + " " + uniform_name + hint + ";\n"

# Uniform-Name falls deklariert, sonst ein GLSL-Ersatzwert
func _u(declared: Dictionary, uniform_name: String, fallback: String) -> String:
	return uniform_name if declared.has(uniform_name) else fallback

func _f(value: float) -> String:
	return "%.6f" % value

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
