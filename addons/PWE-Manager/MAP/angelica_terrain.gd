@tool
extends RefCounted

# ====================================================
# Terrain einer Map (A3DTerrain2 mit A3DTerrain2LoaderB, Angelica2) -> Godot-Szene.
# Dateien im Map-Ordner (maps\<map>\):
#   <map>.trn2   Kopf (Größe, Raster, Blöcke, Maskenbereiche), Texturliste, Namen der Teilkarten
#   <sub>.t2bk   Blöcke (BlockGrid x BlockGrid Raster): Höhen und Normalen (2 Winkelbytes),
#                zlib bzw. inkrementell gepackt (A3DTrn2SubLoaderB::ReadBlockData)
#   <sub>.t2mk   Textur-Ebenen (Textur, UV-Skalierung, Projektionsachse) und je Maskenbereich
#                seine Ebenen mit 8-Bit-Masken; die erste Ebene hat keine Maske (voll)
#   <sub>.t2lm   Lightmap (Tag) je Maskenbereich, meist als DDS; .t2lm1 (Nacht) bleibt ungenutzt
# Standard: kleine <map>.tscn als Layout; Terrain, Gebäude, Wasser und Objekte werden zur Laufzeit
# quellbasiert in Bereichen gelesen und um den Spieler aufgebaut. Keine vorab erzeugten .res/.scn.
# Optionaler Ressourcenmodus: importiert die Meshes vorab; der Laufzeit-Streamer lädt Terrain und
# Gebäude-Chunks aus dem Cache. World-Objekte in diesem Modus bleiben in der Karte.
# Lage wie in Angelica: Mitte der Map im Ursprung, Zeile 0 oben (+z), Koordinaten unverändert
# (wie die Modelle). Bodentexturen der Map als ein Texture2DArray (<map>_layers.res, DXT1,
# angelica_texture_array.gd),
# Masken und Lightmap eines Bereichs im Material von terrain/area_<Nr>.res.
# Blöcke mit T2BKFLAG_NORENDER (Version 6) bleiben leer.
# ====================================================

const TRN2_ID = 0x54524E32 # "TRN2"
const T2BK_ID = 0x54424B42 # "TBKB"
const T2MK_ID = 0x544D4B42 # "TMKB"
const T2LM_ID = 0x54324C4D # "T2LM"
const T2BKCOMP_COL_ZIP = 0x01
const T2BKCOMP_HEI_ZIP = 0x04
const T2BKCOMP_HEI_INC = 0x08
const T2BKCOMP_NOR_ZIP = 0x10
const T2BKCOMP_NOR_DEG = 0x20
const T2BKFLAG_NORENDER = 0x01
const T2LMFILE_DDS = 0x01
const MAX_LAYERS = 16 # angelica_terrain.gdshader
const MAX_TEXTURE_SIZE = 1024 # Bodentexturen im Array
const SHADER = preload("angelica_terrain.gdshader")
const TextureArray = preload("angelica_texture_array.gd") # speichert seine Bilder selbst
const StreamerScript = preload("res://game/client/terrain_streamer.gd")

var importer # ecm_importer.gd: Pfade, Hinweise, Speichern
var _cos = PackedFloat32Array()
var _sin = PackedFloat32Array()
var _runtime_sub_cache = {}
var _runtime_sub_order = []
var _runtime_sub_mutex = Mutex.new()


func _init(p_importer) -> void:
	importer = p_importer
	# a3d_DecompressDir: 256 Schritte für 360 Grad
	for i in 256:
		_cos.append(cos(i * TAU / 256.0))
		_sin.append(sin(i * TAU / 256.0))

func _warn(msg: String) -> void:
	importer.warn(msg)


