@tool
extends RefCounted

# ====================================================
# Fertigkeiten des Clients (wie CECSkill): Name und Beschreibung über die Lua-Skripte der Spieldaten
# (CECSkill::GetName / GetDesc -> SkillDesc:GetSkillName / SkillDesc:GetDesc), Symbol aus dem Atlas
# surfaces\iconset\iconlist_skill.
#   var s = Skills.new(files, "Deu");  s.open() -> "" oder Fehler (gut 1 s: im Thread möglich)
#   s.skill_name(id), s.desc(id, Stufe, Kontext) -> Text mit Angelica-Codes (^RRGGBB, ^O..., \r, \v),
#   s.bbcode(Text) -> BBCode für Tooltips, s.icon(id) -> Texture2D oder null
#   Kontext (SkillDesc.CONTEXT): SKILL_INTERFACE 0 = Fertigkeiten-Fenster, QUICK_BAR 1 = Leiste
# Skripte (<Sprache>/script/skill/, Lua-Bytecode, Data/angelica_lua.gd) in der Reihenfolge des Spiels:
# erst die 2014er (skilldesc_2014 setzt SkillDesc = SkillDesc_2014, skilldesc_2014_1, skillstr_2014),
# dann das alte SkillDesc (skilldesc.lua, skilldesc1..19 mit den Funktionen je Fertigkeit,
# skillstr.lua mit den Texten); das alte gibt neuere IDs (SkillDesc_2014:CheckSkill) weiter.
# GameApi der Skripte (GetHostProp, GetHostSkillLevel ...) ist nachgebildet: host_level,
# host_skills setzt das Spiel. Was CECSkill aus der Skill-Bibliothek (ElementSkill, nur im
# Programm des Spiels) mitgibt - Höchststufe, Stufe / SP für die nächste Stufe -, fehlt: die
# Beschreibung zeigt die aktuelle Stufe ohne "nächste Stufe lernbar".
# Symbol: die Bibliothek nennt die Datei; ohne sie über den chinesischen Namen (configs\skillstr.txt,
# Eintrag ID * 10): <Name>.dds im Atlas, sonst <Präfix>_<Name>.dds (z.B. 牧师2_治愈术.dds), bei
# mehreren der mit dem Präfix der Klasse (CLASS_PREFIX) bzw. der kürzeste.
# ====================================================

const CONTEXT_SKILL = 0
const CONTEXT_BAR = 1
const SKILL_DIR = "script/skill/"
const FIRST = ["skilldesc_2014.lua", "skilldesc_2014_1.lua", "skillstr_2014.lua", "skilldesc.lua"]
const LAST = ["skillstr.lua"]
const ICON_SET = "iconlist_skill"
# Ohne passendes Symbol im Atlas: das nächstliegende (120 Stadtportal: Gilden-Rückkehr)
const ICON_ALIAS = {120: "公会_快速回城.dds"}
# Klasse -> Präfixe der Symbol-Dateien (clsconfig-Nummer)
const CLASS_PREFIX = {1: ["战士"], 2: ["守护"], 3: ["刺客"], 4: ["射手", "火枪"], 5: ["法师"], 6: ["牧师"], 7: ["血魔"],
	8: ["诗人", "吟游"], 9: ["死亡", "死骑"], 10: ["灵魂"]}

var files # angelica_files.gd
var language = "Deu"
var host_level = 1
var host_skills = {} # ID -> Stufe (GameApi.GetHostSkillLevel)
var skill_class = {} # ID -> Klasse (Symbol-Wahl), setzt das Spiel für bekannte Fertigkeiten
var errors: Array = []
var _lua = null
var _sd = null # SkillDesc
var _cn = {} # ID -> chinesischer Name (skillstr.txt)
var _icon_index = {} # Dateiname klein -> Symbol-Nummer
var _icon_names: Array = [] # Dateinamen klein, Reihenfolge des Atlas
var _atlas: Texture2D = null
var _cell = Vector2i(40, 40)
var _cols = 1
var _icons = {} # ID -> AtlasTexture oder null
var _icons_read = false


func _init(p_files, p_language: String = "Deu") -> void:
	files = p_files
	language = p_language

func open() -> String:
	var dir = _find_dir()
	if dir == "":
		return "Fertigkeiten-Skripte fehlen (%s/%s)" % [language, SKILL_DIR]
	_lua = load("res://addons/PWE-Manager/Data/angelica_lua.gd").new(files)
	_lua.globals["GameApi"] = {"GetHostProp": func(_a): return [{"level": host_level}],
		"GetHostSkillLevel": func(a): return [int(host_skills.get(int(a[0]) if not a.is_empty() and a[0] != null else 0, 0))],
		"GetHostBuffLevel": func(_a): return [0], "GetItemNumInPack": func(_a): return [0],
		"GetHostSubProfLevel": func(_a): return [0], "GetHostRepuValue": func(_a): return [0]}
	var names: Array = files.list_dir(dir)["files"].filter(func(f): return f.to_lower().begins_with("skilldesc") and f.to_lower().ends_with(".lua"))
	names.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	var order = FIRST.duplicate()
	for f in names:
		if not f.to_lower() in FIRST:
			order.append(f)
	order.append_array(LAST)
	for f in order:
		var p = files.resolve(f, dir)
		if p != "" and files.file_exists(p):
			var err = _lua.run_file(p)
			if err != "":
				errors.append("%s: %s" % [f, err])
	_sd = _lua.globals.get("SkillDesc")
	if not _sd is Dictionary:
		return "SkillDesc fehlt in den Skripten"
	_read_cn_names()
	return "" # Symbol-Atlas erst beim ersten icon() (Textur im Haupt-Thread)

