@tool
extends RefCounted

# ====================================================
# Dialog der Oberfläche (angelica_ui.gd read_dialog) -> Godot-Szene aus Controls, so wie AUI
# zeichnet. Gespeichert unter res://ECM_Import/<Pfad in den Spieldaten>, z.B.
# Deu/interfaces/1action.tscn, Bilder daneben unter Deu/surfaces/... (.res), Schriften unter font/.
#  Rahmen (AUIFrame, FrameMode 0 = automatisch): Bild in 3x3 (Breite und Höhe durch 3 teilbar),
#        4x4 (Ecken je 1/4), 3x1, 1x3 oder 1x1 Stücke; Ecken bleiben, der Rest wird gestreckt
#        -> NinePatchRect / StyleBoxTexture mit diesen Rändern.
#  Bilder (AUIImagePicture): auf die Größe des Elements gestreckt, Frames = waagrechte Streifen
#        untereinander (im Editor Bild 0), Breite / Höhe 0 = Bildgröße.
#  Bilder ohne Alpha: Magenta (255, 0, 255) ist durchsichtig (AUI_COLORKEY).
#  Text: Schriftgröße in Punkt bei 96 dpi (Pixel = Punkt * 4 / 3), Schatten 1 Pixel versetzt,
#        Farbcodes ^RRGGBB / ^U..^u (unterstrichen) -> BBCode; LABEL links (Standard), mittig oder
#        rechts an x bzw. im Rechteck, wenn es Breite und Höhe hat (dann mit Umbruch).
#  Buttons (STILLIMAGEBUTTON): Rahmen je Zustand (Up, Down, OnHover, Disabled), Text mittig
#        (Align, TextOffsetX / Y), gesperrt grau.
#  RADIO / CHECK: Bild je Zustand auf das Element gestreckt (Align mittig) bzw. als Häkchen-Symbol
#        neben dem Text; RADIO mit gleicher GroupID schließen sich aus.
#  EDIT: nur lesend und ohne Text = Hintergrund (NinePatchRect), sonst LineEdit / TextEdit.
#  TEXT, LIST, TREE, COMBO, SCROLL, SLIDER, PROGRESS: passende Godot-Controls mit den Rahmen.
#  SUBDIALOG: der genannte Dialog wird eingebettet (abgeschnitten auf das Rechteck).
#  GFX in der Oberfläche (Gfx, GfxDown, GfxOnHover) sind 3D und fehlen hier, der Pfad steht als
#  Meta "gfx" am Element. Befehl, Sound und Typ stehen als Meta "command", "sound", "aui_type".
# Im Spiel (save_files = false, game/client/ui/aui_manager.gd) wird nichts gespeichert: Bilder und
# Schriften entstehen im Speicher, schon importierte .res unter res://ECM_Import werden genutzt.
# ====================================================

const UI = preload("angelica_ui.gd")
const Builder = preload("../ECM/angelica_model_builder.gd")
const OUT_ROOT = "res://ECM_Import"
const FONT_DIR = "res://ECM_Import/font"
const POINT_TO_PIXEL = 96.0 / 72.0
const MAX_SUB_DEPTH = 4
const PREVIEW_PROGRESS = 100.0 # Füllstand der Fortschrittsbalken im Editor
const DISABLED_TEXT = Color8(128, 128, 128)
const SHADOW_OFFSET = 1
enum { MODE_UNKNOWN, MODE_1X1, MODE_3X3, MODE_4X4, MODE_3X1, MODE_1X3 } # AUIFrame

var ui # angelica_ui.gd (Sprache, Pfade)
var warnings: Array = []
var written: Array = [] # gespeicherte Dateien (für EditorFileSystem.update_file)
var save_files = true # false: Laufzeit, nichts unter res://ECM_Import speichern
var _images = Builder.new(null, null, Callable()) # liest .dds / .tga
var _textures = {} # Quelle -> Texture2D (null = nicht lesbar)
var _fonts = {} # Schriftdatei -> FontFile
var _variants = {} # Schrift + fett / kursiv -> FontVariation
var _defaults = {} # Standardschrift des aktuellen Dialogs
var _groups = {} # GroupID -> ButtonGroup des aktuellen Dialogs
var _depth = 0


func _init(p_ui) -> void:
	ui = p_ui

func warn(msg: String) -> void:
	if not msg in warnings:
		warnings.append(msg)

# Zielpfad unter res://ECM_Import für eine Datei der Spieldaten
func out_path(src: String, new_ext: String) -> String:
	var root: String = ui.files.root
	if not src.begins_with(root + "/"):
		return ""
	return OUT_ROOT.path_join(src.substr(root.length() + 1).get_basename() + new_ext)