# ====================================================
# LESEN
# ====================================================
# .trn2 -> Kopf, Texturnamen, Teilkarten {name, min_height}, Maskengröße; {"error"} bei Fehlern
func read_trn2(path: String) -> Dictionary:
	var b = importer.files.get_bytes(path)
	if b.size() < 140 or b.decode_u32(0) != TRN2_ID:
		return {"error": path.get_file() + ": keine Terrain-Datei (TRN2)"}
	var t = {
		"width": b.decode_float(8), "length": b.decode_float(12), "block_size": b.decode_float(16),
		"block_grid": b.decode_s32(20), "num_block": b.decode_s32(24), "block_rows": b.decode_s32(28),
		"block_cols": b.decode_s32(32), "num_texture": b.decode_s32(36), "num_mask_area": b.decode_s32(40),
		"mask_block": b.decode_s32(44), "mask_grid": b.decode_s32(48), "num_sub": b.decode_s32(52),
		"sub_rows": b.decode_s32(56), "sub_cols": b.decode_s32(60), "sub_grid": b.decode_s32(64),
		"grid_size": b.decode_float(68), "loader_id": b.decode_s32(76),
	}
	if t["loader_id"] != 1:
		return {"error": path.get_file() + ": Terrain-Loader " + str(t["loader_id"]) + " wird nicht unterstützt (nur B)"}
	var subs = []
	for i in t["num_sub"]:
		subs.append({"min_height": b.decode_float(140 + i * 8), "max_height": b.decode_float(144 + i * 8)})
	var at = [b.decode_u32(72)]
	var textures = []
	for i in t["num_texture"]:
		textures.append(_string(b, at))
	at = [b.decode_u32(80)]
	t["mask_map_size"] = b.decode_s32(at[0])
	at[0] += 4
	for i in t["num_sub"]:
		subs[i]["name"] = _string(b, at)
	t["textures"] = textures
	t["subs"] = subs
	return t

# AFile::ReadString: Länge (int) + Bytes (GBK)
func _string(b: PackedByteArray, at: Array) -> String:
	var n = b.decode_s32(at[0])
	var s = importer.files.decode_gbk(b.slice(at[0] + 4, at[0] + 4 + n))
	at[0] += 4 + n
	return s

# <sub>.t2bk -> {Blockindex in der Teilkarte: {row, col, mask, flags, heights, normals}}
# (normals = false: ohne Normalen, schneller, z.B. für read_height_grid)
func read_blocks(path: String, num_vert: int, normals: bool = true) -> Dictionary:
	var b = importer.files.get_bytes(path)
	if b.size() < 16 or b.decode_u32(0) != T2BK_ID:
		return {"error": path.get_file() + ": keine Block-Datei (T2BK)"}
	var ver = b.decode_u32(4)
	var num = b.decode_s32(8)
	var comp = 0
	var at = 12
	if ver >= 2:
		comp = b[12] if ver >= 5 else ((T2BKCOMP_COL_ZIP | T2BKCOMP_HEI_ZIP | T2BKCOMP_NOR_ZIP) if b[12] != 0 else 0)
		at = 16
	var info_size = [16, 16, 24, 28, 32, 32, 36][mini(ver, 6)]
	var blocks = {}
	for i in num:
		var o = b.decode_u32(at + i * 4)
		var blk = {"mask": b.decode_s32(o), "row": b.decode_u16(o + 4), "col": b.decode_u16(o + 6), "flags": 0}
		var hei_size = num_vert * 4
		var nor_size = num_vert * 12
		if ver >= 2:
			hei_size = b.decode_u32(o + 16)
			nor_size = b.decode_u32(o + 20)
		if ver >= 6:
			blk["flags"] = b.decode_u32(o + 32)
		var p = o + info_size
		blk["heights"] = _heights(b.slice(p, p + hei_size), comp, num_vert)
		p += hei_size
		blk["normals"] = _normals(b.slice(p, p + nor_size), comp, num_vert) if normals else PackedVector3Array()
		if blk["heights"].size() != num_vert or (normals and blk["normals"].size() != num_vert):
			return {"error": path.get_file() + ": Block " + str(i) + " nicht lesbar"}
		blocks[i] = blk
	return blocks

# Höhenraster der ganzen Map ohne Mesh (z.B. für den Abgleich mit dem Server):
# {rows, cols (Punkte), step, left, top, heights: PackedFloat32Array zeilenweise von +Z} oder {"error"};
# Punkt (r, c) liegt bei x = left + c * step, z = top - r * step (wie die Meshes von build)
func read_height_grid(trn2_path: String) -> Dictionary:
	var t = read_trn2(trn2_path)
	if t.has("error"):
		return t
	var bg: int = t["block_grid"]
	var rows: int = t["block_rows"] * bg + 1
	var cols: int = t["block_cols"] * bg + 1
	var heights = PackedFloat32Array()
	heights.resize(rows * cols)
	var dir = trn2_path.get_base_dir()
	var num_vert = (bg + 1) * (bg + 1)
	var filled = 0
	for sub in t["subs"]:
		var blocks = read_blocks(_find(dir.path_join(sub["name"]) + ".t2bk"), num_vert, false)
		if blocks.has("error"):
			continue
		for k in blocks:
			var blk = blocks[k]
			var hs: PackedFloat32Array = blk["heights"]
			var r0 = int(blk["row"]) * bg
			var c0 = int(blk["col"]) * bg
			for li in bg + 1:
				var r = r0 + li
				if r >= rows:
					break
				for lj in bg + 1:
					var c = c0 + lj
					if c < cols:
						heights[r * cols + c] = hs[li * (bg + 1) + lj]
			filled += 1
	if filled == 0:
		return {"error": trn2_path.get_file() + ": keine Höhen"}
	return {"rows": rows, "cols": cols, "step": float(t["grid_size"]), "left": -t["width"] * 0.5, "top": t["length"] * 0.5,
		"heights": heights, "blocks": filled}

