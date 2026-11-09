extends Control

# ====================================================
# Spiel-Oberfläche zur Laufzeit (wie AUIManager): baut Dialoge aus den Spieldaten mit dem Plugin
# (angelica_ui.gd lesen, angelica_ui_builder.gd bauen, ohne etwas zu speichern), ordnet sie wie
# die Dialog-Liste (.dcf) an und zeigt Meldungsfenster.
#   setup(Datenordner, Sprache) -> "" oder Fehler     load_layout("loginui")  (.dcf + .stf)
#   dialog("Login.xml") -> aui_dialog.gd (einmal gebaut, danach wiederverwendet; auch eigene
#                          Dialoge als Pfad res://...xml)
#   show_dialog / hide_dialog, set_background(Bild der Spieldaten, auf den Bildschirm gestreckt)
#   set_scene(Textur): Ebene zwischen Hintergrund und Dialogen (z.B. 3D-Vorschau einer Figur)
#   texture(Bild der Spieldaten) -> Texture2D
#   await message_box(Text, MB_OK / MB_OKCANCEL / MB_YESNO) -> "IDOK" / "IDCANCEL" / "IDYES" / "IDNO"
#   text(Nummer) aus der Texttabelle der Dialog-Liste
# Position (AUIDialog::TranslatePosForAlign): x / y = -1 mittig, < -1 rechts / unten bündig
# (x + Breite - Dialogbreite + 2), sonst links / oben. Das Spiel ist für 1024 x 768 gebaut: ist
# das Fenster kleiner, wird die ganze Oberfläche verkleinert (nie vergrößert).
# Meldungsfenster wie AUIManager::MessageBox: Rahmen MsgBoxFrame.tga, Knöpfe Button\Button.tga,
# Texte der Knöpfe aus MsgBox.stf, Größe aus Text und Rahmen; modal (darunter ist alles gesperrt,
# auch der Tastatur-Fokus: ein DEFAULT_-Feld, das sich beim Zeigen seines Dialogs verzögert den Fokus
# holt, schluckte sonst Enter für das Meldungsfenster - es bekommt ihn erst nach dem Schließen).
# Esc / Enter gehen an das oberste Meldungsfenster bzw. den obersten Dialog (aui_dialog.gd).
# ====================================================

const Dialog = preload("aui_dialog.gd")
const UI = "res://addons/PWE-Manager/UI-XML/angelica_ui.gd"
const UI_BUILDER = "res://addons/PWE-Manager/UI-XML/angelica_ui_builder.gd"
const FILES = "res://addons/PWE-Manager/Data/angelica_files.gd"
const DESIGN = Vector2(1024, 768)
const MSGBOX_FRAME = "MsgBoxFrame.tga"
const MSGBOX_BUTTON = "Button\\Button.tga"
const MSGBOX_BUTTON_DOWN = "Button\\ButtonDown.tga"
const MSGBOX_BUTTON_HOVER = "Button\\ButtonHover.tga"
const MSGBOX_COLOR = Color.WHITE
const MSGBOX_LINE_SPACE = 3
const ID_TEXT = {"IDOK": 1, "IDCANCEL": 2, "IDYES": 6, "IDNO": 7} # Windows-Werte, Nummern in MsgBox.stf

enum {MB_OK, MB_OKCANCEL, MB_YESNO}

var ui # angelica_ui.gd
var builder # angelica_ui_builder.gd
var language = ""
var strings = {} # Texttabelle der geladenen Dialog-Liste
var warnings: Array = []
var keys_enabled = true # Enter / Esc an den obersten Dialog (das HUD schaltet das ab und verteilt selbst)
var _layout = {} # Dialog-Datei (klein) -> Vector2i aus der .dcf
var _by_file = {} # Dialog-Datei (klein) -> Dialog
var _msg_strings = {}
var _background: TextureRect
var _scene: TextureRect
var _back: Control # Hintergrund-Dialoge
var _front: Control # übrige Dialoge
var _top: Control # Meldungsfenster
var _blocker: ColorRect
var _focus_after_box: Control # wollte den Fokus, während ein Meldungsfenster offen war
var _scale = 1.0


# Gibt es Dialoge der Sprache unter dem Datenordner (entpackt oder in den .pck)?
static func data_available(data_root: String, lang: String) -> bool:
	if not DirAccess.dir_exists_absolute(data_root) or not ResourceLoader.exists(FILES):
		return false
	var files = load(FILES).new(data_root)
	for base in [lang, "resources/" + lang]:
		if files.resolve(base + "/interfaces") != "":
			return true
	return false

func _init() -> void:
	name = "AUI"
	mouse_filter = MOUSE_FILTER_IGNORE
	_background = TextureRect.new()
	_background.name = "Hintergrund"
	_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_background.stretch_mode = TextureRect.STRETCH_SCALE
	_background.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_background)
	_scene = TextureRect.new()
	_scene.name = "Szene"
	_scene.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scene.stretch_mode = TextureRect.STRETCH_SCALE
	_scene.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_scene)
	_back = _layer("Hintergrund-Dialoge")
	_front = _layer("Dialoge")
	_top = _layer("Meldungen")
	_blocker = ColorRect.new()
	_blocker.name = "Sperre"
	_blocker.color = Color(0, 0, 0, 0)
	_blocker.mouse_filter = MOUSE_FILTER_STOP
	_blocker.visible = false
	_top.add_child(_blocker)