# ====================================================
# DIALOG -> SZENE
# ====================================================
# Dialog-Datei (Name im interfaces-Ordner oder Pfad) bauen und speichern
# -> {"scene", "warnings", "written"} oder {"error"}
func import_dialog(file_name: String) -> Dictionary:
	var d = ui.read_dialog(file_name)
	if d.is_empty():
		var path = ui.interface_file(file_name)
		return {"error": (file_name + " nicht gefunden") if path == "" else (path.get_file() + " ist kein Dialog (<DIALOG> fehlt)")}
	var scene_path = out_path(d["file"], ".tscn")
	if scene_path == "":
		return {"error": d["file"] + " liegt nicht in den Spieldaten " + ui.files.root}
	var root = build_dialog(d)
	_set_owner(root, root)
	var packed = PackedScene.new()
	var err = packed.pack(root)
	root.free()
	if err == OK:
		err = _save(packed, scene_path)
	if err != OK:
		return {"error": "Speichern fehlgeschlagen (%s)" % error_string(err)}
	return {"scene": scene_path, "warnings": warnings, "written": written}

# Dialog -> Control (nicht gespeichert)
func build_dialog(d: Dictionary) -> Control:
	var saved_defaults = _defaults
	var saved_groups = _groups
	_defaults = ui.text_defaults(d["file"])
	_groups = {}
	var root = Control.new()
	root.name = _node_name(d["name"] if d["name"] != "" else d["file"].get_file().get_basename())
	root.size = Vector2(d["rect"].size)
	root.set_meta("aui_file", d["file"])
	for key in d["props"]:
		root.set_meta(key.to_snake_case(), d["props"][key])
	if d["sound"] != "":
		root.set_meta("sound", d["sound"])
	if not d["frame"].is_empty():
		var frame = _nine(d["frame"], Rect2i(Vector2i.ZERO, d["rect"].size))
		if frame != null:
			frame.name = "Frame"
			# Alpha gilt nur für den Rahmen des Dialogs, nicht für seine Steuerelemente
			# (AUIDialog::Render: m_pAUIFrameDlg->Render(..., m_nAlpha))
			if d["props"].has("Alpha"):
				frame.modulate.a = clampf(d["props"]["Alpha"] / 255.0, 0.0, 1.0)
			root.add_child(frame)
	var names = {"Frame": true}
	for c in d["controls"]:
		var node = build_control(c)
		if node == null:
			continue
		var n = _node_name(c["name"] if c["name"] != "" else c["type"].capitalize())
		var unique = n
		var k = 2
		while names.has(unique):
			unique = "%s_%d" % [n, k]
			k += 1
		names[unique] = true
		node.name = unique
		root.add_child(node)
	_defaults = saved_defaults
	_groups = saved_groups
	return root

func build_control(c: Dictionary) -> Control:
	var node: Control
	match c["type"]:
		"IMAGEPICTURE": node = _image_picture(c)
		"LABEL": node = _label(c)
		"STILLIMAGEBUTTON": node = _button(c)
		"EDIT": node = _edit(c)
		"TEXT": node = _text_area(c)
		"RADIO", "CHECK": node = _check(c)
		"PROGRESS": node = _progress(c)
		"LIST": node = _list(c)
		"TREE": node = _tree(c)
		"COMBO": node = _combo(c)
		"SCROLL": node = _scroll(c)
		"SLIDER": node = _slider(c)
		"SUBDIALOG": node = _sub_dialog(c)
		_: node = _placeholder(c)
	if node.position == Vector2.ZERO and node.size == Vector2.ZERO: # nicht schon gesetzt
		node.position = Vector2(c["rect"].position)
		node.size = Vector2(c["rect"].size)
	node.visible = c["show"]
	if c["hint"] != "":
		node.tooltip_text = _plain(c["hint"])
	node.set_meta("aui_type", c["type"])
	if c["command"] != "":
		node.set_meta("command", c["command"])
	if c["sound"] != "":
		node.set_meta("sound", c["sound"])
	for res_name in c["resources"]:
		var r = c["resources"][res_name]
		if r["gfx"] and r["file"] != "":
			node.set_meta("gfx" if res_name.to_lower() == "gfx" else res_name.to_snake_case(), r["path"] if r["path"] != "" else r["file"])
	if c.get("render_top", false):
		node.z_index = 1
	return node