# Höhe im Raster von read_height_grid bei (x, z), bilinear; außerhalb der Rand
static func grid_height(g: Dictionary, x: float, z: float) -> float:
	var fc = clampf((x - g["left"]) / g["step"], 0.0, g["cols"] - 1.0)
	var fr = clampf((g["top"] - z) / g["step"], 0.0, g["rows"] - 1.0)
	var c = mini(int(fc), g["cols"] - 2)
	var r = mini(int(fr), g["rows"] - 2)
	var h: PackedFloat32Array = g["heights"]
	var n: int = g["cols"]
	var a = lerpf(h[r * n + c], h[r * n + c + 1], fc - c)
	var b = lerpf(h[(r + 1) * n + c], h[(r + 1) * n + c + 1], fc - c)
	return lerpf(a, b, fr - r)

# Höhen: zlib, inkrementell (CH_DATAINFO + short-Deltas) oder roh
func _heights(d: PackedByteArray, comp: int, num_vert: int) -> PackedFloat32Array:
	if comp & T2BKCOMP_HEI_ZIP:
		d = d.decompress_dynamic(num_vert * 4 + 64, FileAccess.COMPRESSION_DEFLATE)
	if not (comp & T2BKCOMP_HEI_INC):
		return d.to_float32_array()
	# A3DTerrain2::DecompressHeightMap
	var mn = d.decode_float(4)
	var delta = (d.decode_float(8) - mn) / 32767.0
	var n = mini(d.decode_s32(12), (d.size() - 16) / 2)
	var out = PackedFloat32Array()
	out.resize(n)
	var acc = 0
	for i in n:
		acc += d.decode_s16(16 + i * 2)
		out[i] = mn + acc * delta
	return out

# Normalen: zlib und/oder Winkelbytes (a3d_DecompressDir), sonst 3 Floats
func _normals(d: PackedByteArray, comp: int, num_vert: int) -> PackedVector3Array:
	if comp & T2BKCOMP_NOR_ZIP:
		d = d.decompress_dynamic(num_vert * 12 + 64, FileAccess.COMPRESSION_DEFLATE)
	var out = PackedVector3Array()
	if comp & T2BKCOMP_NOR_DEG:
		var n = mini(d.decode_s32(4), (d.size() - 8) / 2)
		out.resize(n)
		for i in n:
			var b1 = d[8 + i * 2]
			var b2 = d[9 + i * 2]
			var s = _sin[b2]
			out[i] = Vector3(s * _cos[b1], _cos[b2], s * _sin[b1])
	else:
		var f = d.to_float32_array()
		out.resize(f.size() / 3)
		for i in out.size():
			out[i] = Vector3(f[i * 3], f[i * 3 + 1], f[i * 3 + 2])
	return out

