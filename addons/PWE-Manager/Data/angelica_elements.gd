@tool
extends RefCounted

# ====================================================
# Vorlagen-Datenbank des Spiels (data\elements.data, elementdataman) lesen: Gegenstände, Monster,
# NPCs, Sammelpunkte, Konfigurationen ... und die Pfadtabelle data\path.data.
# Aufbau elements.data: Version (0x10000xxx), Export-Info (132 Bytes), dann Listen nacheinander,
# je Liste Satzgröße, Anzahl und die Sätze; nach Liste 33 und 67 je ein Block mit Kennung
# (0x19e75edf: Länge, Rechnername, Zeit; 0xee35679f: Länge, Daten); am Ende die Gesprächsdaten
# (talk_proc, talks()): Anzahl, je Gespräch ID, Titel (64 Zeichen), Fenster (ID, Elternfenster,
# Text variabler Länge, Optionen: Ziel-ID (oberstes Bit = Funktion), Text 64 Zeichen, Parameter).
# Die Listenzahl je Version steht in der Beschreibung ("lists"): bei v297 sind es 206; ohne sie
# endet die Suche an der ersten Stelle, die nicht wie eine Liste aussieht.
# Strukturen und Reihenfolge der Listen: angelica_elements_schema.json (aus exptypes.h /
# elementdataman.cpp v260, pack 4). Andere Versionen haben teils größere Sätze (eingefügte
# Felder): für v297 (Client) stehen die Einfügestellen je Typ in der Beschreibung ("Verschiebung
# ab Offset"), ermittelt aus dem Vergleich gleicher IDs mit einer älteren Datei. Typen ohne
# bekannte Einfügestellen und neue Listen (v297 hat 13 mehr) liefern nur ID und Namen.
# Die Datei bleibt offen, gelesen wird nur, was gebraucht wird (die Client-Datei hat > 200 MB).
# IDs sind je Raum eindeutig (essence: Gegenstände, Monster, NPCs, Minen ...; addon; recipe;
# config), nicht über Räume hinweg.
# path.data ("DIMP", Anzahl, je Eintrag ID, Länge, Pfad GBK): Pfad-IDs der Vorlagen (z.B.
# file_model) -> Pfad relativ zum Spielordner (models\npcs\...\x.ecm).
# Ort: je Sprache ein data-Ordner (Deu / Franz / Eng unter den Spieldaten, gleicher Aufbau,
# Texte in der Sprache), sonst data\ direkt im Spielordner (locate()).
# ====================================================

const SCHEMA_FILE = "angelica_elements_schema.json"
const LANGUAGES = ["Deu", "Franz", "Eng"]
const HEADER_SIZE = 136 # Version + Export-Info
const TAG_NAME = 0x19e75edf
const TAG_INFO = 0xee35679f
const PATH_ID = 0x504d4944 # "DIMP"
const PRIM_SIZE = {"i32": 4, "u32": 4, "f32": 4, "f64": 8, "i16": 2, "u16": 2, "i8": 1, "u8": 1, "bool": 1,
	"wchar": 2, "i64": 8, "u64": 8}
# Layout einer Liste
const FULL = "voll" # Satz wie die Beschreibung
const SHIFTED = "angepasst" # mit bekannten Einfügestellen
const NAME_ONLY = "nur ID / Name"
const UNKNOWN = "unbekannt" # Liste, die die Beschreibung nicht kennt

var path = ""
var version = 0
var lists: Array = [] # [{index, type, space, size, count, offset, layout}]
var _f: FileAccess
var _patch = {} # Typ -> Einfügestellen [[Offset, Verschiebung], ...]
var _ids = {} # Raum -> {ID: [Liste, Satz]}
var _paths = {} # path.data
var _paths_loaded = false
var _talk_offset = -1 # Beginn der Gesprächsdaten
var _talks = {} # ID -> Gespräch (talks())
var _files = null # angelica_files.gd (GBK für Pfade), optional
var _schema: Dictionary = {} # angelica_elements_schema.json (je Instanz: eine statische Variable hielte das Skript bis zum Beenden fest)