func setup(data_root: String, lang: String) -> String:
	if not ResourceLoader.exists(UI_BUILDER):
		return "Plugin PWE-Manager fehlt"
	if not data_available(data_root, lang):
		return "Keine Oberfläche unter %s für Sprache %s" % [data_root, lang]
	language = lang
	ui = load(UI).new(data_root, lang)
	builder = load(UI_BUILDER).new(ui)
	builder.save_files = false
	_msg_strings = ui.read_string_table("MsgBox.stf")
	return ""

func _ready() -> void:
	get_viewport().size_changed.connect(_relayout)
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	_relayout()

func _layer(layer_name: String) -> Control:
	var c = Control.new()
	c.name = layer_name
	c.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(c)
	return c


# ====================================================
# DIALOGE
# ====================================================
# Dialog-Liste (.dcf) und Texttabelle (.stf) laden -> Anzahl der Einträge (0 = Liste fehlt)
func load_layout(layout_name: String) -> int:
	_layout = {}
	for e in ui.read_layout(layout_name):
		_layout[e["file"].to_lower()] = Vector2i(e["x"], e["y"])
	strings = ui.read_string_table(layout_name)
	return _layout.size()

func text(id: int) -> String:
	return str(strings.get(id, ""))

func dialog(file_name: String) -> Dialog:
	var key = file_name.get_file().to_lower()
	if _by_file.has(key):
		return _by_file[key]
	var d = ui.read_dialog(file_name)
	if d.is_empty():
		_warn("Dialog %s nicht gefunden" % file_name)
		return null
	var dlg = _wrap(builder.build_dialog(d))
	dlg.layout_pos = _layout.get(key, Vector2i(-1, -1))
	_by_file[key] = dlg
	_place(dlg)
	return dlg

func show_dialog(dlg: Dialog) -> void:
	if dlg == null:
		return
	dlg.get_parent().move_child(dlg, -1)
	_place(dlg)
	dlg.open()

func hide_dialog(dlg: Dialog) -> void:
	if dlg != null:
		dlg.close()

func set_background(file_name: String) -> void:
	var path = ui.surface(file_name)
	var img = builder._images.image_file(path) if path != "" else null
	if img == null:
		_warn("Hintergrund %s nicht lesbar" % file_name)
		_background.texture = null
		return
	if img.is_compressed():
		img.decompress()
	_background.texture = ImageTexture.create_from_image(img)

func clear_background() -> void:
	_background.texture = null

func set_scene(tex: Texture2D) -> void:
	_scene.texture = tex

func texture(file_name: String) -> Texture2D:
	return builder._texture(_resource(file_name))

func screen_size() -> Vector2:
	return size

func _wrap(content: Control) -> Dialog:
	for w in builder.warnings:
		_warn(w)
	builder.warnings.clear()
	var dlg = Dialog.new()
	dlg.builder = builder
	dlg.setup(content)
	(_back if dlg.background else _front).add_child(dlg)
	return dlg

func _place(dlg: Dialog) -> void:
	var s = dlg.size
	var x = dlg.layout_pos.x
	var y = dlg.layout_pos.y
	if x == -1:
		x = int((size.x - s.x) / 2)
	elif x < -1:
		x += int(size.x - s.x) + 2
	if y == -1:
		y = int((size.y - s.y) / 2)
	elif y < -1:
		y += int(size.y - s.y) + 2
	dlg.position = Vector2(x, y)

func _relayout() -> void:
	var vp = get_viewport_rect().size
	_scale = minf(1.0, minf(vp.x / DESIGN.x, vp.y / DESIGN.y))
	scale = Vector2(_scale, _scale)
	position = Vector2.ZERO
	size = vp / _scale
	for layer in [_back, _front, _top]:
		layer.size = size
	_background.size = size
	_scene.size = size
	_blocker.size = size
	for dlg in _by_file.values():
		_place(dlg)
	for c in _top.get_children():
		if c is Dialog:
			_place(c)

func _warn(msg: String) -> void:
	if not msg in warnings:
		warnings.append(msg)
		push_warning("AUI: " + msg)


# ====================================================
# MELDUNGSFENSTER
# ====================================================
func message_box(msg: String, type: int = MB_OK) -> String:
	var dlg = _wrap(builder.build_dialog(_message_box_dialog(msg, type)))
	dlg.message_box = true
	dlg.reparent(_top)
	_place(dlg)
	dlg.open()
	_update_blocker()
	var cmd = await dlg.command
	dlg.queue_free()
	_top.remove_child(dlg)
	_update_blocker()
	if not has_message_box() and is_instance_valid(_focus_after_box) and _focus_after_box.is_visible_in_tree():
		_focus_after_box.grab_focus()
	_focus_after_box = null
	return cmd

func has_message_box() -> bool:
	return _top.get_child_count() > 1

