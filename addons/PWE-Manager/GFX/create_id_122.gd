@tool
extends "create_id_120.gd"

# ====================================================
# GFXELEMENTID 122 = ID_ELE_TYPE_PARTICLE_MULTIPLANE (A3DMultiPlaneEmitter)
# ====================================================
# Partikel entstehen auf den Dreiecken eines Referenzmodells (RefModel, A3DMultiPlaneEmitter::
# LoadSkinModel: Gfx\Models\<RefModel>, .smd; .mox fehlt noch). Die .smd der Spieldaten wird wie
# beim GFX-Modell zur Szene (gfx_sources.gd); daraus ziehen wir SAMPLE_COUNT flächengewichtete
# Zufallspunkte
# (wie RandDecidePlane + RandGenVert). Jede Emission nimmt zufällig einen davon.
# Ohne Modell starten die Partikel am Emitter (Angelica würde sie gar nicht initialisieren).
# ====================================================

const SAMPLE_COUNT = 128

var _sample_count = 0

func _element_id() -> String:
	return "122"

func _gen_emitter_uniforms(_parent_node: Node, parsed_data: Dictionary, declared: Dictionary, uniform_assignments: Dictionary, _emitter_ctrls: Array) -> String:
	_sample_count = 0
	var ref_model = str(parsed_data.get("RefModel", "")).strip_edges()
	var mesh = _load_ref_mesh(ref_model)
	if mesh == null:
		if ref_model != "":
			preload("gfx_sources.gd").warn("MultiPlane-Referenzmodell Gfx\\Models\\" + ref_model + " nicht gefunden -> Partikel starten am Emitter")
		return ""

	var samples = _sample_mesh(mesh, hash(ref_model))
	var points: PackedVector3Array = samples[0]
	if points.is_empty():
		push_warning("MultiPlane-Referenzmodell ohne Dreiecke: " + ref_model)
		return ""

	_sample_count = points.size()
	uniform_assignments["MultiPlane_Points"] = points
	uniform_assignments["MultiPlane_Normals"] = samples[1]
	declared["MultiPlane_Points"] = true
	declared["MultiPlane_Normals"] = true

	var c = "group_uniforms Emitter_MultiPlane;\n"
	c += "// Stichproben von " + ref_model.replace("\\", "/") + "\n"
	c += "uniform vec3 MultiPlane_Points[" + str(_sample_count) + "];\n"
	c += "uniform vec3 MultiPlane_Normals[" + str(_sample_count) + "];\n"
	c += "group_uniforms;\n\n"
	return c

func _gen_emitter_functions(_declared: Dictionary) -> String:
	var c = _calc_vert_vec_glsl()
	c += "// QuatFromAxes: Quaternion, das x/y/z auf die Basis (x_ax, y_ax, z_ax) dreht\n"
	c += "vec4 quat_from_basis(vec3 x_ax, vec3 y_ax, vec3 z_ax) {\n"
	c += "\tfloat tr = x_ax.x + y_ax.y + z_ax.z;\n"
	c += "\tvec4 q;\n"
	c += "\tif (tr > 0.0) {\n"
	c += "\t\tfloat s = sqrt(tr + 1.0) * 2.0;\n"
	c += "\t\tq = vec4((y_ax.z - z_ax.y) / s, (z_ax.x - x_ax.z) / s, (x_ax.y - y_ax.x) / s, 0.25 * s);\n"
	c += "\t} else if (x_ax.x > y_ax.y && x_ax.x > z_ax.z) {\n"
	c += "\t\tfloat s = sqrt(1.0 + x_ax.x - y_ax.y - z_ax.z) * 2.0;\n"
	c += "\t\tq = vec4(0.25 * s, (y_ax.x + x_ax.y) / s, (z_ax.x + x_ax.z) / s, (y_ax.z - z_ax.y) / s);\n"
	c += "\t} else if (y_ax.y > z_ax.z) {\n"
	c += "\t\tfloat s = sqrt(1.0 + y_ax.y - x_ax.x - z_ax.z) * 2.0;\n"
	c += "\t\tq = vec4((y_ax.x + x_ax.y) / s, 0.25 * s, (z_ax.y + y_ax.z) / s, (z_ax.x - x_ax.z) / s);\n"
	c += "\t} else {\n"
	c += "\t\tfloat s = sqrt(1.0 + z_ax.z - x_ax.x - y_ax.y) * 2.0;\n"
	c += "\t\tq = vec4((z_ax.x + x_ax.z) / s, (z_ax.y + y_ax.z) / s, 0.25 * s, (x_ax.y - y_ax.x) / s);\n"
	c += "\t}\n"
	c += "\treturn normalize(q);\n"
	c += "}\n\n"
	c += "// RandomDeviation: d zufällig um bis zu angle kippen\n"
	c += "vec3 random_deviation(vec3 d, float angle, float e_idx) {\n"
	c += "\tvec3 up = quat_rot(quat_axis(d, rnd(e_idx, 12.0) * TAU), calc_vert_vec(d));\n"
	c += "\treturn quat_rot(quat_axis(up, rnd(e_idx, 13.0) * angle), d);\n"
	c += "}\n\n"
	return c

