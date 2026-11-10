@tool
extends RefCounted

# ====================================================
# Gebäude einer Map (litmodels\<map>\<teil>\litmodel_<n>.bmd, A3DLitModel) -> Godot.
# .bmd (AFile "MOXB"): Gebäudeversion (ab 0x80000001 mit Flag "nur Kollision"), dann das LitModel
# (A3DLitModel::Load 0x10000002): Skalierung, Richtung, Oben, Position und die Meshes
# (A3DLitMesh::Load 0x10000002 - 0x10000006): Name, Textur, Vertices (Position, Farbe, UV),
# WORD-Indizes, Normalen, Vertexfarben Tag / Nacht (vorberechnetes Licht), AABB, Material
# (2Sided). Danach folgen Kollisionsdaten (nicht genutzt).
# Nur die Gebäude, die die Map nennt (.ecbsd, angelica_world.gd), wie im Spiel; ohne Szenen-Datei
# alle im Ordner.
# Jedes Gebäude trägt seine Weltlage selbst (A3DLitModel::UpdateAbsoluteTM):
#   Scaling(Scale) * TransformMatrix(Dir, Up, Pos), Z = Dir, X = Up x Z, Y = Z x X
# Je Gebäude ein MeshInstance3D "litmodel_<n>" unter einem Node je Teilordner, alle zusammen in
# <map>_buildings.scn (binär). Material je Textur und Seitigkeit geteilt (angelica_litmodel.gdshader
# bzw. _2s). Gebäude nur für die Kollision bleiben weg. Koordinaten wie in Angelica, Dreiecke
# umgedreht wie bei den Modellen (angelica_model_reader.gd).
# ====================================================

const SHADER = preload("../ECM/angelica_litmodel.gdshader")
const SHADER_2SIDED = preload("../ECM/angelica_litmodel_2s.gdshader")
const BUILDING_FLAGS_VERSION = 0x80000001
const MESH_VERSIONS = [0x10000002, 0x10000003, 0x10000004, 0x10000005, 0x10000006, 0x10000100]
const MESH_LIGHTMAP_VERSION = 0x10000100

var importer # ecm_importer.gd
var _builder = null
var _materials = {}


func _init(p_importer) -> void:
	importer = p_importer
	_builder = importer.new_builder()

func _warn(msg: String) -> void:
	importer.warn(msg)


# ====================================================
# LESEN
# ====================================================
# .bmd -> {collide_only, scale, dir, up, pos, meshes: [{name, texture, two_sided, positions,
# normals, uvs, colors, indices}]} oder {"error"}
func read_bmd(path: String) -> Dictionary:
	var b = importer.files.get_bytes(path)
	if b.size() < 64 or b.slice(0, 4).get_string_from_ascii() != "MOXB":
		return {"error": path.get_file() + ": keine Gebäude-Datei"}
	var p = 4
	var out = {"collide_only": false}
	if b.decode_u32(p) >= BUILDING_FLAGS_VERSION:
		out["collide_only"] = b[p + 4] != 0
		p += 5
	var ver = b.decode_u32(p)
	if ver != 0x10000001 and ver != 0x10000002:
		return {"error": path.get_file() + ": LitModel-Version 0x%x wird nicht unterstützt" % ver}
	p += 4
	var v = []
	for k in 4:
		v.append(Vector3(b.decode_float(p), b.decode_float(p + 4), b.decode_float(p + 8)))
		p += 12
	out["scale"] = v[0]
	out["dir"] = v[1]
	out["up"] = v[2]
	out["pos"] = v[3]
	var meshes = []
	var n = b.decode_s32(p)
	p += 4
	for i in n:
		var m = _read_mesh(b, p)
		if m.has("error"):
			return {"error": path.get_file() + ": Mesh " + str(i) + ": " + m["error"]}
		p = m["end"]
		meshes.append(m)
	out["meshes"] = meshes
	return out

func read_bmd_position(path: String) -> Dictionary:
	var b = importer.files.get_bytes(path)
	if b.size() < 64 or b.slice(0, 4).get_string_from_ascii() != "MOXB":
		return {"error": "Не удалось прочитать положение здания: " + path.get_file()}
	var at = 4
	if b.decode_u32(at) >= BUILDING_FLAGS_VERSION:
		at += 5
	var version = b.decode_u32(at)
	if version != 0x10000001 and version != 0x10000002:
		return {"error": "Неизвестная версия здания: " + path.get_file()}
	at += 4
	return {"position": Vector3(b.decode_float(at + 36), b.decode_float(at + 40), b.decode_float(at + 44))}