# elements.data öffnen -> "" oder Fehlertext
func open(file_path: String, files = null) -> String:
	close()
	path = file_path
	_files = files
	_f = FileAccess.open(file_path, FileAccess.READ)
	if _f == null:
		return file_path + " nicht lesbar"
	var schema = load_schema()
	if schema.is_empty():
		return SCHEMA_FILE + " fehlt"
	version = _f.get_32()
	var vinfo: Dictionary = schema["versions"].get(str(version), {})
	_patch = {}
	var patches: Dictionary = vinfo.get("patch", {})
	for t in patches:
		_patch[t] = patches[t]
	var unsafe: Array = vinfo.get("unsafe", [])
	var known: Array = schema["lists"]
	var list_count: int = int(vinfo.get("lists", 0))
	var size = _f.get_length()
	var p = HEADER_SIZE
	while p + 8 <= size and (list_count == 0 or lists.size() < list_count):
		_f.seek(p)
		var a = _f.get_32()
		var c = _f.get_32()
		if a == TAG_NAME:
			p += 8 + c + 4
			continue
		if a == TAG_INFO:
			p += 8 + c
			continue
		if a == 0 or a > 200000 or c > 2000000 or p + 8 + a * c > size:
			break # Gesprächsdaten
		var i = lists.size()
		var info = {"index": i, "size": a, "count": c, "offset": p + 8, "type": "", "space": "", "layout": UNKNOWN}
		if i < known.size():
			var t: String = known[i]["type"]
			info["type"] = t
			info["space"] = known[i]["space"]
			var st: Dictionary = schema["structs"].get(t, {})
			if st.get("size", -1) == a:
				info["layout"] = FULL
			elif _patch.has(t) and _patch[t]["size"] == a and not t in unsafe:
				info["layout"] = SHIFTED
			else:
				info["layout"] = NAME_ONLY
		lists.append(info)
		p += 8 + a * c
	_talk_offset = p
	if lists.is_empty():
		return file_path + ": keine Listen gefunden"
	return ""

func close() -> void:
	_f = null
	lists = []
	_talk_offset = -1
	_talks = {}
	_ids = {}
	_paths = {}
	_paths_loaded = false

# elements.data der Spieldaten finden ("" wenn keine): <Sprache>/data oder resources/<Sprache>/data,
# zuerst die gewünschte Sprache, dann Deu, Franz, Eng; zuletzt data/ (ohne Sprachordner)
static func locate(files, lang: String = "") -> String:
	var order = [lang] if lang != "" else []
	for l in LANGUAGES:
		if not l in order:
			order.append(l)
	for l in order:
		for base in [l + "/data", "resources/" + l + "/data"]:
			var p: String = files.resolve(base + "/elements.data")
			if p != "":
				return p
	return files.resolve("data/elements.data")

# Beschreibung neben diesem Skript, einmal je Instanz geladen
func load_schema() -> Dictionary:
	if _schema.is_empty():
		var p = (get_script() as Script).resource_path.get_base_dir().path_join(SCHEMA_FILE)
		if FileAccess.file_exists(p):
			var d = JSON.parse_string(FileAccess.get_file_as_string(p))
			if d is Dictionary:
				_schema = _ints(d)
	return _schema

# JSON liefert Zahlen als float: Größen, Offsets, Dimensionen und Einfügestellen als int
static func _ints(d: Dictionary) -> Dictionary:
	for t in d["structs"]:
		var st: Dictionary = d["structs"][t]
		st["size"] = int(st["size"])
		for f in st["fields"]:
			f[2] = int(f[2])
			var dims = []
			for x in f[3]:
				dims.append(int(x))
			f[3] = dims
	for v in d["versions"]:
		var patch: Dictionary = d["versions"][v]["patch"]
		for t in patch:
			patch[t]["size"] = int(patch[t]["size"])
			for st in patch[t]["steps"]:
				st[0] = int(st[0])
				st[1] = int(st[1])
	return d


# ====================================================
# SUCHEN
# ====================================================
# Liste eines Typs (z.B. "MONSTER_ESSENCE"), -1 wenn nicht vorhanden
func list_of(type: String) -> int:
	for l in lists:
		if l["type"] == type:
			return l["index"]
	return -1

# ID -> [Liste, Satz] im Raum (essence / addon / recipe / config), [] wenn unbekannt
func find(id: int, space: String = "essence") -> Array:
	if not _ids.has(space):
		_index(space)
	return _ids[space].get(id, [])

func _index(space: String) -> void:
	var map = {}
	for l in lists:
		if l["space"] != space or l["layout"] == UNKNOWN:
			continue
		var fields: Array = _fields(l["type"])
		if fields.is_empty() or fields[0][0] != "id":
			continue
		for i in l["count"]:
			_f.seek(l["offset"] + i * l["size"])
			var id = _f.get_32()
			if not map.has(id):
				map[id] = [l["index"], i]
	_ids[space] = map

# Typ einer ID ("" wenn unbekannt)
func type_of(id: int, space: String = "essence") -> String:
	var at = find(id, space)
	return lists[at[0]]["type"] if not at.is_empty() else ""

