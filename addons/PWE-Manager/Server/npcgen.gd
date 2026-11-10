@tool
extends RefCounted

# ====================================================
# Spawn-Datei des Spielservers (config\<Ordner>\npcgen.data, CNPCGenMan, Versionen 4 - 23).
# Aufbau (alles little endian, ohne Füllbytes):
#   Version, Kopf (Anzahl Gebiete, Sammelgebiete, dyn. Objekte, Steuerungen, Flugbereiche;
#   v16 + Mineral-Würfel / -Kugeln; v22 + Export-Info 132 Bytes; v23 Kopf v22 + Export-Info),
#   ab v20 nCopy, nFlyCopy
#   Gebiete: Typ (0 auf dem Terrain, 1 Box), Anzahl Einträge, Pos, Dir, Ausdehnung, NPC-Typ
#            (0 Monster, 1 NPC, 2 Monster-Gruppe), Gruppen-Typ, 3 Schalter, GenID,
#            ab v7 Steuerung / Lebenszeit / Höchstzahl, ab v12 Export-ID / Anhänge (-1 = selbst
#            ein angehängtes Gebiet), ab v13 Buff-Region; dann je Eintrag 60 Bytes (Vorlagen-ID,
#            Anzahl, Respawn-Zeit s, Tode bis neue Eigenschaften, angriffslustig, Abstand zu Wasser /
#            Terrain, 3 Fraktionen, 4 Schalter, Pfad-ID, Pfad-Schleife, Laufen, Verschwinden nach Tod);
#            dann die IDs der angehängten Gebiete
#   Sammelgebiete: Pos, Ausdehnung X / Z, Anzahl, Schalter, GenID, ab v6 Richtung (2 Bytes) +
#            Drehung, ab v7 Steuerung / Höchstzahl, ab v12 Export-ID / Anhänge, ab v17 Typ / Höhe /
#            Radius; dann je Eintrag 20 Bytes (Typ, Vorlagen-ID, Respawn-Zeit, Anzahl, Höhe)
#   Dynamische Objekte (19 / 20 / 24 / 25 Bytes je Version), Steuerungen (Name GBK 128 Bytes,
#            aktiv, Warte- / Stoppzeit, Zeitpunkte, ab v8 Zeitraum, ab v11 wiederholbar, ab v15
#            Zonen-Maske), Flugbereiche
# Positionen in Spiel-Koordinaten = Godot-Koordinaten der importierten Maps.
# ====================================================

const MAX_VERSION = 23
const NPC_TYPES = ["Monster", "NPC", "Monster-Gruppe"]

var _b: PackedByteArray
var _p = 0
var _files = null # angelica_files.gd für GBK-Namen (optional)


# Datei -> {version, areas, res_areas, dyn_objects, controllers, fly_areas} oder {"error"}
func read(path: String, files = null) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "Файл не найден: " + path}
	return parse(FileAccess.get_file_as_bytes(path), files)

func parse(bytes: PackedByteArray, files = null) -> Dictionary:
	_b = bytes
	_p = 0
	_files = files
	if _b.size() < 12:
		return {"error": "zu kurz"}
	var version = _u32()
	if version > MAX_VERSION:
		return {"error": "Неизвестная версия %d" % version}
	var counts = _header(version)
	if version >= 20:
		_p += 8 # nCopy, nFlyCopy
	var out = {"version": version, "areas": [], "res_areas": [], "dyn_objects": [], "controllers": [], "fly_areas": 0}
	for i in counts[0]:
		if not _fits(59):
			return _broken(out, "Gebiet %d" % i)
		out["areas"].append(_area(version))
	for i in counts[1]:
		if not _fits(31):
			return _broken(out, "Sammelgebiet %d" % i)
		out["res_areas"].append(_res_area(version))
	for i in counts[2]:
		if not _fits(19):
			return _broken(out, "Objekt %d" % i)
		out["dyn_objects"].append(_dyn_object(version))
	for i in counts[3]:
		if not _fits(195):
			return _broken(out, "Steuerung %d" % i)
		out["controllers"].append(_controller(version))
	for i in counts[4]:
		if version < 16:
			return _broken(out, "Flugbereich vor Version 16")
		if version < 18:
			_p += 35
		elif version < 19:
			_p += 32
		elif version < 21:
			_p += 28
		else:
			_p += 8 * _u32() + 8
	_p += counts[5] * 31 + counts[6] * 16 # Mineral-Würfel / -Kugeln (nur v16)
	out["fly_areas"] = counts[4]
	if _p != _b.size():
		out["warning"] = "Лишние данные: %d байт" % (_b.size() - _p)
	_b = PackedByteArray()
	return out

# -> [Gebiete, Sammelgebiete, Objekte, Steuerungen, Flugbereiche, Mineral-Würfel, -Kugeln]
func _header(version: int) -> Array:
	if version < 6:
		return [_u32(), _u32(), 0, 0, 0, 0, 0]
	if version < 7:
		return [_u32(), _u32(), _u32(), 0, 0, 0, 0]
	if version < 16:
		return [_u32(), _u32(), _u32(), _u32(), 0, 0, 0]
	if version == 16:
		return [_u32(), _u32(), _u32(), _u32(), _u32(), _u32(), _u32()]
	var c = [_u32(), _u32(), _u32(), _u32(), _u32(), 0, 0]
	if version >= 22:
		_p += 132 # Export-Zeit, VSS- und Rechnername
	if version >= 23:
		_p += 132 # Export-Info noch einmal (ExportInfo)
	return c