# <sub>.t2mk -> {layers: [{texture, mask_size, axis, u_scale, v_scale}], areas: [[{layer, mask}]]}
# mask = 8-Bit-Maske (mask_size²) bzw. leer für die erste Ebene
func read_masks(path: String) -> Dictionary:
	var b = importer.files.get_bytes(path)
	if b.size() < 16 or b.decode_u32(0) != T2MK_ID:
		return {"error": path.get_file() + ": keine Masken-Datei (T2MK)"}
	var ver = b.decode_u32(4)
	var num_area = b.decode_s32(8)
	var num_layer = b.decode_s32(12)
	var comp = ver >= 2 and b[16] != 0
	var at = 20 if ver >= 2 else 16
	var offs = []
	for i in num_area:
		offs.append(b.decode_u32(at + i * 4))
	at += num_area * 4
	var layers = []
	for i in num_layer:
		var o = at + i * 28 # T2MKFILELAYER
		layers.append({"texture": b.decode_s32(o), "mask_size": b.decode_s32(o + 8), "axis": b[o + 12],
			"u_scale": b.decode_float(o + 16), "v_scale": b.decode_float(o + 20)})
	var areas = []
	var entry = 12 if ver >= 2 else 8
	for o in offs:
		var n = b.decode_s32(o)
		var area = []
		for k in n:
			var e = o + 4 + k * entry
			var li = b.decode_s32(e)
			var mask = PackedByteArray()
			if k > 0 and li >= 0 and li < layers.size():
				var size: int = layers[li]["mask_size"]
				var data_off = b.decode_u32(e + 4)
				if comp:
					mask = b.slice(data_off, data_off + b.decode_u32(e + 8)).decompress(size * size, FileAccess.COMPRESSION_DEFLATE)
				else:
					mask = b.slice(data_off, data_off + size * size)
			area.append({"layer": li, "mask": mask})
		areas.append(area)
	return {"layers": layers, "areas": areas}

# <sub>.t2lm -> [Image je Maskenbereich] (leer = keine Lightmap)
func read_lightmaps(path: String) -> Array:
	if not importer.files.file_exists(path):
		return []
	var b = importer.files.get_bytes(path)
	if b.size() < 16 or b.decode_u32(0) != T2LM_ID:
		return []
	var ver = b.decode_u32(4)
	var num = b.decode_s32(8)
	var size = b.decode_s32(12)
	var flags = 0
	var data_size = size * size * 3
	var at = 16
	if ver >= 2:
		flags = b.decode_u32(16)
		data_size = b.decode_s32(20)
		at = 24
	var out = []
	for i in num:
		var o = b.decode_u32(at + i * 4)
		var img = Image.new()
		if flags & T2LMFILE_DDS:
			if img.load_dds_from_buffer(b.slice(o, o + data_size)) != OK:
				img = null
		else:
			# Rohdaten 24 Bit (A3DTerrain2LoaderB::FillLightMap: B, G, R)
			var raw = b.slice(o, o + data_size)
			for p in range(0, raw.size() - 2, 3):
				var t = raw[p]
				raw[p] = raw[p + 2]
				raw[p + 2] = t
			img = Image.create_from_data(size, size, false, Image.FORMAT_RGB8, raw)
		out.append(img)
	return out