# ====================================================
# STEUERELEMENTE
# ====================================================
func _image_picture(c: Dictionary) -> Control:
	var r = c["resources"].get("FrameImage", {})
	var tex = _texture(r)
	var node = TextureRect.new()
	node.mouse_filter = Control.MOUSE_FILTER_PASS if c["hint"] != "" else Control.MOUSE_FILTER_IGNORE
	if tex == null:
		# ohne Bild (z.B. Effekt-Plätze st_1 im Ziel-Fenster, das Spiel setzt das Symbol als Cover): Platz trotzdem
		node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		node.stretch_mode = TextureRect.STRETCH_SCALE
		node.position = Vector2(c["rect"].position)
		node.size = Vector2(c["rect"].size)
		return node
	var frames = maxi(1, r.get("frames", 1))
	var size = tex.get_size()
	var shown: Texture2D = tex
	if frames > 1:
		var atlas = AtlasTexture.new()
		atlas.atlas = tex
		atlas.region = Rect2(0, 0, size.x, floorf(size.y / frames))
		shown = atlas
		node.set_meta("frames", frames)
		if r.get("interval", 0) > 0:
			node.set_meta("interval_ms", r["interval"])
	node.texture = shown
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.stretch_mode = TextureRect.STRETCH_SCALE
	var rect: Rect2i = c["rect"]
	node.position = Vector2(rect.position)
	node.size = Vector2(rect.size.x if rect.size.x > 0 else size.x, rect.size.y if rect.size.y > 0 else floorf(size.y / frames))
	if r.get("degree", 0) != 0:
		node.pivot_offset = node.size / 2.0
		node.rotation_degrees = r["degree"]
	return node

func _label(c: Dictionary) -> Control:
	var t: Dictionary = c["text"]
	var s = _lines(t.get("string", ""))
	var align = c.get("align", 0)
	var rect: Rect2i = c["rect"]
	var boxed = rect.size.x > 0 and rect.size.y > 0
	var node: Control
	if _has_markup(s):
		var rich = RichTextLabel.new()
		rich.bbcode_enabled = true
		rich.text = _bbcode(s, align)
		rich.fit_content = true
		rich.scroll_active = false
		rich.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if boxed else TextServer.AUTOWRAP_OFF
		_text_style(rich, t, "default_color", "normal_font", "normal_font_size")
		node = rich
	else:
		var label = Label.new()
		label.text = s
		label.horizontal_alignment = _halign(align)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if boxed else TextServer.AUTOWRAP_OFF
		_text_style(label, t, "font_color", "font", "font_size")
		node = label
	node.mouse_filter = Control.MOUSE_FILTER_PASS if c["hint"] != "" else Control.MOUSE_FILTER_IGNORE
	if c.has("line_space"):
		node.add_theme_constant_override("line_separation", c["line_space"])
	if boxed:
		node.position = Vector2(rect.position)
		node.size = Vector2(rect.size)
	else:
		# AUILabel::Render: mittig x + Breite / 2 - Textbreite / 2, rechts x + Breite - Textbreite
		var ts = _text_size(_plain(s), t, c.get("line_space", 0))
		var x = float(rect.position.x)
		if align == 1:
			x += rect.size.x / 2.0 - ts.x / 2.0
		elif align == 2:
			x += rect.size.x - ts.x
		node.position = Vector2(roundf(x), rect.position.y)
		node.size = ts
	return node

