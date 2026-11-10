@tool
extends RefCounted

# ====================================================
# Oberfläche der Angelica-Engine (AUIManager / AUIDialog) lesen: Dialoge (interfaces\*.xml),
# Dialog-Listen (.dcf) und Texttabellen (.stf), je Sprache.
# Sprachen: die Ordner interfaces\ und surfaces\ gibt es je Sprache, unter <root>/<Sprache>/ oder
# <root>/resources/<Sprache>/ (z.B. Deu, Franz); ohne Sprache gilt <root>/resources/. Fehlt eine
# Bilddatei im Sprachordner, wird sie in resources/surfaces/ gesucht.
# Dialog-Listen (AUIManager::LoadDialogLayout, AScriptFile): je Zeile Datei, x, y, sichtbar;
# Zeilen mit "#" oder "//" zählen nicht. 1gameui / 2gameui sind zwei Oberflächen-Stile des
# Spiels (Dateien mit Präfix 1 / 2), gameui der alte, dazu loginui und loadingui.
# Texttabellen (ImportStringTable, AWScriptFile): Nummer und "Text" im Wechsel, Text durch
# AUICTranslate (\n, \t, \", oktal). Nummer 1 = Standardschrift, 2 = Schriftgröße, 3 = Breite
# eines Tabs in "W", 4 / 5 Schriftgröße von Bildfeldern / Meldungsfenstern.
# Dialog (AUIDialog::InitFromXML): <DIALOG> mit Rahmenbild und Steuerelementen als Kindern:
#   CHECK, COMBO, CONSOLE, EDIT, IMAGEPICTURE, LABEL, LIST, LIST2, PROGRESS, RADIO, SCROLL, SLIDER,
#   STILLIMAGEBUTTON, SUBDIALOG, SUBVIEW, TEXT, TREE, VERTICALTEXT, WINDOWPICTURE
# (andere Namen übergeht das Spiel). Jedes Steuerelement hat Name, x, y, Width, Height und Kinder
#   <Text>     Schrift und Text (String; nur LABEL und TEXT lösen Escape-Folgen auf)
#   <Hint>     Tooltip (String, Escape-Folgen aufgelöst)
#   <Resource> Bilder (FrameImage, FrameUpImage, ... : FileName relativ zu surfaces\) und GFX
#              (Gfx, GfxDown, GfxOnHover: FileName relativ zu gfx\)
# Mehrere gleichnamige Kinder werden nacheinander gelesen, spätere Werte überschreiben frühere.
# Texte können Farbcodes enthalten (^RRGGBB, ^O...), sie bleiben unverändert.
# Alles weitere je Typ steht roh in "attrs" und im XML-Element "item" (Abfragen: angelica_xml.gd).
# ====================================================

const XML = preload("angelica_xml.gd")
const Files = preload("../Data/angelica_files.gd")

const CONTROL_TYPES = ["CHECK", "COMBO", "CONSOLE", "EDIT", "IMAGEPICTURE", "LABEL", "LIST", "LIST2",
	"PROGRESS", "RADIO", "SCROLL", "SLIDER", "STILLIMAGEBUTTON", "SUBDIALOG", "SUBVIEW", "TEXT", "TREE",
	"VERTICALTEXT", "WINDOWPICTURE"]
const TRANSLATED_TEXT = ["LABEL", "TEXT"] # AUILabel / AUITextArea::InitXML
const LAYOUTS = ["1gameui", "2gameui", "gameui", "loginui", "loadingui"]
# Schriftname -> Datei in <root>/font/ (A3DFTFontMan _font_inner_map, 方正兰亭黑体 nach dem
# Dateinamen); unbekannte Namen (宋体) nimmt das Spiel aus Windows, hier die Standardschrift
const DEFAULT_FONT = "方正细黑一简体"
const FONT_FILES = {
	"方正细黑一简体": "fzxh1jw.ttf",
	"方正隶二简体": "fzl2jw.ttf",
	"方正隶变简体": "fzlbjw.ttf",
	"方正兰亭黑体": "fzlthk.ttf",
}
# Wahrheitswerte und Zahlen der Steuerelemente und Ressourcen, die read_dialog umwandelt
const BOOL_KEYS = ["Anomaly", "ReadOnly", "WantReturn", "NumberOnly", "Multiline",
	"Password", "AutoReturn", "EnableSelection", "RenderTop", "VerticalProgress",
	"ReverseDirection", "HoverHilight", "AutoWrap", "LongHilightBar", "TextTransparent",
	"TransScrollWheel", "LeftScrollBar", "ExtendAsCircular", "ForceDynamicRender"]