func _on_focus_changed(c: Control) -> void:
	if has_message_box() and c != null and not _top.is_ancestor_of(c):
		_focus_after_box = c
		c.release_focus.call_deferred()

# Dialog wie AUIManager::MessageBox (Rahmen, Beschriftung, 1 - 2 Knöpfe) als Beschreibung für den Builder
func _message_box_dialog(msg: String, type: int) -> Dictionary:
	msg = msg.replace("\r\n", "\n").replace("\r", "\n")
	var defaults = ui.ui_defaults(strings) if not strings.is_empty() else {"font": "", "size": 10}
	var t = {"string": msg, "font": defaults["font"], "size": int(strings.get(5, defaults["size"])),
		"color": MSGBOX_COLOR, "shadow": Color(0, 0, 0, 1)}
	var font_px = maxi(1, roundi(t["size"] * 96.0 / 72.0))
	var ts: Vector2 = builder._text_size(msg, t, MSGBOX_LINE_SPACE)
	var text_h = roundi(builder._font(t).get_height(font_px)) if builder._font(t) != null else font_px
	var lines = msg.count("\n") + 1
	var frame = _resource(MSGBOX_FRAME)
	var limit = Vector2i.ZERO
	var frame_tex = builder._texture(frame)
	if frame_tex != null:
		var m = builder._frame_margins(frame_tex.get_size(), 0)
		limit = Vector2i(m.x * 2, m.y * 2)
	var buttons = {MB_OK: ["IDOK"], MB_OKCANCEL: ["IDOK", "IDCANCEL"], MB_YESNO: ["IDYES", "IDNO"]}[type]
	var res = {"FrameUpImage": _resource(MSGBOX_BUTTON), "FrameDownImage": _resource(MSGBOX_BUTTON_DOWN)}
	if ui.surface(MSGBOX_BUTTON_HOVER) != "":
		res["FrameOnHoverImage"] = _resource(MSGBOX_BUTTON_HOVER)
	var button_size = Vector2i.ZERO
	var up_tex = builder._texture(res["FrameUpImage"])
	if up_tex != null:
		var bm = builder._frame_margins(up_tex.get_size(), 0)
		button_size = Vector2i(bm.x * 2, bm.y * 2)
	button_size += Vector2i(text_h * 4, text_h)
	var h = limit.y + text_h * (lines + 2) + button_size.y + text_h * 2
	var w = limit.x + maxi(int(ts.x) + text_h * 2, (buttons.size() + 1) * button_size.x)
	var controls = [_control("LABEL", "Txt_Message", Rect2i((w - int(ts.x)) / 2, limit.y / 2 + text_h, int(ts.x) + 2, int(ts.y) + 2), t, {},
		{"line_space": MSGBOX_LINE_SPACE})]
	var by = h - limit.y / 2 - text_h - button_size.y
	for i in buttons.size():
		var bx = (w - button_size.x) / 2
		if buttons.size() == 2:
			bx = w / 2 - button_size.x - text_h / 2 if i == 0 else w / 2 + text_h / 2
		var bt = t.duplicate()
		bt["string"] = str(_msg_strings.get(ID_TEXT[buttons[i]], buttons[i]))
		controls.append(_control("STILLIMAGEBUTTON", "Btn_" + buttons[i], Rect2i(bx, by, button_size.x, button_size.y), bt, res,
			{"command": buttons[i]}))
	return {"file": "", "name": "MsgBox", "rect": Rect2i(0, 0, w, h), "props": {"CanEscClose": true}, "frame": frame,
		"sound": "", "sound_close": "", "controls": controls, "item": null}

func _resource(file_name: String) -> Dictionary:
	return {"file": file_name, "path": ui.surface(file_name), "gfx": false}

func _control(type: String, ctl_name: String, rect: Rect2i, t: Dictionary, res: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var c = {"type": type, "name": ctl_name, "rect": rect, "show": true, "enable": true, "template": "", "command": "",
		"sound": "", "text": t, "hint": "", "resources": res, "attrs": {}, "item": null}
	c.merge(extra, true)
	return c

func _update_blocker() -> void:
	var n = _top.get_child_count()
	_blocker.visible = n > 1
	if n > 1:
		_top.move_child(_blocker, n - 2) # direkt unter dem obersten Meldungsfenster


# ====================================================
# TASTEN
# ====================================================
func _unhandled_key_input(event: InputEvent) -> void:
	var k = event as InputEventKey
	if k == null or not k.pressed or k.echo or (not keys_enabled and not has_message_box()):
		return
	var target = _top_dialog()
	if target == null:
		return
	if k.keycode == KEY_ESCAPE and (target.can_esc_close or target.message_box):
		target.send("IDCANCEL")
		get_viewport().set_input_as_handled()
	elif k.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		target.send("IDOK")
		get_viewport().set_input_as_handled()

# Oberstes Meldungsfenster, sonst der oberste sichtbare Dialog
func _top_dialog() -> Dialog:
	for layer in [_top, _front, _back]:
		for i in range(layer.get_child_count() - 1, -1, -1):
			var c = layer.get_child(i)
			if c is Dialog and c.visible:
				return c
	return null