func read_runtime_chunk(paths: PackedStringArray) -> Array:
	var out = []
	for path in paths:
		var model = read_bmd(path)
		if not model.has("error") and not model["collide_only"]:
			out.append({"path": path, "model": model})
	return out

func runtime_manifest(paths: PackedStringArray, columns: int, rows: int, cell_size: float, width: float, length: float) -> Dictionary:
	var chunks = {}
	for path in paths:
		var record = read_bmd_position(path)
		if record.has("error"):
			continue
		var pos: Vector3 = record["position"]
		var col = clampi(int(floor((pos.x + width * 0.5) / cell_size)), 0, columns - 1)
		var row = clampi(int(floor((length * 0.5 - pos.z) / cell_size)), 0, rows - 1)
		var index = row * columns + col
		if not chunks.has(index):
			chunks[index] = PackedStringArray()
		chunks[index].append(path)
	return chunks

func runtime_manifest_for_map(map_name: String, wanted_paths: Array, columns: int, rows: int, cell_size: float, width: float, length: float) -> Dictionary:
	var dir = importer.find_game_dir("litmodels/" + map_name)
	if dir == "":
		return {}
	var all_paths = []
	_collect(dir, all_paths)
	var wanted = {}
	for rel in wanted_paths:
		wanted[str(rel).replace("\\", "/").to_lower()] = true
	var paths = PackedStringArray()
	for path in all_paths:
		if wanted.has(path.substr(dir.length() + 1).to_lower()):
			paths.append(path)
	return runtime_manifest(paths, columns, rows, cell_size, width, length)

