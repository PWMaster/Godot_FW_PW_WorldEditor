@tool
extends RefCounted

# ====================================================
# Ein Angelica-Paket (.pck, AFilePackage Version 2.1 / 2.2) lesen, ohne es zu entpacken.
# Aufbau (little endian):
#   Anfang  Safe-Header (0x4DCA23EF, Ende der Daten, 0x56A089B7), wenn vorhanden; dann die Dateien
#   Ende der Daten (Offset aus dem Safe-Header, sonst Dateiende):
#           FILEHEADER (272 Bytes: Wächter 0, Version, Offset der Einträge ^ MASKDWORD, Flags,
#           Beschreibung 252 Bytes, Wächter 1), Anzahl der Einträge (int), Version (DWORD)
#   Einträge ab ihrem Offset, je: int Länge ^ MASKDWORD, int Länge ^ CHECKMASK ^ MASKDWORD
#           (Prüfwert), FILEENTRY (276 Bytes, zlib-gepackt außer bei Länge 276): Name GBK
#           (260 Bytes, relativ zum Paketordner, z.B. models.pck -> "npcs\..."), Offset, Länge,
#           gepackte Länge, Zugriffszähler
#   Datei   gepackte Länge < Länge: zlib, sonst roh; Flag 0x80000000: verschlüsselt (Decrypt)
#   Über 0x7FFFFF00 Bytes (MAX_FILE_PACKAGE) liest CPackageFile in <Name>.pkx weiter.
# Schlüssel je Spiel (AFilePackMan::SetAlgorithmID): Forsaken World = 131; open() erkennt die ID an
# den Wächter-Bytes (0 - 255 und 111).
# Namen (GBK) entschlüsselt der mitgegebene Dekoder (angelica_files.gd); nachgeschlagen wird ohne
# Groß/Klein-Unterscheidung mit "/" (AFilePackage::directory sucht mit stricmp).
# ====================================================

const MAX_FILE_PACKAGE = 0x7fffff00
const SAFE_TAG1 = 0x4DCA23EF
const SAFE_TAG2 = 0x56a089b7
const HEADER_SIZE = 272
const ENTRY_SIZE = 276
const NAME_SIZE = 260
const VERSIONS = [0x00020002, 0x00020001]
const FLAG_ENCRYPT = 0x80000000
const DESCRIPTION = "lica File Package"

var path = ""
var version = 0
var algorithm = -1
var encrypted = false
var count = 0
var _f1: FileAccess
var _f2: FileAccess
var _size1 = 0
var _size2 = 0
var _files = {} # Name (klein, "/") -> PackedInt64Array [Offset, Länge, gepackte Länge]
var _dirs = {} # Ordner (klein, "" = Paketordner) -> {Name klein: [Name, ist Ordner]}


# Wächter- und Maskenwerte einer Algorithmus-ID: [GUARDBYTE0, GUARDBYTE1, MASKDWORD, CHECKMASK]
static func keys(id: int) -> Array:
	if id == 111:
		return [0xab12908f, 0xb3231902, 0x2a63810e, 0x18734563]
	return [(0xfdfdfeee + id * 0x72341f2) & 0xffffffff, (0xf00dbeef + id * 0x1237a73) & 0xffffffff,
		(0xa8937462 + id * 0xab2321f) & 0xffffffff, (0x59374231 + id * 0x987a223) & 0xffffffff]