# ====================================================
# BAUEN
# ====================================================
# .trn2 -> Szene unter scene_path; {"scene"} oder {"error"}
func build(trn2_path: String, scene_path: String) -> Dictionary:
	var t = read_trn2(trn2_path)
	if t.has("error"):
		return t
	if not importer.save_resources:
		return _save_layout(trn2_path, scene_path, t)
	var dir = trn2_path.get_base_dir()
	var out_dir = scene_path.get_base_dir()
	var map_name: String = trn2_path.get_file().get_basename()
	var layer_array = _layer_texture_array(t)
	importer.save_resource(layer_array, out_dir.path_join(map_name + "_layers.res"))

	var root = Node3D.new()
	root.name = map_name
	root.set_meta("trn2_path", trn2_path)
	var terrain = Node3D.new()
	terrain.name = "Terrain"
	root.add_child(terrain)
	terrain.owner = root

	var bg: int = t["block_grid"]
	var num_vert = (bg + 1) * (bg + 1)
	var sub_blocks: int = t["sub_grid"] / bg # Blöcke je Seite einer Teilkarte
	var sub_masks: int = t["sub_grid"] / t["mask_grid"] # Maskenbereiche je Seite einer Teilkarte
	var mask_pitch: int = t["block_cols"] * bg / t["mask_grid"] # Maskenbereiche je Zeile der Map
	var area_rows: int = t["block_rows"] * bg / t["mask_grid"]
	var areas = 0
	for s in t["num_sub"]:
		var base = dir.path_join(t["subs"][s]["name"])
		var blocks = read_blocks(_find(base + ".t2bk"), num_vert)
		if blocks.has("error"):
			_warn(blocks["error"])
			continue
		var masks = read_masks(_find(base + ".t2mk"))
		if masks.has("error"):
			_warn(masks["error"])
			continue
		var lightmaps = read_lightmaps(_find(base + ".t2lm"))
		if lightmaps.is_empty():
			_warn(t["subs"][s]["name"] + ": keine Lightmap, Terrain ohne Licht")
		# Blöcke nach Zeile / Spalte in der Map
		var by_pos = {}
		for k in blocks:
			by_pos[Vector2i(blocks[k]["row"], blocks[k]["col"])] = blocks[k]
		var sub_row = s / t["sub_cols"]
		var sub_col = s % t["sub_cols"]
		for a in masks["areas"].size():
			var mr = sub_row * sub_masks + a / sub_masks # Zeile / Spalte des Bereichs in der Map
			var mc = sub_col * sub_masks + a % sub_masks
			var mesh = _area_mesh(t, by_pos, mr, mc)
			if mesh == null:
				continue
			mesh.surface_set_material(0, _area_material(t, masks, a, lightmaps[a] if a < lightmaps.size() else null, layer_array, t["subs"][s]["min_height"]))
			var index = mr * mask_pitch + mc
			if importer.save_resources:
				var save_err = importer.save_resource(mesh, out_dir.path_join("terrain/area_%03d.res" % index))
				if save_err != OK:
					root.free()
					return {"error": "Не удалось сохранить область рельефа %03d: %s" % [index, error_string(save_err)]}
			else:
				var mi = MeshInstance3D.new()
				mi.name = "Area_%03d" % index
				mi.mesh = mesh
				terrain.add_child(mi)
				mi.owner = root
			areas += 1
		if importer.progress_callback.is_valid():
			importer.progress_callback.call("Импорт рельефа: подкарта %d из %d, областей %d" % [s + 1, t["num_sub"], areas])
		await (Engine.get_main_loop() as SceneTree).process_frame
	if areas == 0:
		root.free()
		return {"error": trn2_path.get_file() + ": kein Maskenbereich lesbar"}
	var world = preload("angelica_world.gd").new(importer)
	var buildings = await preload("angelica_buildings.gd").new(importer).build(map_name, out_dir.path_join(map_name + "_buildings.scn"), world.building_files(trn2_path), _building_stream_config(t, mask_pitch, area_rows) if importer.save_resources else {})
	if importer.save_resources:
		root.set_script(StreamerScript)
		root.set_meta("terrain_dir", out_dir)
		root.set_meta("terrain_area_count", area_rows * mask_pitch)
		root.set_meta("terrain_area_columns", mask_pitch)
		root.set_meta("terrain_grid_size", t["grid_size"])
		root.set_meta("terrain_mask_grid", t["mask_grid"])
		root.set_meta("terrain_width", t["width"])
		root.set_meta("terrain_length", t["length"])
		root.set_meta("building_chunk_indices", buildings.get("chunks", PackedInt32Array()))
		var building_root = Node3D.new()
		building_root.name = "Buildings"
		root.add_child(building_root)
		building_root.owner = root
	# Gebäude als eigene (binäre) Szene, hier eingebunden; nur die, die <map>.ecwld / .ecbsd nennen
	if buildings.has("error"):
		_warn(buildings["error"])
	elif buildings.has("scene"):
		var inst = load(buildings["scene"]).instantiate()
		root.add_child(inst)
		inst.owner = root
	var objects = world.build(trn2_path, root, out_dir)
	var packed = PackedScene.new()
	var err = packed.pack(root)
	root.free()
	if err == OK:
		err = importer.save_resource(packed, scene_path)
	if err != OK:
		return {"error": "Speichern fehlgeschlagen (%s)" % error_string(err)}
	var out = {"scene": scene_path, "areas": areas, "buildings": buildings.get("count", 0)}
	out.merge(objects)
	out["unused_buildings"] = buildings.get("unused", 0)
	return out

func _building_stream_config(t: Dictionary, columns: int, rows: int) -> Dictionary:
	return {"columns": columns, "rows": rows, "cell_size": float(t["mask_grid"]) * float(t["grid_size"]), "width": float(t["width"]), "length": float(t["length"])}