func _button(c: Dictionary) -> Control:
	var b = Button.new()
	var res: Dictionary = c["resources"]
	var up = _frame_style(res.get("FrameUpImage", {}))
	var states = {
		"normal": up,
		"pressed": _frame_style(res.get("FrameDownImage", {})),
		"hover": _frame_style(res.get("FrameOnHoverImage", {})),
		"disabled": _frame_style(res.get("FrameDisabledImage", {})),
	}
	var t: Dictionary = c["text"]
	b.text = _lines(t.get("string", ""))
	b.clip_text = true
	b.focus_mode = Control.FOCUS_NONE
	var align = c.get("align", 1)
	b.alignment = _halign(align)
	b.disabled = not c["enable"]
	_text_style(b, t, "font_color", "font", "font_size")
	var col = t.get("color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", col)
	b.add_theme_color_override("font_hover_color", t.get("text_hover_color", col) if t.get("hover_color", false) else col)
	b.add_theme_color_override("font_hover_pressed_color", col)
	b.add_theme_color_override("font_focus_color", col)
	b.add_theme_color_override("font_disabled_color", DISABLED_TEXT)
	# AUIFrame::Render: Text senkrecht mittig, waagrecht mittig / ab W / bis W vor dem Rand
	# (W = Drittel der Bildbreite bei 3x3 / 3x1, sonst ganze Bildbreite), dazu TextOffsetX / Y
	var w = 0.0
	if up != null:
		var m = _frame_margins(up.texture.get_size(), res["FrameUpImage"].get("frame_mode", MODE_UNKNOWN))
		w = m.x if m.z in [MODE_3X3, MODE_3X1] else up.texture.get_size().x
	var dx = c.get("text_offset_x", 0)
	var dy = c.get("text_offset_y", 0)
	var margins = [maxf(0.0, 2.0 * dx), maxf(0.0, 2.0 * dy), maxf(0.0, -2.0 * dx), maxf(0.0, -2.0 * dy)]
	if align == 0:
		margins[0] = maxf(0.0, w + dx)
		margins[2] = 0.0
	elif align == 2:
		margins[0] = 0.0
		margins[2] = maxf(0.0, w - dx)
	for state in states:
		var sb = states[state] if states[state] != null else up
		if sb == null:
			sb = StyleBoxEmpty.new()
		else:
			sb = sb.duplicate()
		sb.content_margin_left = margins[0]
		sb.content_margin_top = margins[1]
		sb.content_margin_right = margins[2]
		sb.content_margin_bottom = margins[3]
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_stylebox_override("hover_pressed", b.get_theme_stylebox("pressed"))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b

func _edit(c: Dictionary) -> Control:
	var res: Dictionary = c["resources"]
	var t: Dictionary = c["text"]
	var text = _lines(t.get("string", ""))
	if c.get("read_only", false) and text == "":
		var bg = _nine(res.get("FrameImage", {}), c["rect"])
		if bg != null:
			return bg
		var empty = Control.new()
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return empty
	var style = _frame_style(res.get("FrameImage", {}))
	var node: Control
	if c.get("multiline", false):
		var te = TextEdit.new()
		te.text = text
		te.editable = not c.get("read_only", false)
		te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		_text_style(te, t, "font_color", "font", "font_size")
		te.add_theme_color_override("font_readonly_color", t.get("color", Color.WHITE))
		node = te
	else:
		var le = LineEdit.new()
		le.text = text
		le.editable = not c.get("read_only", false)
		le.secret = c.get("password", false)
		if c.get("max_len", 0) > 0:
			le.max_length = c["max_len"]
		_text_style(le, t, "font_color", "font", "font_size")
		le.add_theme_color_override("font_uneditable_color", t.get("color", Color.WHITE))
		node = le
	var sb = style if style != null else StyleBoxEmpty.new()
	for state in ["normal", "focus", "read_only"]:
		node.add_theme_stylebox_override(state, sb)
	return node

func _text_area(c: Dictionary) -> Control:
	var t: Dictionary = c["text"]
	var rich = RichTextLabel.new()
	rich.bbcode_enabled = true
	rich.text = _bbcode(_lines(t.get("string", "")), 0)
	rich.scroll_active = false
	rich.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_style(rich, t, "default_color", "normal_font", "normal_font_size")
	if c.has("line_space"):
		rich.add_theme_constant_override("line_separation", c["line_space"])
	var style = _frame_style(c["resources"].get("FrameImage", {}))
	rich.add_theme_stylebox_override("normal", style if style != null else StyleBoxEmpty.new())
	rich.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return rich

