@tool
extends RefCounted

# ====================================================
# Objekte und Wasser einer Map (maps\<map>\<map>.ecwld, CECWorld / ESWorld) -> Godot.
# .ecwld Version 12–14 (Perfect World / Forsaken World; der ESWorldLoader der Quellen liest erst ab 20, das
# Format hier ist aus den Daten bestimmt): Kopf ESWorldFileHeader (116 Bytes), iNumBlock
# Block-Offsets (DWORD), je Block (Reihenfolge der Blöcke beliebig):
#   WORD Zeile, WORD Spalte, 10 Zähler: Bäume, Wasser, Gras, Gebäude, Box-Bereiche, Effekte,
#   ECModelle, Kleintiere, Bezier-Routen, Sounds (ab 20 dazu Spiegel, Kollision, Laderadius)
#   Bäume, Wasser, Gebäude, Box-Bereiche, Gras: ECWDFILEDATAREF (Export-ID, Offset in der .ecbsd)
#   Effekte:   ECWDFILEEFFECT12 (60 Bytes) + GfxPath (AString, relativ zu gfx\)
#   ECModelle: ECWDFILEECMODEL (40 Bytes) + ECM-Pfad (relativ zum Spielordner) + Aktion
#   Kleintiere, Bezier-Routen: Referenzen
#   Sounds:    Export-ID, Position, Min- / Max-Abstand, 0, Tageszeit (32 Bytes; v14: + 20 Bytes
#              Kegel o.ä., ungenutzt) + Pfad (relativ zu sfx\)
# Ein Objekt über mehreren Blöcken steht in jedem: es zählt einmal (Export-ID).
# Gebäude: Referenz -> .ecbsd ECBSDFILEORNAMENT (Pos, Dir, Up, 3 Flags, 1 Byte, Datei relativ zu
# litmodels\<map>\). Das Spiel lädt nur diese; im Ordner liegen oft weitere, ungenutzte .bmd
# (z.B. Hüllen ganzer Häuserzeilen), die angelica_buildings.gd damit auslässt.
# Lage: TransformMatrix(Dir, Up, Pos) wie die Gebäude, Effekte dazu SetScale(fScale).
# Tageszeit der Effekte und Sounds (iValidTime): 0 Tag, 1 Nacht, 2 immer; angelica_world_objects.gd
# schaltet danach um. nShowType der ECModelle bedeutet in diesen Versionen nichts Verlässliches
# (Tiere und Arbeiter einer Stadt "nur nachts", ganze Maps "nur tags", teils Zufallswerte): die
# Modelle sind immer da, der Wert steht nur als Meta "show_type" daneben.
# Wasser (ATerrainWaterLoader): Referenz -> .ecbsd ("MOXB" + ESBSDFileHeader, Dateinamen der
# Teilkarten) {Teilkarte, Datenindex} -> BSData\<n>.dat (Offset-Tabelle am Dateiende) ->
# A3DWaterArea::Load ab 0x10002000: ID, Farbe, Höhe, Randbreite, Breite, Länge, Rastergröße,
# Mitte, [bMinorWater], Flag je Rasterfeld (WATERGRID_VISIBLE). Ecke links oben =
# Mitte - (Breite, -Länge) * Raster / 2, Zeilen laufen nach -Z (A3DWaterMeshBlock::Init).
# Licht: der Standard-Box-Bereich (ECBSDFILEBOXAREA mit iDefArea, Referenz wie die Gebäude) gibt
# Sonnen-Richtung und -Farbe und das Umgebungslicht vor, je für Tag und Nacht; Angelica beleuchtet
# damit Modelle (ECModelle, Modelle in GFX). -> "Sun" (DirectionalLight3D) und "Environment"
# (Umgebungslicht, Hintergrund = Nebelfarbe). Terrain, Gebäude, Wasser und Effekte tragen ihr
# Licht selbst (unshaded).
# Spawns des Spielservers (NPCs, Monster, Sammelpunkte) als Marker: Server/spawn_builder.gd; die
# Modelle der NPCs und Monster darin werden mit importiert (für den Client, Meta "models").
# Bäume, Gras, Kleintiere, Nebel und weitere Box-Bereiche sowie Bezier-Routen fehlen noch.
# ====================================================