func _save_layout(trn2_path: String, scene_path: String, t: Dictionary) -> Dictionary:
	var root = Node3D.new()
	root.name = trn2_path.get_file().get_basename()
	root.set_script(StreamerScript)
	root.set_meta("source_trn2", trn2_path)
	root.set_meta("terrain_area_count", int(t["block_rows"] * t["block_grid"] / t["mask_grid"]) * int(t["block_cols"] * t["block_grid"] / t["mask_grid"]))
	root.set_meta("terrain_area_columns", int(t["block_cols"] * t["block_grid"] / t["mask_grid"]))
	root.set_meta("terrain_grid_size", t["grid_size"])
	root.set_meta("terrain_mask_grid", t["mask_grid"])
	root.set_meta("terrain_width", t["width"])
	root.set_meta("terrain_length", t["length"])
	var terrain = Node3D.new()
	terrain.name = "Terrain"
	root.add_child(terrain)
	terrain.owner = root
	var buildings = Node3D.new()
	buildings.name = "Buildings"
	root.add_child(buildings)
	buildings.owner = root
	var objects = Node3D.new()
	objects.name = "Objects"
	root.add_child(objects)
	objects.owner = root
	var layout = ImmediateMesh.new()
	layout.surface_begin(Mesh.PRIMITIVE_LINES)
	var half_width = float(t["width"]) * 0.5
	var half_length = float(t["length"]) * 0.5
	layout.surface_add_vertex(Vector3(-half_width, 0.0, -half_length))
	layout.surface_add_vertex(Vector3(half_width, 0.0, -half_length))
	layout.surface_add_vertex(Vector3(half_width, 0.0, -half_length))
	layout.surface_add_vertex(Vector3(half_width, 0.0, half_length))
	layout.surface_add_vertex(Vector3(half_width, 0.0, half_length))
	layout.surface_add_vertex(Vector3(-half_width, 0.0, half_length))
	layout.surface_add_vertex(Vector3(-half_width, 0.0, half_length))
	layout.surface_add_vertex(Vector3(-half_width, 0.0, -half_length))
	layout.surface_end()
	var outline = MeshInstance3D.new()
	outline.name = "Границы карты"
	outline.mesh = layout
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.25, 0.8, 0.45)
	outline.material_override = material
	root.add_child(outline)
	outline.owner = root
	var packed = PackedScene.new()
	var err = packed.pack(root)
	root.free()
	if err == OK:
		err = importer.save_resource(packed, scene_path)
	if err != OK:
		return {"error": "Не удалось сохранить разметку карты: %s" % error_string(err)}
	return {"scene": scene_path, "areas": 0, "buildings": 0, "written": importer.written, "warnings": importer.warnings}

func read_area_data(trn2_path: String, t: Dictionary, index: int) -> Dictionary:
	var bg = int(t["block_grid"])
	var mask_grid = int(t["mask_grid"])
	var sub_masks = int(t["sub_grid"]) / mask_grid
	var columns = int(t["block_cols"]) * bg / mask_grid
	var row = index / columns
	var col = index % columns
	var sub_index = int(row / sub_masks) * int(t["sub_cols"]) + int(col / sub_masks)
	if sub_index < 0 or sub_index >= t["subs"].size():
		return {"error": "Неверный номер области рельефа: %d" % index}
	_runtime_sub_mutex.lock()
	var sub_data: Dictionary = _runtime_sub_cache.get(sub_index, {})
	_runtime_sub_mutex.unlock()
	if sub_data.is_empty():
		var base = trn2_path.get_base_dir().path_join(str(t["subs"][sub_index]["name"]))
		var num_vert = (bg + 1) * (bg + 1)
		sub_data = {"blocks": read_blocks(base + ".t2bk", num_vert), "masks": {}, "lightmaps": []}
		if not sub_data["blocks"].has("error"):
			sub_data["masks"] = read_masks(base + ".t2mk")
			if not sub_data["masks"].has("error"):
				sub_data["lightmaps"] = read_lightmaps(base + ".t2lm")
		_runtime_sub_mutex.lock()
		if _runtime_sub_cache.has(sub_index):
			sub_data = _runtime_sub_cache[sub_index]
		else:
			_runtime_sub_cache[sub_index] = sub_data
			_runtime_sub_order.append(sub_index)
			if _runtime_sub_order.size() > 4:
				_runtime_sub_cache.erase(_runtime_sub_order.pop_front())
		_runtime_sub_mutex.unlock()
	if sub_data["blocks"].has("error"):
		return sub_data["blocks"]
	if sub_data["masks"].has("error"):
		return sub_data["masks"]
	var local_area = (row % sub_masks) * sub_masks + col % sub_masks
	return {"index": index, "row": row, "col": col, "blocks": sub_data["blocks"], "masks": sub_data["masks"], "lightmap": sub_data["lightmaps"][local_area] if local_area < sub_data["lightmaps"].size() else null,
		"area": local_area, "min_height": float(t["subs"][sub_index]["min_height"])}