# Name einer ID ("" wenn unbekannt)
func name_of(id: int, space: String = "essence") -> String:
	var at = find(id, space)
	return record_name(at[0], at[1]) if not at.is_empty() else ""

# Vollständiger Satz einer ID ({} wenn unbekannt), mit "_type" und "_layout"
func get_record(id: int, space: String = "essence") -> Dictionary:
	var at = find(id, space)
	return record(at[0], at[1]) if not at.is_empty() else {}


# ====================================================
# SÄTZE
# ====================================================
# Satz i der Liste li als Dictionary (Felder wie exptypes.h; Texte als String, Arrays als Array)
func record(li: int, i: int) -> Dictionary:
	var l: Dictionary = lists[li]
	if i < 0 or i >= l["count"]:
		return {}
	_f.seek(l["offset"] + i * l["size"])
	var b = _f.get_buffer(l["size"])
	var out: Dictionary
	if l["layout"] == FULL or l["layout"] == SHIFTED:
		var steps: Array = _patch[l["type"]]["steps"] if l["layout"] == SHIFTED else []
		out = _decode(l["type"], b, 0, steps)
	else:
		out = {"id": b.decode_u32(0) if b.size() >= 4 else 0}
		var nf = _name_field(l["type"])
		if not nf.is_empty() and nf[2] + nf[3] <= b.size():
			out["name"] = _wstr(b, nf[2], nf[3] / 2)
		out["_raw"] = b
	out["_type"] = l["type"]
	out["_layout"] = l["layout"]
	return out

# Nur der Name (schnell, ohne den ganzen Satz zu zerlegen)
func record_name(li: int, i: int) -> String:
	var l: Dictionary = lists[li]
	var nf = _name_field(l["type"])
	if nf.is_empty():
		return ""
	var off = nf[2]
	if l["layout"] == SHIFTED:
		off = _shift(off, _patch[l["type"]]["steps"])
	if off + nf[3] > l["size"]:
		return ""
	_f.seek(l["offset"] + i * l["size"] + off)
	return _wstr(_f.get_buffer(nf[3]), 0, nf[3] / 2)

# Feld "name" eines Typs: [Name, Typ, Offset, Bytes] oder []
func _name_field(type: String) -> Array:
	for f in _fields(type):
		if f[0] == "name" and f[1] == "wchar":
			return [f[0], f[1], f[2], 2 * _count(f[3])]
	return []

func _fields(type: String) -> Array:
	return _schema.get("structs", {}).get(type, {}).get("fields", [])

func _decode(type: String, b: PackedByteArray, base: int, steps: Array) -> Dictionary:
	var out = {}
	for f in _fields(type):
		var name: String = f[0]
		var ft: String = f[1]
		var off: int = base + f[2]
		var dims: Array = f[3]
		var n = _count(dims)
		if PRIM_SIZE.has(ft):
			if ft == "wchar" and not dims.is_empty():
				var inner: int = dims[-1]
				if n == inner:
					out[name] = _wstr(b, _shift(off, steps), inner)
				else:
					var arr = []
					for k in n / inner:
						arr.append(_wstr(b, _shift(off + k * inner * 2, steps), inner))
					out[name] = arr
			elif n == 1 and dims.is_empty():
				out[name] = _prim(ft, b, _shift(off, steps))
			else:
				var arr = []
				for k in n:
					arr.append(_prim(ft, b, _shift(off + k * PRIM_SIZE[ft], steps)))
				out[name] = arr
		else:
			var sz: int = _schema["structs"][ft]["size"]
			if dims.is_empty():
				out[name] = _decode(ft, b, off, steps)
			else:
				var arr = []
				for k in n:
					arr.append(_decode(ft, b, off + k * sz, steps))
				out[name] = arr
	return out

# Offset in der Datei-Version: + Verschiebung der letzten Einfügestelle davor
static func _shift(off: int, steps: Array) -> int:
	var s = 0
	for st in steps:
		if st[0] <= off:
			s = st[1]
		else:
			break
	return off + s

static func _count(dims: Array) -> int:
	var n = 1
	for d in dims:
		n *= d
	return n

static func _prim(ft: String, b: PackedByteArray, off: int):
	if off + PRIM_SIZE[ft] > b.size():
		return null
	match ft:
		"i32": return b.decode_s32(off)
		"u32": return b.decode_u32(off)
		"f32": return b.decode_float(off)
		"f64": return b.decode_double(off)
		"i16": return b.decode_s16(off)
		"u16", "wchar": return b.decode_u16(off)
		"i8": return b.decode_s8(off)
		"u8": return b.decode_u8(off)
		"bool": return b.decode_u8(off) != 0
		"i64": return b.decode_s64(off)
		"u64": return b.decode_u64(off)
	return null

