@tool
extends RefCounted

# ====================================================
# Statuseffekte des Clients (wie CECGame::GetSkillBuffType / GetBuffIcon / GetBuffDesc / GetBuffGfx):
#   configs\buff_type.txt   Art je Effekt (SKILL_BUFF_TYPE_*: 0 Stärkung, 1 Schwächung, 2 nicht zeigen,
#                           3 / 4 Stärkung / Schwächung ohne Zeit, 5 besonders, 6 EXP)
#   configs\buff_icon.txt   Symbol-Datei (GBK), im Atlas surfaces\iconset\iconlist_state
#   configs\buff_str.txt    Text (UTF-16, mehrzeilig, Angelica-Codes ^RRGGBB / ^O...); erste Zeile = Name.
#                           Die Datei liegt in configs.pck und gilt für alle Sprachen der Installation
#   <Sprache>\script\config\buff_gfx.lua  Buff_Gfx[Schlüssel][Sichtbar-Index] = {GFX, Haken, Farbe}
#                           (CECBuffGfxInfo): Schlüssel 0 = alle / NPCs, sonst (Rasse - 1) * 9 + Klasse;
#                           der Index ist das Feld light der Effekt-Vorlage (sichtbarer Zustand am Modell)
#   var b = Buffs.new(files, "Deu");  b.open() -> "" oder Fehler (Texte gut 0,1 s: im Thread möglich)
#   b.type(id), b.desc(id), b.title(id), b.icon(id) -> Texture2D oder null, b.gfx(Rasse, Klasse, light)
#   -> [GFX-Pfad relativ zu gfx\, Haken] oder []
# ====================================================

const TYPE_INVALID = -1
const TYPE_BUFF = 0
const TYPE_DEBUFF = 1
const TYPE_NONE = 2
const TYPE_BUFF_NO_TIME = 3
const TYPE_DEBUFF_NO_TIME = 4
const TYPE_NUM = 7
const ICON_SET = "iconlist_state"
const PROF_COUNT = 9 # PlayerUtil::PROF_LAST - 1
const GFX_SCRIPT = "script/config/buff_gfx.lua"

var files # angelica_files.gd
var language = "Deu"
var errors: Array = []
var _types = {} # ID -> Art
var _icon_files = {} # ID -> Dateiname klein
var _desc = {} # ID -> Text
var _gfx = {} # Schlüssel -> {Index: [GFX, Haken]}
var _icon_index = {} # Dateiname klein -> Symbol-Nummer
var _atlas: Texture2D = null
var _cell = Vector2i(40, 40)
var _cols = 1
var _icons = {} # ID -> AtlasTexture oder null
var _icons_read = false


func _init(p_files, p_language: String = "Deu") -> void:
	files = p_files
	language = p_language

func open() -> String:
	var types = _config_file("buff_type.txt")
	if types == "":
		return "configs/buff_type.txt fehlt"
	for kv in _entries(files.read_lines(types)):
		var t = str(kv[1]).to_int()
		_types[kv[0]] = t if t > TYPE_INVALID and t < TYPE_NUM else TYPE_INVALID
	var icons = _config_file("buff_icon.txt")
	if icons != "":
		for kv in _entries(files.read_lines(icons)):
			if kv[1] != "":
				_icon_files[kv[0]] = str(kv[1]).to_lower()
	else:
		errors.append("configs/buff_icon.txt fehlt")
	var strs = _config_file("buff_str.txt")
	if strs != "":
		_read_desc(files.get_bytes(strs))
	else:
		errors.append("configs/buff_str.txt fehlt")
	_read_gfx()
	return ""

func type(id: int) -> int:
	return int(_types.get(id, TYPE_INVALID))

func desc(id: int) -> String:
	return str(_desc.get(id, "")) if id != 0 else ""

# Name ohne Farb- / Schriftcodes (erste Zeile des Textes)
func title(id: int) -> String:
	var s = desc(id).replace("\n", "\r").split("\r")[0]
	return RegEx.create_from_string("\\^(O\\d{3}|[0-9a-fA-F]{6})").sub(s, "", true).strip_edges()

static func bbcode(s: String) -> String:
	var t = s.replace("\r\n", "\n").replace("\r", "\n")
	return load("res://addons/PWE-Manager/UI-XML/angelica_ui_builder.gd")._bbcode(t, 0)