func build_area_from_data(t: Dictionary, data: Dictionary, layer_array: Texture2DArray) -> Mesh:
	if data.has("error"):
		return null
	var by_pos = {}
	for block in data["blocks"].values():
		by_pos[Vector2i(block["row"], block["col"])] = block
	var mesh = _area_mesh(t, by_pos, int(data["row"]), int(data["col"]))
	if mesh == null:
		return null
	var masks: Dictionary = data["masks"]
	mesh.surface_set_material(0, _area_material(t, masks, int(data["area"]), data["lightmap"], layer_array, float(data["min_height"])))
	return mesh

# Teildatei ohne Groß/Klein-Unterscheidung
func _find(path: String) -> String:
	var p = importer.files.resolve(path.get_file(), path.get_base_dir())
	return p if p != "" else path

# Raster eines Maskenbereichs (mask_grid + 1)² aus seinen Blöcken
func _area_mesh(t: Dictionary, by_pos: Dictionary, mr: int, mc: int) -> ArrayMesh:
	var bg: int = t["block_grid"]
	var mb: int = t["mask_block"]
	var n: int = t["mask_grid"]
	var g: float = t["grid_size"]
	var left: float = -t["width"] * 0.5
	var top: float = t["length"] * 0.5
	# Blöcke des Bereichs, fehlende -> kein Mesh
	var grid = []
	for bi in mb:
		var line = []
		for bj in mb:
			var blk = by_pos.get(Vector2i(mr * mb + bi, mc * mb + bj))
			if blk == null:
				return null
			line.append(blk)
		grid.append(line)
	var verts = PackedVector3Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	verts.resize((n + 1) * (n + 1))
	normals.resize(verts.size())
	uvs.resize(verts.size())
	var k = 0
	for i in n + 1:
		var bi = mini(i / bg, mb - 1)
		var li = i - bi * bg
		var z = top - (mr * n + i) * g
		for j in n + 1:
			var bj = mini(j / bg, mb - 1)
			var lj = j - bj * bg
			var blk = grid[bi][bj]
			var v = li * (bg + 1) + lj
			verts[k] = Vector3(left + (mc * n + j) * g, blk["heights"][v], z)
			normals[k] = blk["normals"][v]
			uvs[k] = Vector2(float(j) / n, float(i) / n)
			k += 1
	# Godot: Vorderseite im Uhrzeigersinn (von oben gesehen)
	var indices = PackedInt32Array()
	indices.resize(n * n * 6)
	var c = 0
	for i in n:
		for j in n:
			if grid[mini(i / bg, mb - 1)][mini(j / bg, mb - 1)]["flags"] & T2BKFLAG_NORENDER:
				continue
			var a = i * (n + 1) + j
			var b = a + 1
			var d = a + n + 1
			indices[c] = a
			indices[c + 1] = d
			indices[c + 2] = b
			indices[c + 3] = b
			indices[c + 4] = d
			indices[c + 5] = d + 1
			c += 6
	if c == 0:
		return null
	indices.resize(c)
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _area_material(t: Dictionary, masks: Dictionary, a: int, lightmap: Image, layer_array: Texture2DArray, min_height: float) -> ShaderMaterial:
	var area: Array = masks["areas"][a]
	if area.size() > MAX_LAYERS:
		_warn("Maskenbereich mit %d Ebenen, nur %d genutzt" % [area.size(), MAX_LAYERS])
	var count = mini(area.size(), MAX_LAYERS)
	var index = PackedInt32Array()
	var uv = PackedVector4Array()
	var mask_images = []
	for i in MAX_LAYERS:
		var li = area[i]["layer"] if i < count else -1
		var layer = masks["layers"][li] if li >= 0 and li < masks["layers"].size() else {}
		index.append(clampi(int(layer.get("texture", 0)), 0, maxi(0, t["num_texture"] - 1)))
		uv.append(Vector4(layer.get("u_scale", 1.0), layer.get("v_scale", 1.0), layer.get("axis", 1), 0.0))
		if i > 0 and i < count:
			var size: int = layer.get("mask_size", 0)
			var data: PackedByteArray = area[i]["mask"]
			var img: Image
			if size > 0 and data.size() == size * size:
				img = Image.create_from_data(size, size, false, Image.FORMAT_L8, data)
			else:
				img = Image.create(maxi(size, 4), maxi(size, 4), false, Image.FORMAT_L8)
			mask_images.append(img)
	# Alle Masken gleich groß (A3DTerrain2LoaderB: eine Maskengröße je Map)
	if mask_images.is_empty():
		mask_images.append(Image.create(4, 4, false, Image.FORMAT_L8))
	var mask_size = mask_images[0].get_size()
	for img in mask_images:
		if img.get_size() != mask_size:
			img.resize(mask_size.x, mask_size.y)
		img.generate_mipmaps()
	var mask_array = TextureArray.new()
	mask_array.layer_images = mask_images

	var mat = ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("layer_textures", layer_array)
	mat.set_shader_parameter("layer_masks", mask_array)
	mat.set_shader_parameter("layer_count", count)
	mat.set_shader_parameter("layer_index", index)
	mat.set_shader_parameter("layer_uv", uv)
	mat.set_shader_parameter("min_height", min_height)
	if lightmap != null and not lightmap.is_empty():
		if lightmap.is_compressed():
			lightmap.decompress()
		lightmap.generate_mipmaps()
		lightmap.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
		mat.set_shader_parameter("lightmap", ImageTexture.create_from_image(lightmap))
	else:
		mat.set_shader_parameter("use_lightmap", false)
	return mat