func close() -> void:
	if _lua != null:
		_lua.close()
	_lua = null
	_sd = null

func skill_name(id: int) -> String:
	if _sd == null:
		return str(id)
	var r = _lua._call(_sd["GetSkillName"], [_sd, id])
	var s = r[0] if r is Array and not r.is_empty() else null
	return s if s is String and not s.begins_with("GetSkillName Error") else _cn.get(id, str(id))

func desc(id: int, level: int, context: int = CONTEXT_SKILL) -> String:
	if _sd == null:
		return ""
	var lv = maxi(1, level)
	var info = {"level": lv, "baseLevel": lv, "extralevel": 0, "maxLevel": lv, "maxLearnLevel": lv, "nextLevel": lv + 1,
		"nextRequiredPlayerLevel": 9999, "nextRequiredPlayerSecLevel": 0, "nextCostSp": 0, "bTalent": false,
		"costMPReduceRate": 0, "requiredSkillID": 0, "requiredSkillSP": 0, "beliefUIPosH": 0, "beliefUIPosV": 0, "beliefGod": -1}
	var r = _lua._call(_sd["GetDesc"], [_sd, id, context, info])
	var s = r[0] if r is Array and not r.is_empty() else null
	return s if s is String else ""

# Angelica-Text -> BBCode (Zeilen \r, Spalten \v als Abstand, Farben / Schriftwechsel wie der UI-Builder)
static func bbcode(s: String) -> String:
	var t = s.replace("\r\n", "\n").replace("\r", "\n").replace("\v", "    ")
	return load("res://addons/PWE-Manager/UI-XML/angelica_ui_builder.gd")._bbcode(t, 0)

func icon(id: int) -> Texture2D:
	if _icons.has(id):
		return _icons[id]
	if not _icons_read:
		_icons_read = true
		_read_icons()
	var tex: AtlasTexture = null
	var i = _icon_of(id)
	if i >= 0 and _atlas != null:
		tex = AtlasTexture.new()
		tex.atlas = _atlas
		tex.region = Rect2((i % _cols) * _cell.x, (i / _cols) * _cell.y, _cell.x, _cell.y)
	_icons[id] = tex
	return tex

# Symbol-Nummer im Atlas über den chinesischen Namen, -1 ohne
func _icon_of(id: int) -> int:
	if ICON_ALIAS.has(id) and _icon_index.has(ICON_ALIAS[id]):
		return _icon_index[ICON_ALIAS[id]]
	var cn = str(_cn.get(id, "")).to_lower()
	if cn == "":
		return -1
	if _icon_index.has(cn + ".dds"):
		return _icon_index[cn + ".dds"]
	var tail = "_" + cn + ".dds"
	var prefixes: Array = CLASS_PREFIX.get(int(skill_class.get(id, 0)), [])
	var best = ""
	var best_score = INF
	for h in _icon_names:
		if not h.ends_with(tail):
			continue
		var score = h.length() + (0 if prefixes.any(func(p): return h.begins_with(p)) else 1000)
		if score < best_score:
			best_score = score
			best = h
	return _icon_index[best] if best != "" else -1

func _find_dir() -> String:
	for base in [language + "/" + SKILL_DIR, "resources/" + language + "/" + SKILL_DIR, "resources/" + SKILL_DIR]:
		var p = files.resolve(base)
		if p != "" and files.dir_exists(p):
			return p
	return ""

# configs\skillstr.txt (UTF-16): Zeilen <Nummer> "Text"; Nummer = ID * 10 ist der Name
func _read_cn_names() -> void:
	var p = files.resolve("resources/configs/skillstr.txt")
	if p == "":
		p = files.resolve("configs/skillstr.txt")
	if p == "" or not files.file_exists(p):
		return
	var b: PackedByteArray = files.get_bytes(p)
	var t = b.slice(2).get_string_from_utf16() if b.size() > 1 and b[0] == 0xFF and b[1] == 0xFE else b.get_string_from_utf8()
	var re = RegEx.create_from_string("^(\\d+)0\\s+\"([^\"\\r\\n]*)")
	for line in t.split("\n"):
		var m = re.search(line)
		if m != null:
			_cn[m.get_string(1).to_int()] = m.get_string(2)

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
		if key != "":
			_icon_names.append(key)
			if not _icon_index.has(key):
				_icon_index[key] = i - 4