const ECWD_ID = 0x45435744 # ('E'<<24) | ('C'<<16) | ('W'<<8) | 'D'
const BSDF_ID = 0x42534446 # ('B'<<24) | ('S'<<16) | ('D'<<8) | 'F'
const HEADER_SIZE = 116
const BSD_HEADER_END = 76 # "MOXB" + ESBSDFileHeader (72)
const BLOCK_INFO_SIZE = 44
const BOXAREA_LIGHT_END = 144 # ECBSDFILEBOXAREA bis dwDirLtCol_n
const EFFECT_SIZE = 60 # ECWDFILEEFFECT12 (mit Füllbytes)
const ECMODEL_SIZE = 40 # ECWDFILEECMODEL in PW 155
const SOUND_SIZE = {12: 32, 13: 32, 14: 52} # je Version, zugleich die lesbaren Versionen
const WATER_MIN_VERSION = 0x10002000
const WATER_MINOR_VERSION = 0x10003000
const WATERGRID_VISIBLE = 0x01
const WATER_NORMAL_MAP = "textures/water/waternormal/water_normal00.dds"
const WATER_SHADER = preload("angelica_water.gdshader")
const OBJECTS_SCRIPT = preload("angelica_world_objects.gd")
const MODEL_SCRIPT = preload("angelica_world_model.gd")
const SpawnBuilder = preload("../Server/spawn_builder.gd")
const Buildings = preload("angelica_buildings.gd")

var importer # ecm_importer.gd
var _sounds = {} # Quelle -> AudioStream (null = fehlt)
var _world = {} # read_world der Map samt "bsd" (Bytes der .ecbsd), einmal je Map gelesen
var _runtime_water_areas = []
var _runtime_chunks = {}


func _init(p_importer) -> void:
	importer = p_importer

func _warn(msg: String) -> void:
	importer.warn(msg)


