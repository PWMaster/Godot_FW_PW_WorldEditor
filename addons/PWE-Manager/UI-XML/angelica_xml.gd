@tool
extends RefCounted

# ====================================================
# XML der Angelica-Engine (AXMLFile / AXMLItem, AUI) -> Baum aus Dictionaries.
# Die Dateien der Oberfläche (interfaces\*.xml) sind oft kein gültiges XML: rohe "<", ">" und "&"
# in Werten (String="<<<", "Gem & Rune"), doppelte Attribute, Reste nach dem Wurzelelement. Ein
# Standard-Parser (XMLParser, ElementTree) lehnt rund 7 % davon ab; dieser Parser liest sie wie
# das Spiel:
#  - Ein Element ist der Text von "<" bis zum nächsten ">" außerhalb von "..." ; "\" überspringt
#    das folgende Zeichen (auch außerhalb von Anführungszeichen).
#  - Name bis zum ersten Leerzeichen, dann Schlüssel="Wert" (Wert roh, ohne &amp;-Auflösung,
#    "\" bleibt stehen). Tab / CR / LF zählen als Leerzeichen.
#  - "</Name>" schließt nur, wenn der Name genau dem offenen Element gleicht (Groß/Klein zählt),
#    sonst wird es wie ein neues Element eingehängt. "<.../>" hat keine Kinder.
#  - 8-Bit-Text endet am ersten Null-Byte (das Spiel liest die Datei als C-String; die UTF-16-
#    Dateien der Daten enthalten keine Null-Zeichen).
# Abfragen von Schlüsseln und Kind-Namen ohne Groß/Klein (a_stricmp), der erste Treffer zählt.
# Zahlen, Wahrheitswerte und Farben wie die Makros XMLGET_*_VALUE (AUICommon.h).
# Element: {"name": String, "keys": PackedStringArray, "values": PackedStringArray,
#           "lookup": {kleingeschriebener Schlüssel: Wert des ersten Treffers},
#           "children": Array[Dictionary]}
# ====================================================

# Datei -> Wurzel (namenlos, die Elemente der Datei als Kinder). Kodierung: UTF-16LE (mit oder
# ohne BOM, so liest das Spiel), sonst UTF-8 / GBK über angelica_files.gd (files, optional).
static func load_file(path: String, files = null) -> Dictionary:
	var b = files.get_bytes(path) if files != null else FileAccess.get_file_as_bytes(path)
	if b.is_empty():
		return {}
	return parse(decode(b, files))

static func decode(b: PackedByteArray, files = null) -> String:
	if b.size() >= 2 and (b[0] == 0xFF and b[1] == 0xFE or b[1] == 0 and b[0] != 0): # UTF-16LE
		return b.slice(2 if b[0] == 0xFF else 0).get_string_from_utf16() # ohne BOM: "<" = 3C 00
	var nul = b.find(0)
	if nul >= 0:
		b = b.slice(0, nul)
	if b.size() >= 3 and b[0] == 0xEF and b[1] == 0xBB and b[2] == 0xBF:
		return b.slice(3).get_string_from_utf8()
	return files.decode(b) if files != null else b.get_string_from_utf8()

static func parse(text: String) -> Dictionary:
	var root = _item("")
	var parents = [] # offene Elemente, root zuerst
	var parent = root
	var label = "/"
	var pos = [0]
	var s = _next_item_text(text, pos)
	while s != "":
		var item = _init_item(s)
		if item["name"] == label:
			if parents.is_empty(): # "</>" auf oberster Ebene
				break
			parent = parents.pop_back()
			label = "/" + parent["name"]
		else:
			parent["children"].append(item)
			if s[s.length() - 2] != "/":
				parents.append(parent)
				parent = item
				label = "/" + item["name"]
		s = _next_item_text(text, pos)
	return root

# AXMLFile::GetNextXMLItemText: "<" bis ">" außerhalb von Anführungszeichen, "\" überspringt
static func _next_item_text(text: String, pos: Array) -> String:
	var start = text.find("<", pos[0])
	if start < 0:
		return ""
	var i = start
	var quoted = false
	var nq = text.find("\"", i)
	var nb = text.find("\\", i)
	var ng = text.find(">", i)
	while true:
		var at = -1
		var kind = 0 # 1 Anführungszeichen, 2 Backslash, 3 Ende
		if nq >= 0:
			at = nq
			kind = 1
		if nb >= 0 and (at < 0 or nb < at):
			at = nb
			kind = 2
		if not quoted and ng >= 0 and (at < 0 or ng < at):
			at = ng
			kind = 3
		if at < 0:
			return ""
		if kind == 3:
			pos[0] = at + 1
			return text.substr(start, at + 1 - start)
		if kind == 1:
			quoted = not quoted
			i = at + 1
		else:
			i = at + 2
		if nq >= 0 and nq < i:
			nq = text.find("\"", i)
		if nb >= 0 and nb < i:
			nb = text.find("\\", i)
		if ng >= 0 and ng < i:
			ng = text.find(">", i)
	return ""