# Paket öffnen und die Einträge lesen -> "" oder Fehlertext; decoder: angelica_files.gd (GBK)
func open(pck_path: String, decoder) -> String:
	path = pck_path
	_f1 = FileAccess.open(pck_path, FileAccess.READ)
	if _f1 == null:
		return pck_path + " nicht lesbar"
	_size1 = _f1.get_length()
	var pkx = pck_path.get_basename() + ".pkx"
	if FileAccess.file_exists(pkx):
		_f2 = FileAccess.open(pkx, FileAccess.READ)
		_size2 = _f2.get_length() if _f2 != null else 0
	var end = _size1 + _size2
	var safe = _read(0, 12)
	if safe.size() == 12 and safe.decode_u32(0) == SAFE_TAG1 and safe.decode_u32(8) == SAFE_TAG2:
		end = safe.decode_u32(4)
	var tail = _read(end - HEADER_SIZE - 8, HEADER_SIZE + 8)
	if tail.size() != HEADER_SIZE + 8:
		return pck_path.get_file() + ": zu kurz"
	version = tail.decode_u32(HEADER_SIZE + 4)
	count = tail.decode_s32(HEADER_SIZE)
	if not version in VERSIONS:
		return pck_path.get_file() + ": Version 0x%x unbekannt" % version
	if tail.slice(16, 16 + 252).get_string_from_ascii().find(DESCRIPTION) < 0:
		return pck_path.get_file() + ": keine Angelica-Paketdatei"
	var g0 = tail.decode_u32(0)
	var g1 = tail.decode_u32(268)
	var k = []
	for id in range(256) + [111]:
		var kk = keys(id)
		if kk[0] == g0 and kk[1] == g1:
			algorithm = id
			k = kk
			break
	if k.is_empty():
		return pck_path.get_file() + ": Schlüssel unbekannt (Wächter 0x%x / 0x%x)" % [g0, g1]
	encrypted = (tail.decode_u32(12) & FLAG_ENCRYPT) != 0
	var entry_offset = tail.decode_u32(8) ^ k[2]
	var table = _read(entry_offset, end - HEADER_SIZE - 8 - entry_offset)
	var p = 0
	for i in count:
		if p + 8 > table.size():
			return pck_path.get_file() + ": Eintrag %d fehlt" % i
		var cs = table.decode_u32(p) ^ k[2]
		var check = table.decode_u32(p + 4) ^ k[3] ^ k[2]
		if cs != check or p + 8 + cs > table.size():
			return pck_path.get_file() + ": Eintrag %d beschädigt" % i
		var e = table.slice(p + 8, p + 8 + cs)
		if cs != ENTRY_SIZE:
			e = e.decompress(ENTRY_SIZE, FileAccess.COMPRESSION_DEFLATE)
		p += 8 + cs
		if e.size() < ENTRY_SIZE - 4:
			return pck_path.get_file() + ": Eintrag %d nicht entpackbar" % i
		var name_bytes = e.slice(0, NAME_SIZE)
		var nul = name_bytes.find(0)
		if nul >= 0:
			name_bytes = name_bytes.slice(0, nul)
		var name = decoder.decode_gbk(name_bytes).replace("\\", "/")
		var package_root = pck_path.get_file().get_basename()
		if name.to_lower().begins_with(package_root.to_lower() + "/"):
			name = name.substr(package_root.length() + 1)
		var info = PackedInt64Array([e.decode_u32(NAME_SIZE), e.decode_u32(NAME_SIZE + 4), e.decode_u32(NAME_SIZE + 8)])
		if info[2] > MAX_FILE_PACKAGE: # vom Patcher kaputt geschrieben (CheckFileEntryValid): leere Datei
			info[1] = 0
			info[2] = 0
		_add(name, info)
	return ""

func _add(name: String, info: PackedInt64Array) -> void:
	var lower = name.to_lower()
	_files[lower] = info
	var parts = name.split("/", false)
	var dir = ""
	for i in parts.size():
		if not _dirs.has(dir):
			_dirs[dir] = {}
		var last = i == parts.size() - 1
		var key = parts[i].to_lower()
		if not _dirs[dir].has(key):
			_dirs[dir][key] = [parts[i], not last]
		dir = key if dir == "" else dir + "/" + key

func close() -> void:
	_f1 = null
	_f2 = null
	_files = {}
	_dirs = {}

func has_file(rel: String) -> bool:
	return _files.has(rel.to_lower())

func has_dir(rel: String) -> bool:
	return _dirs.has(rel.to_lower().trim_suffix("/"))

# Inhalt eines Ordners im Paket ("" = Paketordner): {Name klein: [Name, ist Ordner]}
func list_dir(rel: String) -> Dictionary:
	return _dirs.get(rel.to_lower().trim_suffix("/"), {})

func file_size(rel: String) -> int:
	var info = _files.get(rel.to_lower())
	return info[1] if info != null else -1

# Datei aus dem Paket (entpackt), leer wenn es sie nicht gibt
func get_bytes(rel: String) -> PackedByteArray:
	var info = _files.get(rel.to_lower())
	if info == null or info[1] == 0:
		return PackedByteArray()
	var raw = _read(info[0], info[2] if info[1] > info[2] else info[1])
	if encrypted:
		_decrypt(raw)
	if info[1] > info[2]:
		return raw.decompress(info[1], FileAccess.COMPRESSION_DEFLATE)
	return raw

# Bytes ab Offset über .pck und .pkx hinweg (CPackageFile::read)
func _read(offset: int, n: int) -> PackedByteArray:
	var out = PackedByteArray()
	if n <= 0:
		return out
	if offset < MAX_FILE_PACKAGE:
		_f1.seek(offset)
		var k = mini(n, MAX_FILE_PACKAGE - offset)
		out = _f1.get_buffer(k)
		offset += k
		n -= k
	if n > 0 and _f2 != null:
		_f2.seek(offset - MAX_FILE_PACKAGE)
		out.append_array(_f2.get_buffer(n))
	return out

# AFilePackage::Decrypt (Forsaken World verschlüsselt nicht; der Vollständigkeit halber)
static func _decrypt(b: PackedByteArray) -> void:
	var mask = (b.size() + 0x739802ab) & 0xffffffff
	var i = 0
	while i + 3 < b.size():
		var data = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]
		data = ((data << 16) | ((data >> 16) & 0xffff)) & 0xffffffff
		data ^= mask
		b[i] = (data >> 24) & 0xff
		b[i + 1] = (data >> 16) & 0xff
		b[i + 2] = (data >> 8) & 0xff
		b[i + 3] = data & 0xff
		i += 4