# AUICheckBox / AUIRadioButton: mittig = Bild auf das ganze Element gestreckt, Text darüber;
# sonst Bild in Höhe des Elements neben dem Text
func _check(c: Dictionary) -> Control:
	var res: Dictionary = c["resources"]
	var normal = _texture(res.get("NormalImage", {}))
	var checked = _texture(res.get("CheckedImage", {}))
	var hover = _texture(res.get("OnHoverImage", {}))
	var checked_hover = _texture(res.get("CheckedOnHoverImage", {}))
	var t: Dictionary = c["text"]
	var align = c.get("align", 1)
	var b: Button
	if align == 1:
		b = Button.new()
		b.toggle_mode = true
		var states = {
			"normal": normal, "hover": hover if hover != null else normal, "pressed": checked,
			"hover_pressed": checked_hover if checked_hover != null else checked, "disabled": normal,
		}
		for state in states:
			b.add_theme_stylebox_override(state, _plain_style(states[state]))
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		b = CheckBox.new()
		for icon in ["unchecked", "radio_unchecked", "unchecked_disabled", "radio_unchecked_disabled"]:
			if normal != null:
				b.add_theme_icon_override(icon, _icon(normal, c["rect"].size.y))
		for icon in ["checked", "radio_checked", "checked_disabled", "radio_checked_disabled"]:
			if checked != null:
				b.add_theme_icon_override(icon, _icon(checked, c["rect"].size.y))
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			b.add_theme_stylebox_override(state, StyleBoxEmpty.new())
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.focus_mode = Control.FOCUS_NONE
	b.text = _lines(t.get("string", ""))
	b.clip_text = align == 1 # Häkchen links: Text steht rechts neben dem Element (oft nur so breit wie das Bild)
	b.disabled = not c["enable"]
	_text_style(b, t, "font_color", "font", "font_size")
	var col = t.get("color", Color.WHITE)
	var col_checked = t.get("text_check_color", t.get("check_color", col))
	b.add_theme_color_override("font_hover_color", col)
	b.add_theme_color_override("font_pressed_color", col_checked)
	b.add_theme_color_override("font_hover_pressed_color", col_checked)
	b.add_theme_color_override("font_disabled_color", DISABLED_TEXT)
	if c["type"] == "RADIO":
		var gid = c.get("group_id", 0)
		if not _groups.has(gid):
			_groups[gid] = ButtonGroup.new()
			_groups[gid].allow_unpress = false
		b.toggle_mode = true
		b.button_group = _groups[gid]
		b.set_meta("button_id", c.get("button_id", 0))
		b.set_meta("group_id", gid)
	else:
		b.toggle_mode = true
	return b

func _progress(c: Dictionary) -> Control:
	var res: Dictionary = c["resources"]
	var bar = TextureProgressBar.new()
	bar.nine_patch_stretch = true
	bar.texture_progress = _texture(res.get("FillImage", {}))
	bar.texture_under = _texture(res.get("FrameImage", {}))
	var vertical = c.get("vertical_progress", false)
	var reverse = c.get("reverse_direction", false)
	if vertical:
		bar.fill_mode = TextureProgressBar.FILL_TOP_TO_BOTTOM if reverse else TextureProgressBar.FILL_BOTTOM_TO_TOP
	else:
		bar.fill_mode = TextureProgressBar.FILL_RIGHT_TO_LEFT if reverse else TextureProgressBar.FILL_LEFT_TO_RIGHT
	bar.max_value = 100.0
	bar.value = PREVIEW_PROGRESS
	bar.mouse_filter = Control.MOUSE_FILTER_PASS if c["hint"] != "" else Control.MOUSE_FILTER_IGNORE
	return bar

func _list(c: Dictionary) -> Control:
	var list = ItemList.new()
	_panel(list, c, "panel")
	_text_style(list, c["text"], "font_color", "font", "font_size")
	var hilight = _frame_style(c["resources"].get("HilightImage", {}))
	if hilight != null:
		for state in ["selected", "selected_focus", "hovered", "hovered_selected", "hovered_selected_focus"]:
			list.add_theme_stylebox_override(state, hilight)
	list.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return list

func _tree(c: Dictionary) -> Control:
	var tree = Tree.new()
	tree.hide_root = true
	_panel(tree, c, "panel")
	_text_style(tree, c["text"], "font_color", "font", "font_size")
	tree.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var res: Dictionary = c["resources"]
	var plus = _texture(res.get("PlusSymbolImage", {}))
	var minus = _texture(res.get("MinusSymbolImage", {}))
	if plus != null:
		tree.add_theme_icon_override("arrow_collapsed", plus)
	if minus != null:
		tree.add_theme_icon_override("arrow", minus)
	return tree

func _combo(c: Dictionary) -> Control:
	var combo = OptionButton.new()
	var res: Dictionary = c["resources"]
	var normal = _frame_style(res.get("FrameImage", {}))
	var pushed = _frame_style(res.get("FramePushedImage", {}))
	for state in ["normal", "hover", "disabled"]:
		combo.add_theme_stylebox_override(state, normal if normal != null else StyleBoxEmpty.new())
	combo.add_theme_stylebox_override("pressed", pushed if pushed != null else (normal if normal != null else StyleBoxEmpty.new()))
	combo.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	combo.alignment = _halign(c.get("align", 0))
	combo.clip_text = true
	_text_style(combo, c["text"], "font_color", "font", "font_size")
	return combo

