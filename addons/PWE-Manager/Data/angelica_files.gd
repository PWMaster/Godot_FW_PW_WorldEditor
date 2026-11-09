@tool
extends RefCounted

# ====================================================
# Zugriff auf die Angelica-Spieldaten (Standard res://Stock-PWE-Client = Original-Client mit seinen
# .pck; entpackte Daten wie früher res://.resources gehen genauso): Dateien und Ordner über angelica_vfs.gd, also
# entpackt oder direkt aus den Paketen (resources/models.pck = Ordner resources/models/ ...).
# Alle Leser holen Spieldaten hierüber: file_exists, dir_exists, get_bytes, file_size, list_dir,
# load_image, read_lines, resolve.
#  - Text: die Spieldateien sind GBK-kodiert (Windows-Codepage 936), Godot kennt nur UTF-8/16/32.
#    gbk_table.bin hält für jedes Doppelbyte (Lead 0x81-0xFE, Trail 0x40-0xFE) das Unicode-
#    Zeichen als uint16 (0 = ungültig). Ganze Textdateien (.ecm) dürfen auch UTF-8 sein; kurze
#    Namen in Binärdateien sind immer GBK (z.B. 战士 = D5BD CABF wäre auch gültiges UTF-8).
#  - Pfade: Angelica-Pfade (Models\NPCS\宠物\...) sind Windows-Pfade ohne Groß/Klein, relativ
#    zum Spielordner (root; der Importer bestimmt ihn je .ecm, siehe ecm_importer.gd).
#    resolve() sucht die wirkliche Schreibweise (Platte bzw. Paket; Ordnerlisten zwischengespeichert).
# ====================================================

const VFS = preload("angelica_vfs.gd")
const GBK_TABLE = "gbk_table.bin"
const GBK_TRAIL_FIRST = 0x40
const GBK_TRAIL_COUNT = 191 # 0x40 - 0xFE

var root = "res://Stock-PWE-Client"
var _gbk = PackedByteArray()
var _dirs = {} # Ordner -> {kleingeschriebener Name: wirklicher Name}
var _high = RegEx.create_from_string("[\\x{80}-\\x{ff}]")


func _init(data_root: String = "res://Stock-PWE-Client") -> void:
	root = data_root.trim_suffix("/")
	_gbk = FileAccess.get_file_as_bytes(get_script().resource_path.get_base_dir().path_join(GBK_TABLE))


# ====================================================
# TEXT
# ====================================================
# Ganze Textdatei -> Text: gültiges UTF-8 mit mindestens einem Zeichen ab U+0800 (chinesisch
# in UTF-8 = 3 Bytes), sonst GBK. Nur 2-Byte-Folgen sind GBK, auch wenn sie als UTF-8 gültig wären
# (山 = C9 BD wäre "ɽ"). Schnell auch für große .gfx: der Text
# wird erst als Latin-1 gelesen (ein Zeichen je Byte, Position = Byte-Offset), nur die Zeilen
# mit Bytes ab 0x80 (chinesische Namen und Pfade) werden einzeln geprüft und dekodiert.
func decode(b: PackedByteArray) -> String:
	var s = b.get_string_from_ascii()
	if s.length() != b.size(): # Null-Bytes: Byte für Byte
		return b.get_string_from_utf8() if is_utf8(b) and _has_wide(b) else gbk_decode(b)
	if _high.search(s) == null:
		return s
	var lines = s.split("\n")
	var high = [] # [Zeile, Byte-Offset]
	var at = 0
	for i in lines.size():
		if _high.search(lines[i]) != null:
			high.append([i, at])
		at += lines[i].length() + 1
	var utf8 = true
	var wide = false
	for h in high:
		var line = b.slice(h[1], h[1] + lines[h[0]].length())
		if not is_utf8(line):
			utf8 = false
			break
		wide = wide or _has_wide(line)
	utf8 = utf8 and wide
	if utf8:
		return b.get_string_from_utf8()
	for h in high:
		lines[h[0]] = gbk_decode(b.slice(h[1], h[1] + lines[h[0]].length()))
	return "\n".join(lines)

# Name aus einer Binärdatei -> Text: ASCII oder GBK
func decode_gbk(b: PackedByteArray) -> String:
	for c in b:
		if c >= 0x80:
			return gbk_decode(b)
	return b.get_string_from_ascii()

# Ein Lead-Byte ab 0xE0 (UTF-8-Zeichen ab U+0800)
func _has_wide(b: PackedByteArray) -> bool:
	for c in b:
		if c >= 0xE0:
			return true
	return false