const INT_KEYS = ["Align", "AlignStyle", "LineSpace", "TextOffsetX", "TextOffsetY", "MaxLen", "ButtonID",
	"GroupID", "TotalLevels", "Indent", "ExtendLength", "TextAlign", "FrameMode", "Frames", "Interval",
	"Degree"]

var files # angelica_files.gd (Pfade, GBK)
var language = "" # Sprachordner (Deu, Franz, ...), "" = resources/
var _interfaces = "" # Ordner der Dialoge dieser Sprache
var _surfaces = "" # Bilder dieser Sprache
var _layout_of = {} # Dialog-Datei (klein) -> erste Dialog-Liste, die sie nennt
var _defaults = {} # Dialog-Liste -> ui_defaults ihrer Texttabelle


func _init(data_root: String = "res://Stock-PWE-Client", lang: String = "", file_access = null) -> void:
	files = file_access if file_access != null else Files.new(data_root)
	set_language(lang)

func set_language(lang: String) -> void:
	language = lang
	_interfaces = _language_dir("interfaces")
	_surfaces = _language_dir("surfaces")
	_layout_of = {}
	_defaults = {}

# Sprachordner unter <root> und <root>/resources mit einem interfaces-Ordner
func languages() -> PackedStringArray:
	var out = PackedStringArray()
	for base in [files.root, files.root.path_join("resources")]:
		for sub in files.list_dir(base)["dirs"]:
			if sub != "resources" and files.resolve("interfaces", base.path_join(sub)) != "" and not out.has(sub):
				out.append(sub)
	return out

func interfaces_dir() -> String:
	return _interfaces

func _language_dir(sub: String) -> String:
	if language != "":
		for base in [language, "resources/" + language]:
			var p = files.resolve(base + "/" + sub)
			if p != "":
				return p
	var common = files.resolve("resources/" + sub)
	if common != "":
		return common
	if sub == "interfaces":
		return files.resolve("interfaces1")
	return files.resolve(sub)


# ====================================================
# PFADE
# ====================================================
# Datei im interfaces-Ordner der Sprache (Groß/Klein egal), "" wenn nicht vorhanden
func interface_file(file_name: String) -> String:
	if file_name.begins_with("res://") or file_name.begins_with("/"):
		return file_name if files.file_exists(file_name) else ""
	return files.resolve(file_name, _interfaces) if _interfaces != "" else ""

# Bild (FileName einer Resource, relativ zu surfaces\): erst im Sprachordner, dann resources/
func surface(file_name: String) -> String:
	if file_name == "":
		return ""
	var p = files.resolve(file_name, _surfaces) if _surfaces != "" else ""
	if p == "":
		p = files.resolve("resources/surfaces/" + file_name)
	return p

# GFX einer Resource (relativ zu gfx\)
func gfx(file_name: String) -> String:
	if file_name == "":
		return ""
	var p = files.resolve("resources/gfx/" + file_name)
	return p if p != "" else files.resolve("gfx/" + file_name)

# Sound (SoundEffect, relativ zum Spielordner: SFX\Interface\...)
func sound(file_name: String) -> String:
	if file_name == "":
		return ""
	var p = files.resolve("resources/" + file_name)
	return p if p != "" else files.resolve(file_name)