# AXMLItem::Init: Name und Schlüssel="Wert"-Paare eines Element-Texts
static func _init_item(s: String) -> Dictionary:
	s = s.strip_edges()
	var n = s.length() - 1 # ohne ">"
	if n >= 1 and s[n - 1] == "/":
		n -= 1
	s = s.substr(0, n).replace("\t", " ").replace("\r", " ").replace("\n", " ")
	var i = 1
	while i < n and s[i] == " ":
		i += 1
	var j = i
	i = s.find(" ", i)
	if i < 0:
		i = n
	var item = _item(s.substr(j, i - j))
	while i < n:
		while i < n and s[i] == " ":
			i += 1
		j = i
		var eq = s.find("=", i)
		var sp = s.find(" ", i)
		i = mini(eq if eq >= 0 else n, sp if sp >= 0 else n)
		var key = s.substr(j, i - j)
		i = eq if eq >= 0 else n
		if i >= n:
			break
		i = s.find("\"", i)
		if i < 0:
			break
		i += 1
		j = i
		while i < n:
			var q = s.find("\"", i)
			var b = s.find("\\", i)
			if q < 0 or q >= n:
				i = n
			elif b >= 0 and b < q:
				i = b + 2
			else:
				var v = s.substr(j, q - j)
				item["keys"].append(key)
				item["values"].append(v)
				var low = key.to_lower()
				if not item["lookup"].has(low):
					item["lookup"][low] = v
				i = q + 1
				break
	return item

static func _item(name: String) -> Dictionary:
	return {"name": name, "keys": PackedStringArray(), "values": PackedStringArray(), "lookup": {},
		"children": []}


# ====================================================
# ABFRAGEN
# ====================================================
# Wert eines Schlüssels (ohne Groß/Klein, erster Treffer), null wenn nicht vorhanden
static func value(item: Dictionary, key: String):
	return item.get("lookup", {}).get(key.to_lower())

static func has_value(item: Dictionary, key: String) -> bool:
	return item.get("lookup", {}).has(key.to_lower())

static func string_value(item: Dictionary, key: String, default: String = "") -> String:
	var v = value(item, key)
	return default if v == null else v

static func int_value(item: Dictionary, key: String, default: int = 0) -> int:
	var v = value(item, key)
	return default if v == null else atoi(v)

static func float_value(item: Dictionary, key: String, default: float = 0.0) -> float:
	var v = value(item, key)
	return default if v == null else atof(v)

# "true" / "false" ohne Groß/Klein, alles andere lässt den Standard stehen
static func bool_value(item: Dictionary, key: String, default: bool = false) -> bool:
	var v = value(item, key)
	if v == null:
		return default
	if v.nocasecmp_to("true") == 0:
		return true
	if v.nocasecmp_to("false") == 0:
		return false
	return default

# "r,g,b[,a]" (0-255) -> Color; weniger als drei Teile lassen den Standard stehen
static func color_value(item: Dictionary, key: String, default = null):
	var v = value(item, key)
	if v == null or v == "":
		return default
	var p = v.split(",")
	if p.size() < 3:
		return default
	var a = atoi(p[3]) if p.size() >= 4 else 255
	return Color8(atoi(p[0]) & 0xFF, atoi(p[1]) & 0xFF, atoi(p[2]) & 0xFF, a & 0xFF)

# Kinder mit diesem Namen (ohne Groß/Klein)
static func children(item: Dictionary, name: String) -> Array:
	var out = []
	for c in item.get("children", []):
		if c["name"].nocasecmp_to(name) == 0:
			out.append(c)
	return out

# Erstes Kind mit diesem Namen, {} wenn keins
static func child(item: Dictionary, name: String) -> Dictionary:
	for c in item.get("children", []):
		if c["name"].nocasecmp_to(name) == 0:
			return c
	return {}

# Alle Schlüssel / Werte als Dictionary (erster Treffer je Schlüssel, Schreibweise der Datei)
static func attributes(item: Dictionary) -> Dictionary:
	var out = {}
	var seen = {}
	var keys: PackedStringArray = item.get("keys", PackedStringArray())
	for i in keys.size():
		var low = keys[i].to_lower()
		if not seen.has(low):
			seen[low] = true
			out[keys[i]] = item["values"][i]
	return out

# atoi / atof wie in C: Leerraum, Vorzeichen, Ziffern am Anfang, sonst 0
static func atoi(s: String) -> int:
	var i = _skip_space(s)
	var neg = i < s.length() and s[i] == "-"
	if i < s.length() and (s[i] == "-" or s[i] == "+"):
		i += 1
	var j = _digits(s, i)
	if j == i:
		return 0
	var v = s.substr(i, j - i).to_int()
	return -v if neg else v

static func atof(s: String) -> float:
	var i = _skip_space(s)
	var start = i
	if i < s.length() and (s[i] == "-" or s[i] == "+"):
		i += 1
	var j = _digits(s, i)
	var has_digits = j > i
	if j < s.length() and s[j] == ".":
		var k = _digits(s, j + 1)
		has_digits = has_digits or k > j + 1
		j = k
	if not has_digits:
		return 0.0
	if j < s.length() and (s[j] == "e" or s[j] == "E"):
		var e = j + 1
		if e < s.length() and (s[e] == "-" or s[e] == "+"):
			e += 1
		var k = _digits(s, e)
		if k > e:
			j = k
	return s.substr(start, j - start).replace("+", "").to_float()

static func _skip_space(s: String) -> int:
	var i = 0
	while i < s.length() and s.unicode_at(i) in [32, 9, 10, 11, 12, 13]:
		i += 1
	return i

static func _digits(s: String, i: int) -> int:
	while i < s.length() and s.unicode_at(i) >= 48 and s.unicode_at(i) <= 57:
		i += 1
	return i