func _read_mesh(b: PackedByteArray, p: int) -> Dictionary:
	if p + 336 > b.size():
		return {"error": "Datei zu kurz"}
	var ver = b.decode_u32(p)
	if not ver in MESH_VERSIONS:
		return {"error": "Version 0x%x wird nicht unterstützt" % ver}
	var m = {"name": _cstr(b, p + 4, 64), "texture": _cstr(b, p + 68, 256), "two_sided": false}
	var nv = b.decode_s32(p + 324)
	var nf = b.decode_s32(p + 328)
	p += 332
	var extra = false
	if ver == 0x10000006:
		extra = b[p] != 0
		p += 1
	# A3DLVERTEX (x, y, z, diffuse, specular, tu, tv) bzw. A3DLMVERTEX_WITHOUTNORMAL (pos, diffuse, u, v)
	var vsize = 28 if ver <= 0x10000003 else 24
	var need = p + nv * vsize + nf * 6 + nv * 12 + (0 if ver == 0x10000002 else nv * 8) + (nv * 8 if extra else 0) + 48
	if nv < 0 or nf < 0 or need > b.size():
		return {"error": "Datei zu kurz"}
	var vf = b.slice(p, p + nv * vsize).to_float32_array()
	var vb = b.slice(p, p + nv * vsize)
	p += nv * vsize
	var ib = b.slice(p, p + nf * 6)
	p += nf * 6
	var nf32 = b.slice(p, p + nv * 12).to_float32_array()
	p += nv * 12
	var cb: PackedByteArray # Tagfarben je Vertex (A3DCOLOR, ARGB)
	var c_stride = 4
	var c_off = 0
	if ver == 0x10000002:
		cb = vb # A3DLitMesh::Load: Tagfarbe = diffuse des Vertex
		c_stride = vsize
		c_off = 12
	else:
		cb = b.slice(p, p + nv * 4)
		p += nv * 8 # Tag + Nacht
	if extra:
		p += nv * 8 # zusätzliche Tag- / Nachtfarben (nicht genutzt)
	p += 48 # AABB
	if ver >= 0x10000005:
		# A3DMaterial::Load (binär): "MATERIAL: <Name>\0", Ambient, Diffuse, Emissive, Specular, Power, 2Sided
		var e = b.find(0, p)
		if e < 0 or e + 70 > b.size():
			return {"error": "Material nicht lesbar"}
		p = e + 1 + 64 + 4
		m["two_sided"] = b[p] != 0
		p += 1
	if ver == MESH_LIGHTMAP_VERSION:
		p += nv * 8 # Lightmap-Koordinaten (nicht genutzt)
	m["end"] = p

	var stride = vsize / 4
	var uv_off = 5 if vsize == 28 else 4
	var positions = PackedVector3Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	var colors = PackedColorArray()
	positions.resize(nv)
	normals.resize(nv)
	uvs.resize(nv)
	colors.resize(nv)
	for i in nv:
		var k = i * stride
		positions[i] = Vector3(vf[k], vf[k + 1], vf[k + 2])
		uvs[i] = Vector2(vf[k + uv_off], vf[k + uv_off + 1])
		normals[i] = Vector3(nf32[i * 3], nf32[i * 3 + 1], nf32[i * 3 + 2])
		var c = cb.decode_u32(i * c_stride + c_off)
		colors[i] = Color8((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)
	# WORD-Indizes, Dreiecke umgedreht (gespiegelte Koordinaten)
	var indices = PackedInt32Array()
	indices.resize(nf * 3)
	for t in nf:
		var a = ib.decode_u16(t * 6)
		var c1 = ib.decode_u16(t * 6 + 2)
		var c2 = ib.decode_u16(t * 6 + 4)
		if a >= nv or c1 >= nv or c2 >= nv:
			return {"error": "Index außerhalb der Vertices"}
		indices[t * 3] = a
		indices[t * 3 + 1] = c2
		indices[t * 3 + 2] = c1
	m["positions"] = positions
	m["normals"] = normals
	m["uvs"] = uvs
	m["colors"] = colors
	m["indices"] = indices
	return m

func _cstr(b: PackedByteArray, at: int, n: int) -> String:
	var s = b.slice(at, at + n)
	var e = s.find(0)
	return importer.files.decode_gbk(s.slice(0, e) if e >= 0 else s)


# ====================================================
# BAUEN
# ====================================================
# Gebäude der Map -> Szene scene_path. only: Pfade relativ zu litmodels\<map>\, die die Map nennt
# (angelica_world.gd building_files), null = alle im Ordner. {"scene", "count", "skipped",
# "unused"}; "scene" fehlt, wenn die Map keine Gebäude hat
func build(map_name: String, scene_path: String, only = null, stream_config: Dictionary = {}) -> Dictionary:
	var dir = importer.find_game_dir("litmodels/" + map_name)
	if dir == "":
		return {"count": 0, "skipped": 0, "unused": 0}
	var files = []
	_collect(dir, files)
	var unused = 0
	if only != null:
		var wanted = {}
		for rel in only:
			wanted[rel.replace("\\", "/").to_lower()] = true
		var all_files = files
		files = all_files.filter(func(f): return wanted.has(f.substr(dir.length() + 1).to_lower()))
		unused = all_files.size() - files.size()
	files.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	var root = Node3D.new()
	root.name = "Buildings"
	var groups = {}
	var chunk_roots = {}
	var count = 0
	var skipped = 0
	for file_index in files.size():
		var f: String = files[file_index]
		var d = read_bmd(f)
		if d.has("error"):
			_warn(d["error"])
			if file_index % 16 == 15:
				await (Engine.get_main_loop() as SceneTree).process_frame
			continue
		if d["collide_only"]:
			skipped += 1
			if file_index % 16 == 15:
				await (Engine.get_main_loop() as SceneTree).process_frame
			continue
		var mesh = _mesh(d)
		if mesh == null:
			if file_index % 16 == 15:
				await (Engine.get_main_loop() as SceneTree).process_frame
			continue
		var parent_root = root
		var chunk_index = -1
		var chunk_groups: Dictionary = groups
		if not stream_config.is_empty():
			var cell_size = float(stream_config["cell_size"])
			var cols = int(stream_config["columns"])
			var rows = int(stream_config["rows"])
			var col = clampi(int(floor((d["pos"].x + float(stream_config["width"]) * 0.5) / cell_size)), 0, cols - 1)
			var row = clampi(int(floor((float(stream_config["length"]) * 0.5 - d["pos"].z) / cell_size)), 0, rows - 1)
			chunk_index = row * cols + col
			if not chunk_roots.has(chunk_index):
				var chunk_root = Node3D.new()
				chunk_root.name = "Buildings_%05d" % chunk_index
				chunk_roots[chunk_index] = {"root": chunk_root, "groups": {}}
			parent_root = chunk_roots[chunk_index]["root"]
			chunk_groups = chunk_roots[chunk_index]["groups"]
		var group_name: String = f.get_base_dir().substr(dir.length()).trim_prefix("/")
		if group_name == "":
			group_name = "Main"
		if not chunk_groups.has(group_name):
			var g = Node3D.new()
			g.name = group_name.replace("/", "_")
			parent_root.add_child(g)
			g.owner = parent_root
			chunk_groups[group_name] = g
		var mi = MeshInstance3D.new()
		mi.name = f.get_file().get_basename()
		mi.mesh = mesh
		mi.transform = _transform(d)
		chunk_groups[group_name].add_child(mi)
		mi.owner = parent_root
		count += 1
		if file_index % 16 == 15:
			if importer.progress_callback.is_valid():
				importer.progress_callback.call("Импорт зданий: файл %d из %d, собрано %d" % [file_index + 1, files.size(), count])
			await (Engine.get_main_loop() as SceneTree).process_frame
	if count == 0:
		root.free()
		return {"count": 0, "skipped": skipped, "unused": unused}
	if not stream_config.is_empty():
		root.free()
		var chunks = PackedInt32Array()
		for index in chunk_roots:
			var chunk = chunk_roots[index]["root"]
			var chunk_scene = PackedScene.new()
			var pack_err = chunk_scene.pack(chunk)
			chunk.free()
			if pack_err == OK:
				pack_err = importer.save_resource(chunk_scene, scene_path.get_base_dir().path_join("buildings/chunk_%05d.scn" % int(index)))
			if pack_err != OK:
				return {"error": "Gebäude-Chunk %05d nicht gespeichert (%s)" % [int(index), error_string(pack_err)]}
			chunks.append(int(index))
		return {"count": count, "skipped": skipped, "unused": unused, "chunks": chunks}
	var packed = PackedScene.new()
	var err = packed.pack(root)
	root.free()
	if err == OK:
		err = importer.save_resource(packed, scene_path)
	if err != OK:
		return {"error": "Gebäude nicht gespeichert (%s)" % error_string(err)}
	return {"scene": scene_path, "count": count, "skipped": skipped, "unused": unused}

func _collect(dir: String, out: Array) -> void:
	var l = importer.files.list_dir(dir)
	for f in l["files"]:
		if f.get_extension().to_lower() == "bmd":
			out.append(dir.path_join(f))
	for d in l["dirs"]:
		_collect(dir.path_join(d), out)

# A3DLitModel::UpdateAbsoluteTM: Scaling * TransformMatrix(Dir, Up, Pos)
func _transform(d: Dictionary) -> Transform3D:
	return transform_of(d["dir"], d["up"], d["pos"], d["scale"])

# Scaling(s) * a3d_TransformMatrix(dir, up, pos): Z = Dir, X = Up x Z, Y = Z x X
static func transform_of(dir: Vector3, up: Vector3, pos: Vector3, s: Vector3) -> Transform3D:
	var z: Vector3 = dir.normalized()
	var x: Vector3 = up.normalized().cross(z)
	if x.length() < 0.000001:
		x = (Vector3.RIGHT if absf(z.y) > 0.999 else Vector3.UP).cross(z)
	x = x.normalized()
	var y = z.cross(x)
	return Transform3D(Basis(x * s.x, y * s.y, z * s.z), pos)

func _mesh(d: Dictionary) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	for m in d["meshes"]:
		if m["indices"].is_empty():
			continue
		var arrays = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = m["positions"]
		arrays[Mesh.ARRAY_NORMAL] = m["normals"]
		arrays[Mesh.ARRAY_TEX_UV] = m["uvs"]
		arrays[Mesh.ARRAY_COLOR] = m["colors"]
		arrays[Mesh.ARRAY_INDEX] = m["indices"]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var s = mesh.get_surface_count() - 1
		mesh.surface_set_name(s, m["name"])
		mesh.surface_set_material(s, _material(m["texture"], m["two_sided"]))
	return mesh if mesh.get_surface_count() > 0 else null

# Material je Textur und Seitigkeit, für alle Gebäude der Map geteilt
func _material(tex_name: String, two_sided: bool) -> ShaderMaterial:
	var key = tex_name.to_lower() + ("|2" if two_sided else "")
	if _materials.has(key):
		return _materials[key]
	var mat = ShaderMaterial.new()
	mat.shader = SHADER_2SIDED if two_sided else SHADER
	if tex_name != "":
		var src = importer.find_game_file(tex_name)
		if src == "":
			_warn("Gebäude-Textur " + tex_name + " nicht gefunden")
		else:
			var tex = _builder.texture_file(src, "Gebäude-Textur " + tex_name)
			importer.take_builder(_builder) # Hinweise und geschriebene Dateien
			if tex != null:
				mat.set_shader_parameter("texture_albedo", tex)
	_materials[key] = mat
	return mat