# Schriftdatei zu einem Schriftnamen (unbekannt -> Standardschrift)
# Fehlt die Datei einer Schrift im Client (z.B. fzlthk.ttf für 方正兰亭黑体), nimmt Windows eine
# Ersatzschrift: hier die Standardschrift des Spiels
func font(face: String) -> String:
	var p = files.resolve("font/" + FONT_FILES.get(face.strip_edges(), FONT_FILES[DEFAULT_FONT]))
	return p if p != "" else files.resolve("font/" + FONT_FILES[DEFAULT_FONT])


# ====================================================
# DIALOG-LISTEN UND TEXTTABELLEN
# ====================================================
# .dcf -> [{file, path ("" wenn die Datei fehlt), x, y, show}]
func read_layout(file_name: String) -> Array:
	var path = interface_file(file_name if file_name.contains(".") else file_name + ".dcf")
	if path == "":
		return []
	var tokens = _tokens(files.decode(files.get_bytes(path)), true)
	var out = []
	var i = 0
	while i + 3 < tokens.size():
		out.append({
			"file": tokens[i],
			"path": interface_file(tokens[i]),
			"x": XML.atoi(tokens[i + 1]),
			"y": XML.atoi(tokens[i + 2]),
			"show": XML.atoi(tokens[i + 3]) != 0,
		})
		i += 4
	return out

# .stf -> {Nummer: Text}
func read_string_table(file_name: String) -> Dictionary:
	var path = interface_file(file_name if file_name.contains(".") else file_name + ".stf")
	var out = {}
	if path == "":
		return out
	var tokens = _tokens(XML.decode(files.get_bytes(path), files), false)
	var i = 0
	while i + 1 < tokens.size():
		out[XML.atoi(tokens[i])] = translate(tokens[i + 1])
		i += 2
	return out

# Dialog-Liste (LAYOUTS), die eine Dialog-Datei nennt ("" = keine)
func layout_of(file_name: String) -> String:
	if _layout_of.is_empty():
		_layout_of[""] = ""
		for lay in LAYOUTS:
			for e in read_layout(lay):
				var key = e["file"].to_lower()
				if not _layout_of.has(key):
					_layout_of[key] = lay
	return _layout_of.get(file_name.get_file().to_lower(), "")

# Standardschrift / -größe für einen Dialog: aus der Texttabelle seiner Dialog-Liste (wie der
# AUIManager, der ihn lädt), ohne Liste die von gameui
func text_defaults(file_name: String) -> Dictionary:
	var lay = layout_of(file_name)
	if lay == "":
		lay = "gameui"
	if not _defaults.has(lay):
		_defaults[lay] = ui_defaults(read_string_table(lay))
	return _defaults[lay]

# Standardschrift und -größe einer Texttabelle (wie ImportStringTable, Lücken mit Engine-Werten)
static func ui_defaults(table: Dictionary) -> Dictionary:
	var face = table.get(1, "")
	var size = table.get(2, "")
	var tab = table.get(3, "")
	return {
		"font": face if face != "" else DEFAULT_FONT,
		"size": XML.atoi(size) if size != "" else 10,
		"tab_chars": XML.atoi(tab) if tab != "" else 30,
	}

# AScriptFile / AWScriptFile::GetNextToken über die ganze Datei. Token: "..." (ohne Escape) oder
# Folge von Zeichen > 32 außer ";" und ","; "//" bis Zeilenende und /* */ sind Kommentar.
# skip_hash: ein Token "#" überspringt den Rest der Zeile (LoadDialogLayout, SkipLine).
static func _tokens(text: String, skip_hash: bool) -> PackedStringArray:
	var out = PackedStringArray()
	var i = 0
	var n = text.length()
	while i < n:
		var c = text.unicode_at(i)
		if c <= 32 or c == 59 or c == 44 or c == 0xFEFF: # ; ,
			i += 1
			continue
		if c == 47 and i + 1 < n and text[i + 1] == "/": # //
			var e = text.find("\n", i)
			i = n if e < 0 else e
			continue
		if skip_hash and c == 35 and (i + 1 >= n or text.unicode_at(i + 1) <= 32): # "#"
			var e = text.find("\n", i)
			i = n if e < 0 else e
			continue
		if c == 47 and i + 1 < n and text[i + 1] == "*": # /* */
			var e = text.find("*/", i + 2)
			i = n if e < 0 else e + 2
			continue
		if c == 34 or c == 40: # " oder (
			var e = text.find("\"" if c == 34 else ")", i + 1)
			if e < 0:
				e = n
			out.append(text.substr(i + 1, e - i - 1))
			i = e + 1
			continue
		var j = i
		while i < n:
			c = text.unicode_at(i)
			if c <= 32 or c == 59 or c == 44:
				break
			i += 1
		out.append(text.substr(j, i - j))
	return out