func icon(id: int) -> Texture2D:
	if _icons.has(id):
		return _icons[id]
	if not _icons_read:
		_icons_read = true
		_read_icons()
	var tex: AtlasTexture = null
	var i = int(_icon_index.get(str(_icon_files.get(id, "")), -1))
	if i >= 0 and _atlas != null:
		tex = AtlasTexture.new()
		tex.atlas = _atlas
		tex.region = Rect2((i % _cols) * _cell.x, (i / _cols) * _cell.y, _cell.x, _cell.y)
	_icons[id] = tex
	return tex

# GFX eines sichtbaren Zustands (CECBuffGfxInfo::GetInfo): erst die Rasse / Klasse, sonst der Eintrag 0
func gfx(race: int, prof: int, light: int) -> Array:
	if light < 0:
		return []
	var key = (race - 1) * PROF_COUNT + prof if race > 0 and prof > 0 else 0
	var e = _gfx.get(key, {}).get(light)
	if e == null and key != 0:
		e = _gfx.get(0, {}).get(light)
	return e if e != null else []

func _config_file(file_name: String) -> String:
	for base in ["resources/configs", "configs"]:
		var p = files.resolve("%s/%s" % [base, file_name])
		if p != "" and files.file_exists(p):
			return p
	return ""

# Zeilen <ID> "<Wert>" nach #_begin (AWScriptFile, Werte einzeilig)
static func _entries(lines: PackedStringArray) -> Array:
	var out = []
	var re = RegEx.create_from_string("^\\s*(\\d+)\\s+\"([^\"]*)\"")
	for line in lines:
		var m = re.search(line)
		if m != null:
			out.append([m.get_string(1).to_int(), m.get_string(2)])
	return out

# buff_str.txt: UTF-16 LE mit BOM, Texte in Anführungszeichen über mehrere Zeilen
func _read_desc(b: PackedByteArray) -> void:
	var t = b.slice(2).get_string_from_utf16() if b.size() > 1 and b[0] == 0xFF and b[1] == 0xFE else files.decode(b)
	var at = t.find("#_begin")
	var re = RegEx.create_from_string("(?m)^\\s*(\\d+)\\s+\"([^\"]*)\"")
	for m in re.search_all(t, maxi(0, at)):
		_desc[m.get_string(1).to_int()] = m.get_string(2).replace("\r\n", "\r")

func _read_gfx() -> void:
	var p = ""
	for base in [language + "/", "resources/" + language + "/", "resources/", ""]:
		p = files.resolve(base + GFX_SCRIPT)
		if p != "" and files.file_exists(p):
			break
		p = ""
	if p == "":
		errors.append("%s fehlt" % GFX_SCRIPT)
		return
	var lua = load("res://addons/PWE-Manager/Data/angelica_lua.gd").new(files)
	var err = lua.run_file(p)
	if err != "":
		errors.append("%s: %s" % [GFX_SCRIPT, err])
	var table = lua.globals.get("Buff_Gfx")
	if table is Dictionary:
		for key in table:
			var row = table[key]
			if not row is Dictionary:
				continue
			var out = {}
			for i in row:
				var e = row[i]
				if e is Dictionary and str(e.get(1, "")) != "":
					out[int(i)] = [str(e[1]).replace("\\", "/"), str(e.get(2, ""))]
			_gfx[int(key)] = out
	lua.close()

func _read_icons() -> void:
	var txt = ""
	for base in [language + "/surfaces/iconset", "resources/" + language + "/surfaces/iconset", "resources/surfaces/iconset"]:
		txt = files.resolve("%s/%s.txt" % [base, ICON_SET])
		if txt != "":
			break
	if txt == "":
		return
	var lines: PackedStringArray = files.read_lines(txt)
	if lines.size() < 5:
		return
	var img = files.load_image(txt.get_basename() + ".dds")
	if img == null:
		return
	_atlas = ImageTexture.create_from_image(img)
	_cell = Vector2i(lines[0].to_int(), lines[1].to_int())
	_cols = maxi(1, lines[3].to_int())
	for i in range(4, lines.size()):
		var key = lines[i].strip_edges().to_lower()
		if key != "" and not _icon_index.has(key):
			_icon_index[key] = i - 4