# ====================================================
# LESEN
# ====================================================
# .ecwld -> {version, effects: [{id, path, scale, pos, dir, up, speed, valid_time, alpha}],
# models: [{id, path, action, pos, dir, up, show_type}], sounds: [{id, path, pos, min_dist,
# max_dist, valid_time}], water / ornaments / boxes: {Export-ID: Offset in der .ecbsd}} oder {"error"}
func read_world(path: String) -> Dictionary:
	var b = importer.files.get_bytes(path)
	if b.size() < HEADER_SIZE or b.decode_u32(0) != ECWD_ID:
		return {"error": path.get_file() + ": keine Szenen-Datei"}
	var ver = b.decode_u32(4)
	if not SOUND_SIZE.has(ver):
		return {"error": path.get_file() + ": Version %d wird nicht unterstützt (12–14)" % ver}
	var num_block = b.decode_s32(24)
	if HEADER_SIZE + num_block * 4 > b.size():
		return {"error": path.get_file() + ": Block-Tabelle abgeschnitten"}
	var out = {"version": ver, "effects": [], "models": [], "sounds": [], "water": {}, "ornaments": {}, "boxes": {}}
	var seen = {}
	for i in num_block:
		var p = b.decode_u32(HEADER_SIZE + i * 4)
		if p + BLOCK_INFO_SIZE > b.size():
			return {"error": path.get_file() + ": Block %d außerhalb der Datei" % i}
		var n = []
		for k in 10:
			n.append(b.decode_s32(p + 4 + k * 4))
		p += BLOCK_INFO_SIZE + (16 if ver >= 5 else 8) * n[0]
		for k in n[1]:
			out["water"][b.decode_u32(p)] = b.decode_u32(p + 4)
			p += 8
		for k in n[3] + n[4] + n[2]: # Gebäude, Box-Bereiche, Gras
			if k < n[3]:
				out["ornaments"][b.decode_u32(p)] = b.decode_u32(p + 4)
			elif k < n[3] + n[4]:
				out["boxes"][b.decode_u32(p)] = b.decode_u32(p + 4)
			p += 8
		var at = [0]
		for k in n[5]:
			if p + EFFECT_SIZE + 4 > b.size():
				return {"error": path.get_file() + ": Block %d abgeschnitten" % i}
			var e = {"id": b.decode_u32(p), "scale": b.decode_float(p + 4), "pos": _vec(b, p + 8),
				"dir": _vec(b, p + 20), "up": _vec(b, p + 32), "speed": b.decode_float(p + 44),
				"valid_time": _valid_time(b.decode_s32(p + 48)), "alpha": b.decode_float(p + 52)}
			at[0] = p + EFFECT_SIZE
			e["path"] = _string(b, at)
			p = at[0]
			if not seen.has("e%d" % e["id"]):
				seen["e%d" % e["id"]] = true
				out["effects"].append(e)
		for k in n[6]:
			if p + ECMODEL_SIZE + 8 > b.size():
				return {"error": path.get_file() + ": Block %d abgeschnitten" % i}
			var m = {"id": b.decode_u32(p), "pos": _vec(b, p + 4), "dir": _vec(b, p + 16), "up": _vec(b, p + 28), "show_type": -1}
			at[0] = p + ECMODEL_SIZE
			m["path"] = _string(b, at)
			m["action"] = _string(b, at)
			p = at[0]
			if not seen.has("m%d" % m["id"]):
				seen["m%d" % m["id"]] = true
				out["models"].append(m)
		p += 8 * (n[7] + n[8])
		for k in n[9]:
			if p + SOUND_SIZE[ver] + 4 > b.size():
				return {"error": path.get_file() + ": Block %d abgeschnitten" % i}
			var s = {"id": b.decode_u32(p), "pos": _vec(b, p + 4), "min_dist": b.decode_float(p + 16),
				"max_dist": b.decode_float(p + 20), "valid_time": _valid_time(b.decode_s32(p + 28))}
			at[0] = p + SOUND_SIZE[ver]
			s["path"] = _string(b, at)
			p = at[0]
			if not seen.has("s%d" % s["id"]):
				seen["s%d" % s["id"]] = true
				out["sounds"].append(s)
	return out

# Wasserflächen der Referenzen aus read_world -> [{id, height, width, length, grid, center,
# flags}] (Flags je Rasterfeld, Zeile für Zeile)
func read_water(bsd_path: String, b: PackedByteArray, refs: Dictionary) -> Array:
	var areas = []
	if refs.is_empty() or b.is_empty():
		return areas
	var names = []
	var at = [BSD_HEADER_END]
	for i in b.decode_s32(12):
		names.append(_string(b, at))
	var dats = {}
	for id in refs:
		var off: int = refs[id]
		if off + 8 > b.size():
			continue
		var sub = b.decode_s32(off)
		var index = b.decode_s32(off + 4)
		if sub < 0 or sub >= names.size():
			continue
		if not dats.has(sub):
			dats[sub] = _read_dat(bsd_path.get_base_dir(), names[sub])
		var dat: Dictionary = dats[sub]
		if dat.is_empty() or index < 0 or index >= dat["offsets"].size():
			continue
		var x: PackedByteArray = dat["bytes"]
		var o: int = dat["offsets"][index]
		var ver = x.decode_u32(o)
		if ver < WATER_MIN_VERSION:
			_warn("Wasser %d: Version 0x%x wird nicht unterstützt" % [id, ver])
			continue
		var w = x.decode_s32(o + 20)
		var l = x.decode_s32(o + 24)
		var q = o + 44 + (1 if ver >= WATER_MINOR_VERSION else 0)
		if w <= 0 or l <= 0 or q + w * l > x.size():
			continue
		areas.append({"id": x.decode_u32(o + 4), "height": x.decode_float(o + 12), "width": w, "length": l,
			"grid": x.decode_float(o + 28), "center": _vec(x, o + 32), "flags": x.slice(q, q + w * l)})
	return areas