func _scroll(c: Dictionary) -> Control:
	var rect: Rect2i = c["rect"]
	var bar: ScrollBar = VScrollBar.new() if rect.size.y >= rect.size.x else HScrollBar.new()
	var res: Dictionary = c["resources"]
	var track = _frame_style(res.get("ScrollImage", {}))
	var thumb = _frame_style(res.get("BarFrameImage", res.get("BarImage", {})))
	bar.add_theme_stylebox_override("scroll", track if track != null else StyleBoxEmpty.new())
	for state in ["grabber", "grabber_highlight", "grabber_pressed"]:
		bar.add_theme_stylebox_override(state, thumb if thumb != null else StyleBoxEmpty.new())
	var up = _texture(res.get("UpImage", {}))
	var down = _texture(res.get("DownImage", {}))
	if up != null:
		bar.add_theme_icon_override("decrement", up)
		bar.add_theme_icon_override("decrement_highlight", up)
		bar.add_theme_icon_override("decrement_pressed", up)
	if down != null:
		bar.add_theme_icon_override("increment", down)
		bar.add_theme_icon_override("increment_highlight", down)
		bar.add_theme_icon_override("increment_pressed", down)
	bar.page = 10.0
	return bar

func _slider(c: Dictionary) -> Control:
	var rect: Rect2i = c["rect"]
	var slider: Slider = VSlider.new() if rect.size.y > rect.size.x else HSlider.new()
	var res: Dictionary = c["resources"]
	var track = _frame_style(res.get("FrameImage", {}))
	slider.add_theme_stylebox_override("slider", track if track != null else StyleBoxEmpty.new())
	slider.add_theme_stylebox_override("grabber_area", StyleBoxEmpty.new())
	slider.add_theme_stylebox_override("grabber_area_highlight", StyleBoxEmpty.new())
	var knob = _texture(res.get("BarImage", {}))
	if knob != null:
		slider.add_theme_icon_override("grabber", knob)
		slider.add_theme_icon_override("grabber_highlight", knob)
	var levels = c.get("total_levels", 0)
	slider.max_value = maxi(1, levels - 1)
	slider.step = 1.0
	return slider

func _sub_dialog(c: Dictionary) -> Control:
	var box = Control.new()
	box.clip_contents = true
	box.mouse_filter = Control.MOUSE_FILTER_PASS
	var file: String = c.get("dialog_file", "")
	box.set_meta("dialog_file", file)
	if file == "":
		return box
	if _depth >= MAX_SUB_DEPTH:
		warn("Unterdialog " + file + " zu tief verschachtelt")
		return box
	var sub = ui.read_dialog(file)
	if sub.is_empty():
		warn("Unterdialog " + file + " nicht gefunden")
		return box
	_depth += 1
	box.add_child(build_dialog(sub))
	_depth -= 1
	return box

func _placeholder(c: Dictionary) -> Control:
	var frame = _nine(c["resources"].get("FrameImage", {}), c["rect"])
	if frame != null:
		return frame
	var node = Control.new()
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


# ====================================================
# RAHMEN UND BILDER
# ====================================================
# AUIFrame::SetMode -> (linker / rechter Rand, oberer / unterer Rand, wirklicher Modus)
func _frame_margins(size: Vector2, mode: int) -> Vector3i:
	var w = int(size.x)
	var h = int(size.y)
	if mode in [MODE_UNKNOWN, MODE_3X3] and w % 3 == 0 and h % 3 == 0:
		return Vector3i(w / 3, h / 3, MODE_3X3)
	if mode in [MODE_UNKNOWN, MODE_4X4] and w % 4 == 0 and h % 4 == 0:
		return Vector3i(w / 4, h / 4, MODE_4X4)
	if mode in [MODE_UNKNOWN, MODE_3X1] and w % 3 == 0:
		return Vector3i(w / 3, 0, MODE_3X1)
	if mode in [MODE_UNKNOWN, MODE_1X3] and h % 3 == 0:
		return Vector3i(0, h / 3, MODE_1X3)
	return Vector3i(0, 0, MODE_1X1)

func _frame_style(r: Dictionary) -> StyleBoxTexture:
	var tex = _texture(r)
	if tex == null:
		return null
	var m = _frame_margins(tex.get_size(), r.get("frame_mode", MODE_UNKNOWN))
	var sb = StyleBoxTexture.new()
	sb.texture = tex
	sb.texture_margin_left = m.x
	sb.texture_margin_right = m.x
	sb.texture_margin_top = m.y
	sb.texture_margin_bottom = m.y
	return sb

# Ganzes Bild gestreckt (Sprite, kein Rahmen)
func _plain_style(tex: Texture2D) -> StyleBox:
	if tex == null:
		return StyleBoxEmpty.new()
	var sb = StyleBoxTexture.new()
	sb.texture = tex
	return sb