# AUICTranslate::Translate: \n \r \t \v \" \' \\, \ooo (oktal, max. 3 Ziffern, <= 255),
# "\" vor Zeilenende verbindet Zeilen, sonst fällt "\" weg
static func translate(s: String) -> String:
	if not s.contains("\\"):
		return s
	var out = ""
	var i = 0
	var n = s.length()
	while i < n:
		var c = s[i]
		if c != "\\":
			out += c
			i += 1
			continue
		i += 1
		if i >= n:
			break
		c = s[i]
		match c:
			"\n":
				i += 1
			"0", "1", "2", "3", "4", "5", "6", "7":
				var v = 0
				var count = 3
				while i < n and count > 0 and s[i] >= "0" and s[i] <= "7":
					v = v * 8 + s.unicode_at(i) - 48
					i += 1
					count -= 1
				if v <= 255:
					out += char(v)
			"\"", "'", "\\":
				out += c
				i += 1
			"n":
				out += "\n"
				i += 1
			"r":
				out += "\r"
				i += 1
			"t":
				out += "\t"
				i += 1
			"v":
				out += char(11)
				i += 1
	return out


# ====================================================
# DIALOG
# ====================================================
# Dialog (Dateiname im interfaces-Ordner oder res://-Pfad) -> {} wenn nicht lesbar, sonst
# {file, name, rect, props, frame, sound, sound_close, controls, item}
#   props:    Schalter des Dialogs (CanMove, CanEscClose, PopupDialog, Alpha, HintDelay, ...)
#   frame:    Rahmenbild wie eine Resource (siehe unten), {} wenn keins
#   controls: [{type, name, rect, show, enable, template, command, sound, align, text, hint,
#               resources, attrs, item}] in Dateireihenfolge (= Zeichenreihenfolge)
#   text:     {} oder {string, font, size, color, shadow, outline, outline_color, bold, italic,
#               ...} nur mit den Werten der Datei (Standard: ui_defaults, Farbe weiß)
#   resources: {Elementname: {file, path, ...}} (FrameImage, FrameUpImage, Gfx, ...)
func read_dialog(file_name: String) -> Dictionary:
	var path = interface_file(file_name)
	if path == "":
		return {}
	var top = XML.load_file(path, files).get("children", [])
	var item = top[0] if not top.is_empty() else {}
	if item.is_empty() or item["name"].nocasecmp_to("DIALOG") != 0:
		return {}
	var props = {}
	for key in ["CanMove", "CanChangeZOrder", "CanEscClose", "PopupDialog", "ImageCoverOrderly", "Anomaly",
			"BackgroundDialog", "CanOutOfWindow", "FullScreen", "StaticRender"]:
		if XML.has_value(item, key):
			props[key] = XML.bool_value(item, key)
	for key in ["Alpha", "HintDelay", "MinDistDlgRToScrL", "MinDistDlgLToScrR", "MinDistDlgBToScrT",
			"MinDistDlgTToScrB"]:
		if XML.has_value(item, key):
			props[key] = XML.int_value(item, key)
	var frame = {}
	for res in XML.children(item, "Resource"):
		var img = XML.child(res, "FrameImage")
		if not img.is_empty():
			frame = _resource(img)
	var controls = []
	for c in item["children"]:
		if CONTROL_TYPES.has(c["name"].to_upper()):
			controls.append(read_control(c))
	return {
		"file": path,
		"name": XML.string_value(item, "Name"),
		"rect": _rect(item),
		"props": props,
		"frame": frame,
		"sound": sound(XML.string_value(item, "SoundEffect")),
		"sound_close": sound(XML.string_value(item, "SoundEffectClose")),
		"controls": controls,
		"item": item,
	}