# Gebäude der Map (Pfade relativ zu litmodels\<map>\), null = keine .ecwld / .ecbsd lesbar
func building_files(trn2_path: String) -> Variant:
	var w = _read(trn2_path)
	if w.has("error") or w["bsd"].is_empty():
		return null
	var b: PackedByteArray = w["bsd"]
	var out = []
	for id in w["ornaments"]:
		var at = [w["ornaments"][id] + 40]
		if at[0] + 4 <= b.size():
			out.append(_string(b, at))
	return out

# .ecwld und .ecbsd der Map einmal lesen: read_world + "bsd" (leer, wenn sie fehlt)
func _read(trn2_path: String) -> Dictionary:
	if not _world.is_empty():
		return _world
	var dir = trn2_path.get_base_dir()
	var map_name = trn2_path.get_file().get_basename()
	var wld_path = importer.files.resolve(map_name + ".ecwld", dir)
	if wld_path == "":
		_world = {"error": ""}
		return _world
	_world = read_world(wld_path)
	if _world.has("error"):
		_warn(_world["error"])
		return _world
	_world["bsd_path"] = importer.files.resolve(map_name + ".ecbsd", dir)
	var b = importer.files.get_bytes(_world["bsd_path"]) if _world["bsd_path"] != "" else PackedByteArray()
	if b.size() < BSD_HEADER_END or b.slice(0, 4).get_string_from_ascii() != "MOXB" or b.decode_u32(4) != BSDF_ID:
		_warn(map_name + ".ecbsd fehlt oder ist keine Block-Datei: Wasser fehlt, alle Gebäude im Ordner")
		b = PackedByteArray()
	_world["bsd"] = b
	return _world

# BSData\<n>.dat: "MOXB", Version, Kompression, Daten, Offset-Tabelle, Anzahl
func _read_dat(dir: String, name: String) -> Dictionary:
	var path = importer.files.resolve(name, dir)
	if path == "":
		_warn(name + " nicht gefunden, Wasser fehlt")
		return {}
	var x = importer.files.get_bytes(path)
	if x.size() < 16:
		return {}
	var n = x.decode_u32(x.size() - 4)
	if n * 4 + 4 > x.size():
		return {}
	var offsets = []
	for i in n:
		offsets.append(x.decode_u32(x.size() - 4 - (n - i) * 4))
	return {"bytes": x, "offsets": offsets}

func _vec(b: PackedByteArray, p: int) -> Vector3:
	return Vector3(b.decode_float(p), b.decode_float(p + 4), b.decode_float(p + 8))

# AString: int Länge + Bytes (GBK)
func _string(b: PackedByteArray, at: Array) -> String:
	var n = b.decode_s32(at[0])
	var s = importer.files.decode_gbk(b.slice(at[0] + 4, at[0] + 4 + n))
	at[0] += 4 + n
	return s

func _valid_time(v: int) -> int:
	return v if v >= 0 and v <= 2 else 2


# ====================================================
# BAUEN
# ====================================================
# Wasser und Objekte der Map (trn2_path) unter root, Wasser-Meshes nach out_dir/water/.
# -> {"effects", "models", "sounds", "water", "light", "spawns"} (Anzahlen)
func build(trn2_path: String, root: Node3D, out_dir: String) -> Dictionary:
	var counts = {"effects": 0, "models": 0, "sounds": 0, "water": 0}
	var w = _read(trn2_path)
	if w.has("error"):
		return counts
	counts["water"] = _build_water(read_water(w["bsd_path"], w["bsd"], w["water"]), root, out_dir)
	counts["light"] = _build_light(w, root)
	var objects = Node3D.new()
	objects.name = "Objects"
	objects.set_script(OBJECTS_SCRIPT)
	root.add_child(objects)
	objects.owner = root
	counts["effects"] = _build_effects(w["effects"], _group(objects, "Effects", root), root)
	counts["models"] = _build_models(w["models"], _group(objects, "Models", root), root)
	counts["sounds"] = _build_sounds(w["sounds"], _group(objects, "Sounds", root), root)
	objects.apply_time()
	var spawns = SpawnBuilder.new()
	counts["spawns"] = spawns.build(trn2_path.get_file().get_basename(), root, importer.files)
	var spawn_node = root.get_node_or_null(SpawnBuilder.NODE_NAME)
	if spawn_node != null:
		counts["spawn_models"] = spawns.import_models(spawn_node, importer)
	for msg in spawns.warnings:
		importer.warn(msg)
	return counts