func _nine(r: Dictionary, rect: Rect2i) -> NinePatchRect:
	var tex = _texture(r)
	if tex == null:
		return null
	var m = _frame_margins(tex.get_size(), r.get("frame_mode", MODE_UNKNOWN))
	var nine = NinePatchRect.new()
	nine.texture = tex
	nine.patch_margin_left = m.x
	nine.patch_margin_right = m.x
	nine.patch_margin_top = m.y
	nine.patch_margin_bottom = m.y
	nine.position = Vector2(rect.position)
	nine.size = Vector2(rect.size)
	nine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return nine

func _panel(node: Control, c: Dictionary, style_name: String) -> void:
	var style = _frame_style(c["resources"].get("FrameImage", {}))
	node.add_theme_stylebox_override(style_name, style if style != null else StyleBoxEmpty.new())

# Häkchen-Symbol in Höhe des Elements (Seitenverhältnis bleibt)
func _icon(tex: Texture2D, height: int) -> Texture2D:
	if height <= 0 or int(tex.get_size().y) == height:
		return tex
	var img = tex.get_image()
	if img == null:
		return tex
	if img.is_compressed():
		img.decompress()
	var w = maxi(1, roundi(img.get_width() * float(height) / img.get_height()))
	img.resize(w, height, Image.INTERPOLATE_BILINEAR)
	return ImageTexture.create_from_image(img)

# Bild einer Resource (surfaces\...) -> Textur, gespeichert als .res unter res://ECM_Import
func _texture(r: Dictionary) -> Texture2D:
	if r.is_empty() or r.get("file", "") == "" or r.get("gfx", false):
		return null
	var src: String = r["path"]
	if src == "":
		warn("Bild " + r["file"] + " nicht in den Spieldaten (surfaces)")
		return null
	if _textures.has(src):
		return _textures[src]
	var dest = out_path(src, ".res")
	var tex: Texture2D = null
	if dest != "" and FileAccess.file_exists(dest):
		tex = load(dest) as Texture2D
	if tex == null:
		var img: Image = _images.image_file(src)
		if img == null:
			warn("Bild " + r["file"] + " nicht lesbar")
		else:
			if img.is_compressed():
				img.decompress()
			img.clear_mipmaps()
			img = _color_key(img)
			if not save_files:
				tex = ImageTexture.create_from_image(img)
				_textures[src] = tex
				return tex
			var portable = PortableCompressedTexture2D.new()
			portable.keep_compressed_buffer = true # außerhalb des Editors sonst leer gespeichert
			portable.create_from_image(img, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
			tex = portable
			if _save(portable, dest) != OK:
				warn("Bild " + dest + " nicht gespeichert")
	_textures[src] = tex
	return tex

# Bilder ohne Alpha: Magenta wird durchsichtig (A2DSprite::Init mit AUI_COLORKEY)
func _color_key(img: Image) -> Image:
	if img.detect_alpha() != Image.ALPHA_NONE:
		return img
	img.convert(Image.FORMAT_RGBA8)
	var data = img.get_data()
	var changed = false
	for i in range(0, data.size(), 4):
		if data[i] == 255 and data[i + 1] == 0 and data[i + 2] == 255:
			data[i] = 0
			data[i + 2] = 0
			data[i + 3] = 0
			changed = true
	if changed:
		img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)
	return img


# ====================================================
# SCHRIFT UND TEXT
# ====================================================
func _text_style(node: Control, t: Dictionary, color_name: String, font_name: String, size_name: String) -> void:
	node.add_theme_font_override(font_name, _font(t))
	node.add_theme_font_size_override(size_name, _px(t))
	node.add_theme_color_override(color_name, t.get("color", Color.WHITE))
	var shadow: Color = t.get("shadow", Color(0, 0, 0, 0))
	if shadow.a > 0.0:
		node.add_theme_color_override("font_shadow_color", shadow)
		node.add_theme_constant_override("shadow_offset_x", SHADOW_OFFSET)
		node.add_theme_constant_override("shadow_offset_y", SHADOW_OFFSET)
	if t.get("outline", 0) > 0:
		node.add_theme_constant_override("outline_size", t["outline"] * 2)
		node.add_theme_color_override("font_outline_color", t.get("outline_color", Color.BLACK))

func _px(t: Dictionary) -> int:
	return maxi(1, roundi(t.get("size", _defaults.get("size", 10)) * POINT_TO_PIXEL))