func _gen_emitter_init(declared: Dictionary) -> String:
	var u_angle = _u(declared, "Angle", "0.0")
	var c = "\t// A3DMultiPlaneEmitter::InitParticle\n"
	c += "\t// m_qParticleDir (gebunden ohne Emitter-Richtung, da m_qParentDir dort nie gesetzt wird)\n"
	c += "\tvec4 mp_dir = is_bind ? ParIniDir_Quat : par_dir;\n"
	if _sample_count == 0:
		c += "\t// Kein Referenzmodell -> Start am Emitter\n"
		c += "\tp_rel = vec3(0.0);\n"
		c += "\tp_rot = mp_dir;\n"
		c += "\tmove_dir = gen_direction(e_idx, is_bind, ee_rot, " + u_angle + ");\n"
		return c

	c += "\tint mp_idx = min(int(rnd(e_idx, 11.0) * " + str(_sample_count) + ".0), " + str(_sample_count - 1) + ");\n"
	c += "\tvec3 mp_pos = MultiPlane_Points[mp_idx];\n"
	c += "\tvec3 mp_n = MultiPlane_Normals[mp_idx];\n"
	c += "\t// Modellpunkt wird NICHT um die Emitterposition verschoben (kein initParticlePosDirByBindAndDragProperty)\n"
	c += "\tp_rel = is_bind ? mp_pos : mp_pos - ee_world;\n"
	c += "\tif (" + _u(declared, "UseNormal", "false") + ") {\n"
	c += "\t\tif (" + _u(declared, "PerpToNormal", "true") + ") {\n"
	c += "\t\t\t// Partikel liegt flach auf der Fläche (Z = Normale)\n"
	c += "\t\t\tvec3 z_ax = normalize(mp_n);\n"
	c += "\t\t\tvec3 x_ax = normalize(cross(calc_vert_vec(z_ax), z_ax));\n"
	c += "\t\t\tp_rot = quat_from_basis(x_ax, cross(z_ax, x_ax), z_ax);\n"
	c += "\t\t\tmove_dir = gen_direction(e_idx, is_bind, ee_rot, " + u_angle + ");\n"
	c += "\t\t} else {\n"
	c += "\t\t\t// Flug entlang der Flächennormale\n"
	c += "\t\t\tp_rot = mp_dir;\n"
	c += "\t\t\tmove_dir = " + u_angle + " != 0.0 ? random_deviation(mp_n, " + u_angle + ", e_idx) : mp_n;\n"
	c += "\t\t}\n"
	c += "\t} else {\n"
	c += "\t\tp_rot = mp_dir;\n"
	c += "\t\tmove_dir = gen_direction(e_idx, is_bind, ee_rot, " + u_angle + ");\n"
	c += "\t}\n"
	return c


# ====================================================
# REFERENZMODELL LADEN & ABTASTEN
# ====================================================
func _load_ref_mesh(ref_model: String) -> Mesh:
	if ref_model == "":
		return null
	var scene: PackedScene = preload("gfx_sources.gd").model(ref_model)
	if scene == null:
		return null
	var inst = scene.instantiate()
	var found = _find_mesh(inst)
	inst.free()
	return found

func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and node.mesh != null:
		return node.mesh
	for child in node.get_children():
		var m = _find_mesh(child)
		if m != null:
			return m
	return null

# Liefert [Punkte, Normalen] – flächengewichtet wie CalcPlanePortion / RandDecidePlane / RandGenVert
func _sample_mesh(mesh: Mesh, seed_value: int) -> Array:
	var tris = []
	var cumulative = PackedFloat32Array()
	var total_area = 0.0

	for s in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices = arrays[Mesh.ARRAY_INDEX]
		var has_indices = indices != null and indices.size() > 0
		var count = indices.size() if has_indices else verts.size()

		for t in range(0, count - 2, 3):
			var v1 = verts[indices[t]] if has_indices else verts[t]
			var v2 = verts[indices[t + 1]] if has_indices else verts[t + 1]
			var v3 = verts[indices[t + 2]] if has_indices else verts[t + 2]
			# norm = CrossProduct(v2 - v1, v3 - v1), Fläche = |norm| / 2
			var norm = (v2 - v1).cross(v3 - v1)
			var area = norm.length() * 0.5
			if area <= 0.0:
				continue
			total_area += area
			cumulative.append(total_area)
			tris.append([v1, v2, v3, norm.normalized()])

	var points = PackedVector3Array()
	var normals = PackedVector3Array()
	if tris.is_empty():
		return [points, normals]

	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	for i in range(SAMPLE_COUNT):
		var tri_idx = mini(cumulative.bsearch(rng.randf() * total_area), tris.size() - 1)
		var tri = tris[tri_idx]
		var r1 = rng.randf()
		var r2 = rng.randf()
		# Parallelogramm-Trick: Punkt außerhalb -> an der Diagonale spiegeln
		if r1 + r2 > 1.0:
			r1 = 1.0 - r1
			r2 = 1.0 - r2
		points.append(tri[0] + (tri[1] - tri[0]) * r1 + (tri[2] - tri[0]) * r2)
		normals.append(tri[3])
	return [points, normals]