func build_runtime_manifest(columns: int, rows: int, cell_size: float, width: float, length: float) -> void:
	_runtime_chunks.clear()
	if _world.is_empty() or _world.has("error") or cell_size <= 0.0:
		return
	var processed = 0
	for kind in ["effects", "models", "sounds"]:
		for entry in _world[kind]:
			var pos: Vector3 = entry["pos"]
			var col = clampi(int(floor((pos.x + width * 0.5) / cell_size)), 0, columns - 1)
			var row = clampi(int(floor((length * 0.5 - pos.z) / cell_size)), 0, rows - 1)
			var index = row * columns + col
			if not _runtime_chunks.has(index):
				_runtime_chunks[index] = {"effects": [], "models": [], "sounds": [], "water": []}
			_runtime_chunks[index][kind].append(entry)
			processed += 1
			if processed % 512 == 0:
				await (Engine.get_main_loop() as SceneTree).process_frame
	_runtime_water_areas = read_water(_world["bsd_path"], _world["bsd"], _world["water"])
	for area in _runtime_water_areas:
		var center: Vector3 = area["center"]
		var col = clampi(int(floor((center.x + width * 0.5) / cell_size)), 0, columns - 1)
		var row = clampi(int(floor((length * 0.5 - center.z) / cell_size)), 0, rows - 1)
		var index = row * columns + col
		if not _runtime_chunks.has(index):
			_runtime_chunks[index] = {"effects": [], "models": [], "sounds": [], "water": []}
		_runtime_chunks[index]["water"].append(area)

func build_runtime_chunk(index: int, root: Node3D) -> void:
	var w = _world
	if w.is_empty() or w.has("error"):
		return
	var chunk: Dictionary = _runtime_chunks.get(index, {"effects": [], "models": [], "sounds": [], "water": []})
	var objects = Node3D.new()
	objects.name = "Objects"
	objects.set_script(OBJECTS_SCRIPT)
	root.add_child(objects)
	objects.owner = root
	var effects = _group(objects, "Effects", root)
	var models = _group(objects, "Models", root)
	var sounds = _group(objects, "Sounds", root)
	var effect_count = 0
	for entry in chunk["effects"]:
		effect_count += _build_effects([entry], effects, root)
		if effect_count % 2 == 0:
			await (Engine.get_main_loop() as SceneTree).process_frame
	var model_count = 0
	for entry in chunk["models"]:
		model_count += _build_models([entry], models, root)
		if model_count % 2 == 0:
			await (Engine.get_main_loop() as SceneTree).process_frame
	var sound_count = 0
	for entry in chunk["sounds"]:
		sound_count += _build_sounds([entry], sounds, root)
		if sound_count % 2 == 0:
			await (Engine.get_main_loop() as SceneTree).process_frame
	for area in chunk["water"]:
		_build_water([area], root, "")
		await (Engine.get_main_loop() as SceneTree).process_frame
	objects.apply_time()


# Nur das Licht ("Sun", "Environment") der Map unter root bauen, z.B. zur Laufzeit für eine Map,
# die vor dem Licht-Import importiert wurde -> false, wenn die Daten fehlen
func build_light(trn2_path: String, root: Node3D) -> bool:
	var w = _read(trn2_path)
	return not w.has("error") and not w["bsd"].is_empty() and _build_light(w, root)