# Text ohne Farbcodes der Oberfläche (^RRGGBB), z.B. für Knotennamen
static func strip_codes(s: String) -> String:
	if not s.contains("^"):
		return s
	var out = ""
	var i = 0
	while i < s.length():
		if s[i] == "^" and i + 6 < s.length() and s.substr(i + 1, 6).is_valid_hex_number():
			i += 7
			continue
		out += s[i]
		i += 1
	return out

# UTF-16-Text fester Länge bis zum ersten Null-Zeichen
static func _wstr(b: PackedByteArray, off: int, chars: int) -> String:
	var end = mini(off + chars * 2, b.size())
	var i = off
	while i + 1 < end and (b[i] != 0 or b[i + 1] != 0):
		i += 2
	return b.slice(off, i).get_string_from_utf16() if i > off else ""


# ====================================================
# GESPRÄCHE (talk_proc am Ende der Datei)
# ====================================================
# Alle Gespräche: {ID: {"id", "title", "windows": [{"id", "parent", "text", "options":
# [{"id", "text", "param", "param_addon"}]}]}}; Fenster parent 0xFFFFFFFF = erstes Fenster,
# Options-ID mit oberstem Bit (0x80000000 ...) = Funktion (Dienst, Schließen ...)
func talks() -> Dictionary:
	if not _talks.is_empty() or _talk_offset < 0 or _f == null:
		return _talks
	_f.seek(_talk_offset)
	var b = _f.get_buffer(_f.get_length() - _talk_offset)
	var p = 4
	var n = b.decode_u32(0) if b.size() >= 4 else 0
	for i in n:
		if p + 136 > b.size():
			break
		var t = {"id": b.decode_u32(p), "title": _wstr(b, p + 4, 64), "windows": []}
		var nw = b.decode_s32(p + 132)
		p += 136
		for w in nw:
			var tl = b.decode_s32(p + 8)
			var win = {"id": b.decode_u32(p), "parent": b.decode_u32(p + 4),
				"text": _wstr(b, p + 12, tl) if tl > 0 else "", "options": []}
			p += 12 + 2 * tl
			var no = b.decode_s32(p)
			p += 4
			for o in no:
				win["options"].append({"id": b.decode_u32(p), "text": _wstr(b, p + 4, 64), "param": b.decode_u32(p + 132),
					"param_addon": b.decode_s32(p + 136)})
				p += 140
			t["windows"].append(win)
		_talks[t["id"]] = t
	return _talks

# Gespräch eines Gesprächs-Dienstes (NPC_TALK_SERVICE id_dialog) bzw. einer ID, {} wenn unbekannt
func talk(id: int) -> Dictionary:
	return talks().get(id, {})


# ====================================================
# PFADE (data\path.data)
# ====================================================
# Pfad-ID -> Pfad relativ zum Spielordner ("" wenn unbekannt); path.data neben elements.data
func path_of(path_id: int) -> String:
	if not _paths_loaded:
		_load_paths(path.get_base_dir().path_join("path.data"))
	return _paths.get(path_id, "")

func _load_paths(file_path: String) -> void:
	_paths_loaded = true
	var b = FileAccess.get_file_as_bytes(file_path)
	if b.size() < 8 or b.decode_u32(0) != PATH_ID:
		return
	var n = b.decode_u32(4)
	var p = 8
	for i in n:
		if p + 8 > b.size():
			break
		var id = b.decode_u32(p)
		var len = b.decode_u32(p + 4)
		var s = b.slice(p + 8, p + 8 + len)
		var nul = s.find(0)
		if nul >= 0:
			s = s.slice(0, nul)
		_paths[id] = _files.decode_gbk(s) if _files != null else s.get_string_from_utf8()
		p += 8 + len

# Modell einer Vorlage (file_model -> Pfad), "" wenn keins
func model_of(id: int, space: String = "essence") -> String:
	var at = find(id, space)
	if at.is_empty():
		return ""
	var l: Dictionary = lists[at[0]]
	if l["layout"] != FULL and l["layout"] != SHIFTED:
		return ""
	for f in _fields(l["type"]):
		if f[0] == "file_model" and f[3].is_empty():
			var steps: Array = _patch[l["type"]]["steps"] if l["layout"] == SHIFTED else []
			_f.seek(l["offset"] + at[1] * l["size"] + _shift(f[2], steps))
			return path_of(_f.get_32())
	return ""