func read_control(c: Dictionary) -> Dictionary:
	var type = c["name"].to_upper()
	var attrs = XML.attributes(c)
	var text = {}
	var hint = ""
	var resources = {}
	for k in c["children"]:
		var kind = k["name"].to_lower()
		if kind == "text":
			_read_text(k, text, TRANSLATED_TEXT.has(type))
		elif kind == "hint":
			hint = translate(XML.string_value(k, "String"))
		elif kind == "resource":
			for r in k["children"]:
				resources[r["name"]] = _resource(r)
	var out = {
		"type": type,
		"name": XML.string_value(c, "Name"),
		"rect": _rect(c),
		"show": XML.bool_value(c, "Show", true),
		"enable": XML.bool_value(c, "Enable", true),
		"template": XML.string_value(c, "Template"),
		"command": XML.string_value(c, "Command"),
		"sound": sound(XML.string_value(c, "SoundEffect")),
		"text": text,
		"hint": hint,
		"resources": resources,
		"attrs": attrs,
		"item": c,
	}
	for key in BOOL_KEYS:
		if XML.has_value(c, key):
			out[key.to_snake_case()] = XML.bool_value(c, key)
	for key in INT_KEYS:
		if XML.has_value(c, key):
			out[key.to_snake_case()] = XML.int_value(c, key)
	if type == "SUBDIALOG":
		out["dialog_file"] = XML.string_value(c, "DialogFile")
	return out

# <Text>: Werte der Datei in text eintragen (später gelesene überschreiben)
func _read_text(k: Dictionary, text: Dictionary, translated: bool) -> void:
	if XML.has_value(k, "String"):
		var s = XML.string_value(k, "String")
		text["string"] = translate(s) if translated else s
	if XML.has_value(k, "FontName"):
		var face = XML.string_value(k, "FontName")
		text["font"] = face
		text["font_file"] = font(face)
	if XML.has_value(k, "FontSize"):
		text["size"] = XML.int_value(k, "FontSize")
	if XML.has_value(k, "Shadow"): # Deckkraft eines schwarzen Schattens
		text["shadow"] = Color8(0, 0, 0, XML.int_value(k, "Shadow") & 0xFF)
	for key in ["Color", "ShadowColor", "OutlineColor", "InnerTextColor", "TextUpperColor", "TextLowerColor",
			"TextHoverColor", "TextCheckColor", "CheckColor", "WordColor", "LinkUnderLineColor"]:
		var col = XML.color_value(k, key)
		if col != null:
			text["shadow" if key == "ShadowColor" else key.to_snake_case()] = col
	for key in ["Outline", "FontPackID", "LineSpace"]:
		if XML.has_value(k, key):
			text[key.to_snake_case()] = XML.int_value(k, key)
	for key in ["Bold", "Italic", "FreeType", "Vertical", "FadeColor", "HoverColor"]:
		if XML.has_value(k, key):
			text[key.to_snake_case()] = XML.bool_value(k, key)

# Resource-Kind -> {file, path, frames, frame_mode, interval, degree}
func _resource(r: Dictionary) -> Dictionary:
	var file = XML.string_value(r, "FileName")
	var gfx_res = r["name"].to_lower().begins_with("gfx")
	var out = {"file": file, "path": gfx(file) if gfx_res else surface(file), "gfx": gfx_res}
	for key in ["Frames", "FrameMode", "Interval", "Degree"]:
		if XML.has_value(r, key):
			out[key.to_snake_case()] = XML.int_value(r, key)
	return out

static func _rect(item: Dictionary) -> Rect2i:
	return Rect2i(XML.int_value(item, "x"), XML.int_value(item, "y"), XML.int_value(item, "Width"),
		XML.int_value(item, "Height"))