# Sonne und Umgebungslicht aus dem ersten Standard-Box-Bereich, Nachtwerte als Meta
# (angelica_world_objects.gd schaltet um). Layout bis zum Licht wie ECBSDFILEBOXAREA20:
# iDefArea, Flags, Pos, Ext, 3 Achsen, Nebel (Start, Ende, Dichte, Farbe), Unterwasser-Nebel,
# Nacht-Nebel, vLightDir (116), dwAmbient, dwDirLtCol, dwAmbient_n, dwDirLtCol_n (128 - 143)
func _build_light(w: Dictionary, root: Node3D) -> bool:
	var b: PackedByteArray = w["bsd"]
	for id in w["boxes"]:
		var off: int = w["boxes"][id]
		if off + BOXAREA_LIGHT_END > b.size() or b.decode_s32(off) == 0:
			continue
		var dir = _vec(b, off + 116)
		if dir.length() < 0.000001:
			continue
		dir = dir.normalized()
		var sun = DirectionalLight3D.new()
		sun.name = "Sun"
		sun.transform = Transform3D(Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD), Vector3.ZERO)
		sun.light_color = _rgb(b.decode_u32(off + 132))
		sun.set_meta("day_color", sun.light_color)
		sun.set_meta("night_color", _rgb(b.decode_u32(off + 140)))
		root.add_child(sun)
		sun.owner = root
		var env = Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = _rgb(b.decode_u32(off + 80))
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = _rgb(b.decode_u32(off + 128))
		var we = WorldEnvironment.new()
		we.name = "Environment"
		we.environment = env
		we.set_meta("day_ambient", env.ambient_light_color)
		we.set_meta("night_ambient", _rgb(b.decode_u32(off + 136)))
		we.set_meta("day_background", env.background_color)
		we.set_meta("night_background", _rgb(b.decode_u32(off + 112)))
		root.add_child(we)
		we.owner = root
		return true
	return false