func is_utf8(b: PackedByteArray) -> bool:
	var i = 0
	var n = b.size()
	while i < n:
		var c = b[i]
		var extra = 0
		if c < 0x80:
			extra = 0
		elif c >= 0xC2 and c <= 0xDF:
			extra = 1
		elif c >= 0xE0 and c <= 0xEF:
			extra = 2
		elif c >= 0xF0 and c <= 0xF4:
			extra = 3
		else:
			return false
		if i + extra >= n and extra > 0:
			return false
		for k in range(1, extra + 1):
			if (b[i + k] & 0xC0) != 0x80:
				return false
		i += extra + 1
	return true

func gbk_decode(b: PackedByteArray) -> String:
	var out = PackedByteArray() # UTF-32LE
	out.resize(b.size() * 4)
	var k = 0
	var i = 0
	var n = b.size()
	while i < n:
		var c = b[i]
		var cp = c
		if c >= 0x81 and c <= 0xFE and i + 1 < n and b[i + 1] >= GBK_TRAIL_FIRST and b[i + 1] <= 0xFE:
			var at = ((c - 0x81) * GBK_TRAIL_COUNT + b[i + 1] - GBK_TRAIL_FIRST) * 2
			cp = _gbk.decode_u16(at) if at + 1 < _gbk.size() else 0
			if cp == 0:
				cp = 0xFFFD
			i += 1
		elif c == 0x80:
			cp = 0x20AC # € in Codepage 936
		elif c > 0x80:
			cp = 0xFFFD
		i += 1
		out.encode_u32(k, cp)
		k += 4
	out.resize(k)
	return out.get_string_from_utf32()

# Textdatei der Spieldaten (z.B. .ecm, "MOXT" + "Version: ...") als Zeilen ohne Zeilenende
func read_lines(path: String) -> PackedStringArray:
	var b = get_bytes(path)
	if b.size() >= 3 and b[0] == 0xEF and b[1] == 0xBB and b[2] == 0xBF:
		b = b.slice(3)
	return decode(b).replace("\r", "").split("\n")


# ====================================================
# DATEIEN (echt oder aus den Paketen)
# ====================================================
func file_exists(path: String) -> bool:
	return VFS.file_exists(path, self)

func dir_exists(path: String) -> bool:
	return VFS.dir_exists(path, self)

func get_bytes(path: String) -> PackedByteArray:
	return VFS.get_bytes(path, self)

func file_size(path: String) -> int:
	return VFS.file_size(path, self)

# Ordnerinhalt: {"files": [Namen], "dirs": [Namen]}
func list_dir(dir: String) -> Dictionary:
	var out = {"files": [], "dirs": []}
	var l = VFS.list(dir, self)
	for k in l:
		out["dirs" if l[k][1] else "files"].append(l[k][0])
	return out

# Bild der Spieldaten (.dds / .tga / .bmp / .png / .jpg) aus dem Speicher, null wenn nicht lesbar
func load_image(path: String) -> Image:
	return image_from_bytes(get_bytes(path), path.get_extension())

# Bilddaten mit Endung ext -> Image, null wenn nicht lesbar
static func image_from_bytes(b: PackedByteArray, ext: String) -> Image:
	if b.is_empty():
		return null
	var img = Image.new()
	var err = ERR_FILE_UNRECOGNIZED
	match ext.to_lower():
		"dds": err = img.load_dds_from_buffer(b)
		"tga": err = img.load_tga_from_buffer(b)
		"bmp": err = img.load_bmp_from_buffer(b)
		"png": err = img.load_png_from_buffer(b)
		"jpg", "jpeg": err = img.load_jpg_from_buffer(b)
	return img if err == OK and not img.is_empty() else null


# ====================================================
# PFADE
# ====================================================
# Angelica-Pfad (\ oder /, beliebige Groß/Klein-Schreibung) relativ zu base (Standard: root)
# -> wirklicher res://-Pfad, "" wenn nicht vorhanden
func resolve(rel: String, base: String = "") -> String:
	var path = root if base == "" else base.trim_suffix("/")
	for part in rel.strip_edges().replace("\\", "/").split("/", false):
		if part == ".":
			continue
		if part == "..":
			path = path.get_base_dir()
			continue
		var hit = _list(path).get(part.to_lower(), "")
		if hit == "":
			return ""
		path = path.path_join(hit)
	return path

# Pfad relativ zu root ("" wenn außerhalb)
func relative(path: String) -> String:
	if not path.begins_with(root + "/"):
		return ""
	return path.substr(root.length() + 1)

func _list(dir: String) -> Dictionary:
	if _dirs.has(dir):
		return _dirs[dir]
	var names = {}
	var l = VFS.list(dir, self)
	for k in l:
		names[k] = l[k][0]
	_dirs[dir] = names
	return names