func _area(version: int) -> Dictionary:
	var a = {
		"type": _u32(), "count": _u32(), "pos": _vec(), "dir": _vec(), "ext": _vec(),
		"npc_type": _u32(), "group_type": _u32(),
		"init_gen": _b[_p] != 0, "auto_revive": _b[_p + 1] != 0, "valid_once": _b[_p + 2] != 0,
	}
	_p += 3
	a["gen_id"] = _u32()
	a["ctrl"] = 0
	a["life_time"] = 0
	a["max_num"] = 0
	var attach = 0
	if version >= 7:
		a["ctrl"] = _s32()
		a["life_time"] = _s32()
		a["max_num"] = _s32()
	if version >= 12:
		a["export_id"] = _s32()
		attach = _s32()
	if version >= 13:
		a["buf_region"] = _s32()
	a["attached"] = attach < 0 # selbst ein angehängtes Gebiet (über export_id genannt)
	var gens = []
	for j in a["count"]:
		gens.append({
			"id": _u32(), "num": _u32(), "refresh": _u32(), "died_times": _u32(), "aggressive": _u32(),
			"offset_water": _f32(), "offset_trn": _f32(),
			"faction": _u32(), "fac_helper": _u32(), "fac_accept": _u32(),
			"need_help": _b[_p] != 0, "def_faction": _b[_p + 1] != 0, "def_fac_helper": _b[_p + 2] != 0,
			"def_fac_accept": _b[_p + 3] != 0,
		})
		_p += 4
		gens[-1]["path"] = _s32()
		gens[-1]["loop"] = _s32()
		gens[-1]["run"] = _s32() == 1
		gens[-1]["dead_time"] = _s32()
	a["gens"] = gens
	a["attach_ids"] = []
	for j in maxi(0, attach):
		a["attach_ids"].append(_s32())
	return a

func _res_area(version: int) -> Dictionary:
	var r = {"pos": _vec(), "ext_x": _f32(), "ext_z": _f32(), "count": _u32(),
		"init_gen": _b[_p] != 0, "auto_revive": _b[_p + 1] != 0, "valid_once": _b[_p + 2] != 0}
	_p += 3
	r["gen_id"] = _u32()
	r["dir"] = [0, 0]
	r["rad"] = 0
	if version >= 6:
		r["dir"] = [_b[_p], _b[_p + 1]]
		r["rad"] = _b[_p + 2]
		_p += 3
	r["ctrl"] = 0
	r["max_num"] = 0
	var attach = 0
	if version >= 7:
		r["ctrl"] = _s32()
		r["max_num"] = _s32()
	if version >= 12:
		r["export_id"] = _s32()
		attach = _s32()
	r["shape"] = 0
	r["ext_y"] = 0.0
	r["radius"] = 0.0
	if version >= 17:
		r["shape"] = _s32()
		r["ext_y"] = _f32()
		r["radius"] = _f32()
	r["attached"] = attach < 0
	var res = []
	for j in r["count"]:
		res.append({"type": _s32(), "id": _s32(), "refresh": _u32(), "num": _u32(), "height": _f32()})
	r["res"] = res
	for j in maxi(0, attach):
		_p += 4
	return r

func _dyn_object(version: int) -> Dictionary:
	var o = {"id": _u32(), "pos": _vec(), "dir": [_b[_p], _b[_p + 1]], "rad": _b[_p + 2], "scale": 16, "ctrl": 0,
		"broadcast": false}
	_p += 3
	if version >= 9:
		o["scale"] = _b[_p] # 16 = 1.0
		_p += 1
	if version >= 10:
		o["ctrl"] = _u32()
	if version >= 14:
		o["broadcast"] = _b[_p] != 0
		_p += 1
	return o

func _controller(version: int) -> Dictionary:
	var c = {"id": _u32(), "ctrl_id": _s32()}
	var name_bytes = _b.slice(_p, _p + 128)
	var nul = name_bytes.find(0)
	if nul >= 0:
		name_bytes = name_bytes.slice(0, nul)
	c["name"] = _files.decode_gbk(name_bytes) if _files != null else name_bytes.get_string_from_ascii()
	_p += 128
	c["active"] = _b[_p] != 0
	_p += 1
	c["wait_time"] = _s32()
	c["stop_time"] = _s32()
	c["active_time_invalid"] = _b[_p] != 0
	c["stop_time_invalid"] = _b[_p + 1] != 0
	_p += 2
	c["active_time"] = _time()
	c["stop_at"] = _time()
	c["active_range"] = 0
	c["repeat"] = false
	if version >= 8:
		c["active_range"] = _s32()
	if version >= 11:
		c["repeat"] = _b[_p] != 0
		_p += 1
	if version >= 15:
		_p += 8 # Zonen-Maske
	return c

# NPCCTRLTIME: Jahr, Monat, Wochentag, Tag, Stunde, Minute (-1 = beliebig)
func _time() -> Array:
	return [_s32(), _s32(), _s32(), _s32(), _s32(), _s32()]

func _fits(n: int) -> bool:
	return _p + n <= _b.size()

func _broken(out: Dictionary, what: String) -> Dictionary:
	out["error"] = "Файл неожиданно закончился при чтении: %s" % what
	_b = PackedByteArray()
	return out

func _u32() -> int:
	var v = _b.decode_u32(_p)
	_p += 4
	return v

func _s32() -> int:
	var v = _b.decode_s32(_p)
	_p += 4
	return v

func _f32() -> float:
	var v = _b.decode_float(_p)
	_p += 4
	return v

func _vec() -> Vector3:
	var v = Vector3(_b.decode_float(_p), _b.decode_float(_p + 4), _b.decode_float(_p + 8))
	_p += 12
	return v