# A3DCOLOR (ARGB) -> Farbe ohne Alpha
static func _rgb(c: int) -> Color:
	return Color8((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)

func _group(parent: Node3D, name: String, root: Node3D) -> Node3D:
	var g = Node3D.new()
	g.name = name
	parent.add_child(g)
	g.owner = root
	return g

# Effekte als Instanzen der importierten .gfx (eine Szene je Datei)
func _build_effects(list: Array, parent: Node3D, root: Node3D) -> int:
	var count = 0
	for e in list:
		var scene = importer.source_gfx_scene(e["path"])
		if scene == null:
			continue
		# Mit Instanz-Zustand: gespeichert wird nur, was von der GFX-Szene abweicht
		var inst = scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		# Die Wurzel trägt DefaultScale als Scale, SetScale kommt dazu
		var s: Vector3 = inst.scale if inst is Node3D else Vector3.ONE
		inst.transform = Buildings.transform_of(e["dir"], e["up"], e["pos"], s * e["scale"])
		inst.name = "%s_%d" % [importer._node_name(e["path"].replace("\\", "/").get_file().get_basename()), e["id"]]
		if "Play_Speed" in inst:
			inst.Play_Speed = e["speed"]
		if "Alpha" in inst:
			inst.Alpha = e["alpha"]
		inst.set_meta("valid_time", e["valid_time"])
		parent.add_child(inst)
		inst.owner = root
		count += 1
	return count

# ECModelle: Szene der .ecm, gespielt mit der Aktion aus der Map (angelica_world_model.gd)
func _build_models(list: Array, parent: Node3D, root: Node3D) -> int:
	var count = 0
	var actions = {}
	for m in list:
		var src = importer.source_ecm(m["path"])
		if src["scene"] == null:
			continue
		if not actions.has(src["ecm"]):
			actions[src["ecm"]] = importer.read_ecm(src["ecm"]).get("actions", [])
		var node = Node3D.new()
		node.set_script(MODEL_SCRIPT)
		node.name = "%s_%d" % [importer._node_name(src["ecm"].get_file().get_basename()), m["id"]]
		node.transform = Buildings.transform_of(m["dir"], m["up"], m["pos"], Vector3.ONE)
		node.Action_Name = m["action"]
		for a in actions[src["ecm"]]:
			if a["name"] == m["action"]:
				node.Base_Actions = PackedStringArray(a["base"])
		node.Model_Scene = src["scene"]
		node.set_meta("valid_time", 2)
		node.set_meta("show_type", m["show_type"])
		parent.add_child(node)
		node.owner = root
		count += 1
	return count

# Sounds (Ambience) als AudioStreamPlayer3D: Abstand bis fMinDist voll, dann 1 / Abstand
func _build_sounds(list: Array, parent: Node3D, root: Node3D) -> int:
	var count = 0
	for s in list:
		var stream = _sound(s["path"])
		if stream == null:
			continue
		var p = AudioStreamPlayer3D.new()
		p.name = "%s_%d" % [importer._node_name(s["path"].replace("\\", "/").get_file().get_basename()), s["id"]]
		p.position = s["pos"]
		p.stream = stream
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.unit_size = maxf(s["min_dist"], 0.1)
		p.max_distance = maxf(s["max_dist"], 0.0)
		p.autoplay = true
		p.set_meta("valid_time", s["valid_time"])
		parent.add_child(p)
		p.owner = root
		count += 1
	return count

# Pfad relativ zu sfx\ -> AudioStreamWAV (endlos), gespeichert als .res neben den anderen Importen
func _sound(rel: String) -> AudioStream:
	var src = importer.find_game_file("sfx/" + rel)
	if _sounds.has(src):
		return _sounds[src]
	var stream: AudioStream = null
	if src == "":
		_warn("Sound sfx\\" + rel + " nicht in den Spieldaten")
	elif src.get_extension().to_lower() != "wav":
		_warn("Sound " + rel + ": nur .wav wird unterstützt")
	else:
		stream = AudioStreamWAV.load_from_buffer(importer.wav_bytes(src), {"edit/loop_mode": 2}) # 2 = vorwärts
		if stream != null:
			stream.loop_end = roundi(stream.get_length() * stream.mix_rate)
		if stream == null:
			_warn("Sound " + rel + " nicht lesbar")
		elif importer.save_resource(stream, importer.out_path(src, ".res")) != OK:
			_warn("Sound " + rel + " nicht gespeichert")
			stream = null
	_sounds[src] = stream
	return stream

# Je Wasserfläche ein Mesh aus den sichtbaren Rasterfeldern (ein Material für alle)
func _build_water(areas: Array, root: Node3D, out_dir: String) -> int:
	if areas.is_empty():
		return 0
	var water = Node3D.new()
	water.name = "Water"
	root.add_child(water)
	water.owner = root
	var mat = ShaderMaterial.new()
	mat.shader = WATER_SHADER
	var src = importer.find_game_file(WATER_NORMAL_MAP)
	if src == "":
		_warn("Wasser-Normalmap " + WATER_NORMAL_MAP + " nicht in den Spieldaten")
	else:
		var builder = importer.new_builder()
		var tex = builder.texture_file(src, "Wasser-Normalmap")
		importer.take_builder(builder)
		mat.set_shader_parameter("normal_map", tex)
	var count = 0
	for a in areas:
		var mesh = _water_mesh(a)
		if mesh == null:
			continue
		mesh.surface_set_material(0, mat)
		var name = "water_%d_%d" % [count, a["id"]]
		importer.save_resource(mesh, out_dir.path_join("water/" + name + ".res"))
		var mi = MeshInstance3D.new()
		mi.name = name
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		water.add_child(mi)
		mi.owner = root
		count += 1
	return count

func _water_mesh(a: Dictionary) -> ArrayMesh:
	var w: int = a["width"]
	var l: int = a["length"]
	var g: float = a["grid"]
	var c: Vector3 = a["center"]
	var org = Vector3(c.x - g * w * 0.5, a["height"], c.z + g * l * 0.5)
	var verts = PackedVector3Array()
	var normals = PackedVector3Array()
	for y in l + 1:
		for x in w + 1:
			verts.append(org + Vector3(x * g, 0.0, -y * g))
			normals.append(Vector3.UP)
	var indices = PackedInt32Array()
	var flags: PackedByteArray = a["flags"]
	for y in l:
		for x in w:
			if flags[y * w + x] & WATERGRID_VISIBLE == 0:
				continue
			var v = y * (w + 1) + x
			indices.append_array([v, v + w + 1, v + 1, v + 1, v + w + 1, v + w + 2]) # von oben im Uhrzeigersinn
	if indices.is_empty():
		return null
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