func _font(t: Dictionary) -> Font:
	var face: String = t.get("font", _defaults.get("font", UI.DEFAULT_FONT))
	var file: String = ui.font(face)
	if file == "":
		warn("Schrift " + face + " nicht gefunden (font)")
		return null
	var base: FontFile = _fonts.get(file)
	if base == null:
		var dest = FONT_DIR.path_join(file.get_file().get_basename() + ".res")
		if FileAccess.file_exists(dest):
			base = load(dest) as FontFile
		if base == null:
			base = FontFile.new()
			var data = ui.files.get_bytes(file)
			if data.is_empty():
				warn("Schrift " + file + " nicht lesbar")
				return null
			base.data = data
			if save_files:
				_save(base, dest)
		_fonts[file] = base
	var bold = t.get("bold", false)
	var italic = t.get("italic", false)
	if not bold and not italic:
		return base
	var key = "%s|%s|%s" % [file, bold, italic]
	if not _variants.has(key):
		var v = FontVariation.new()
		v.base_font = base
		if bold:
			v.variation_embolden = 0.8
		if italic:
			v.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.2, 1), Vector2.ZERO)
		_variants[key] = v
	return _variants[key]

func _text_size(s: String, t: Dictionary, line_space: int) -> Vector2:
	var font = _font(t)
	if font == null or s == "":
		return Vector2.ZERO
	var size = font.get_multiline_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, _px(t))
	var lines = s.count("\n") + 1
	return Vector2(ceilf(size.x), ceilf(size.y + maxi(0, lines - 1) * line_space))

static func _halign(align: int) -> HorizontalAlignment:
	return [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT][clampi(align, 0, 2)]

# Zeilenenden der Spieltexte (\r, \r\n) -> \n
static func _lines(s: String) -> String:
	return s.replace("\r\n", "\n").replace("\r", "\n")

static func _has_markup(s: String) -> bool:
	return s.contains("^")

# AUI_TextOutFormat-Codes -> BBCode: ^RRGGBB Farbe, ^U + Farbe unterstrichen bis ^u,
# ^^ / ^& Zeichen, ^O + 3 Ziffern Schriftwechsel, ^o / ^N ohne Wirkung hier
static func _bbcode(s: String, align: int) -> String:
	var out = ""
	var color = false
	var underline = false
	var i = 0
	var n = s.length()
	while i < n:
		var ch = s[i]
		if ch == "^" and i + 1 < n:
			var nx = s[i + 1]
			if nx == "^" or nx == "&":
				out += nx
				i += 2
			elif nx == "U":
				if not underline:
					out += "[u]"
					underline = true
				i += 8
			elif nx == "u":
				if underline:
					out += "[/u]"
					underline = false
				i += 2
			elif nx == "o" or nx == "N":
				i += 2
			elif nx == "O" and i + 4 < n:
				i += 5
			else:
				var hex = s.substr(i + 1, 6)
				if hex.length() == 6 and hex.is_valid_hex_number():
					if color:
						out += "[/color]"
					out += "[color=#" + hex + "]"
					color = true
				i += 7
			continue
		out += "[lb]" if ch == "[" else ch
		i += 1
	if color:
		out += "[/color]"
	if underline:
		out += "[/u]"
	if align == 1:
		return "[center]" + out + "[/center]"
	if align == 2:
		return "[right]" + out + "[/right]"
	return out

# Text ohne Codes (für Maße und Tooltips)
static func _plain(s: String) -> String:
	if not s.contains("^"):
		return s
	var out = ""
	var i = 0
	var n = s.length()
	while i < n:
		var ch = s[i]
		if ch == "^" and i + 1 < n:
			var nx = s[i + 1]
			if nx == "^" or nx == "&":
				out += nx
				i += 2
			elif nx == "U":
				i += 8
			elif nx in ["u", "o", "N"]:
				i += 2
			elif nx == "O" and i + 4 < n:
				i += 5
			else:
				i += 7
			continue
		out += ch
		i += 1
	return out


# ====================================================
# HILFEN
# ====================================================
func _save(res: Resource, path: String) -> int:
	if path == "":
		return ERR_FILE_BAD_PATH
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	res.take_over_path(path)
	var err = ResourceSaver.save(res, path)
	if err == OK:
		Builder.register_uid(path)
		if not path in written:
			written.append(path)
	return err

func _set_owner(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_owner(child, owner)

static func _node_name(n: String) -> String:
	for c in [".", ":", "@", "/", "\"", "%"]:
		n = n.replace(c, "_")
	return n if n != "" else "Control"