# Alle Bodentexturen der Map als ein Array: gleiche Größe (größte, höchstens MAX_TEXTURE_SIZE),
# RGB mit Mipmaps, DXT1. Das Alpha der Bodentexturen (Glanz) bleibt ungenutzt.
func _layer_texture_array(t: Dictionary) -> Texture2DArray:
	var images = []
	var size = 64
	var builder = importer.new_builder()
	for name in t["textures"]:
		var src = importer.find_game_file(name)
		var img: Image = builder.image_file(src) if src != "" else null
		if img == null or img.is_empty():
			_warn("Bodentextur " + name + " nicht gefunden")
			img = Image.create(64, 64, false, Image.FORMAT_RGB8)
			img.fill(Color(0.5, 0.5, 0.5))
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGB8)
		size = maxi(size, mini(MAX_TEXTURE_SIZE, maxi(img.get_width(), img.get_height())))
		images.append(img)
	if images.is_empty():
		var img = Image.create(64, 64, false, Image.FORMAT_RGB8)
		img.fill(Color(0.5, 0.5, 0.5))
		images.append(img)
	size = nearest_po2(size)
	for img in images:
		if img.get_width() != size or img.get_height() != size:
			img.resize(size, size, Image.INTERPOLATE_CUBIC)
		img.generate_mipmaps()
		img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
	# Das Array braucht ein Format für alle: scheitert das Packen einmal, alle ungepackt
	for img in images:
		if img.get_format() != images[0].get_format():
			for other in images:
				if other.is_compressed():
					other.decompress()
				other.convert(Image.FORMAT_RGB8)
			break
	var arr = TextureArray.new()
	arr.layer_images = images
	return arr

func build_layer_texture_array_async(t: Dictionary) -> Texture2DArray:
	var images = []
	var size = 64
	var builder = importer.new_builder()
	for name in t["textures"]:
		var src = importer.find_game_file(name)
		var img: Image = builder.image_file(src) if src != "" else null
		if img == null or img.is_empty():
			_warn("Bodentextur " + name + " nicht gefunden")
			img = Image.create(64, 64, false, Image.FORMAT_RGB8)
			img.fill(Color(0.5, 0.5, 0.5))
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGB8)
		size = maxi(size, mini(MAX_TEXTURE_SIZE, maxi(img.get_width(), img.get_height())))
		images.append(img)
		await (Engine.get_main_loop() as SceneTree).process_frame
	if images.is_empty():
		var fallback = Image.create(64, 64, false, Image.FORMAT_RGB8)
		fallback.fill(Color(0.5, 0.5, 0.5))
		images.append(fallback)
	size = nearest_po2(size)
	for img in images:
		if img.get_width() != size or img.get_height() != size:
			img.resize(size, size, Image.INTERPOLATE_CUBIC)
		img.generate_mipmaps()
		img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
		await (Engine.get_main_loop() as SceneTree).process_frame
	for img in images:
		if img.get_format() != images[0].get_format():
			for other in images:
				if other.is_compressed():
					other.decompress()
				other.convert(Image.FORMAT_RGB8)
			break
	importer.take_builder(builder)
	var array = TextureArray.new()
	array.layer_images = images
	return array
