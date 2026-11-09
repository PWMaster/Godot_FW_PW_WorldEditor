extends Control

# ====================================================
# Ein Dialog der Spiel-Oberfläche zur Laufzeit (wie AUIDialog): Hülle um die vom Plugin gebaute
# Szene (angelica_ui_builder.gd build_dialog). Name wie im Spiel (Win_Login), Steuerelemente über
# ihren Namen (item("Btn_Login"), set_text, show_item, enable_item, check_item ...).
# Befehle (Signal command, AUIDialog::OnCommand):
#   Knopf -> sein Command, ohne Command sein Name; CHECK bei jedem Klick, RADIO beim Auswählen,
#   SLIDER bei jeder Änderung durch den Spieler (set_level löst nichts aus)
#   Enter in einem Eingabefeld -> sein Command; ohne Command weiter zum nächsten leeren Feld,
#   sonst "IDOK"
#   Esc -> "IDCANCEL" (nur mit CanEscClose oder als Meldungsfenster), Enter außerhalb von
#   Eingabefeldern -> "IDOK" (beides verteilt aui_manager.gd an den obersten Dialog)
# Tab / Umschalt+Tab springt zwischen den sichtbaren Eingabefeldern in Dialog-Reihenfolge
# (TabStop); beim Zeigen bekommt ein Feld mit "DEFAULT_" im Namen den Fokus.
# ====================================================

signal command(cmd: String)

var dlg_name = ""
var file = ""
var can_esc_close = false
var background = false # BackgroundDialog: liegt unter den anderen
var message_box = false
var layout_pos = Vector2i(-1, -1) # aus der .dcf: -1 mittig, < -1 rechts / unten bündig
var content: Control
var builder # angelica_ui_builder.gd (Farbcodes -> BBCode), setzt aui_manager.gd
var _items = {} # Name -> Steuerelement
var _edits: Array = [] # LineEdit in Dialog-Reihenfolge


func setup(p_content: Control) -> void:
	content = p_content
	dlg_name = String(content.name)
	name = dlg_name
	file = str(content.get_meta("aui_file", ""))
	can_esc_close = content.get_meta("can_esc_close", false)
	background = content.get_meta("background_dialog", false)
	size = content.size
	mouse_filter = MOUSE_FILTER_IGNORE
	visible = false
	add_child(content)
	_collect(content)

func open() -> void:
	visible = true
	_link_tabs()
	for e in _edits:
		if String(e.name).begins_with("DEFAULT_") and e.visible and e.editable:
			e.grab_focus.call_deferred()
			break

func close() -> void:
	visible = false


# ====================================================
# STEUERELEMENTE
# ====================================================
func item(item_name: String) -> Control:
	return _items.get(item_name)

func get_text(item_name: String) -> String:
	var c = item(item_name)
	if c is RichTextLabel:
		return c.get_parsed_text()
	if c is LineEdit or c is TextEdit or c is Label or c is Button:
		return c.text
	return ""

# Text setzen; Beschriftungen ohne feste Breite bleiben an ihrem Bezugspunkt (links / Mitte / rechts)
func set_text(item_name: String, s: String) -> void:
	var c = item(item_name)
	s = s.replace("\r\n", "\n").replace("\r", "\n")
	if c is Label and c.autowrap_mode == TextServer.AUTOWRAP_OFF:
		var anchor = c.position.x
		if c.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
			anchor += c.size.x / 2.0
		elif c.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
			anchor += c.size.x
		c.text = s
		c.reset_size()
		if c.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
			c.position.x = roundf(anchor - c.size.x / 2.0)
		elif c.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
			c.position.x = anchor - c.size.x
	elif c is RichTextLabel:
		c.text = builder._bbcode(s, 0) if builder != null else s.replace("[", "[lb]")
	elif c is LineEdit or c is TextEdit or c is Label or c is Button:
		c.text = s

func show_item(item_name: String, on: bool) -> void:
	var c = item(item_name)
	if c != null:
		c.visible = on

func enable_item(item_name: String, on: bool) -> void:
	var c = item(item_name)
	if c is BaseButton:
		c.disabled = not on
	elif c is LineEdit or c is TextEdit:
		c.editable = on

func check_item(item_name: String, on: bool) -> void:
	var c = item(item_name)
	if c is BaseButton:
		c.set_pressed_no_signal(on)

func is_checked(item_name: String) -> bool:
	var c = item(item_name)
	return c is BaseButton and c.button_pressed

func is_shown(item_name: String) -> bool:
	var c = item(item_name)
	return c != null and c.visible

# SLIDER: Stufen 0 .. total - 1 (AUISlider: TotalLevels)
func set_total(item_name: String, total: int) -> void:
	var c = item(item_name)
	if c is Range:
		c.max_value = maxi(1, total - 1)
		c.editable = total > 1

func set_level(item_name: String, level: int) -> void:
	var c = item(item_name)
	if c is Range:
		c.set_value_no_signal(level)

func get_level(item_name: String) -> int:
	var c = item(item_name)
	return int(c.value) if c is Range else 0

# IMAGEPICTURE mit Frames (Streifen untereinander): Bild Nr. index zeigen
func set_frame(item_name: String, index: int) -> void:
	var c = item(item_name)
	if not c is TextureRect or not c.texture is AtlasTexture:
		return
	var at: AtlasTexture = c.texture.duplicate()
	var frames = int(c.get_meta("frames", 1))
	at.region.position.y = clampi(index, 0, frames - 1) * at.region.size.y
	c.texture = at

func set_image(item_name: String, tex: Texture2D) -> void:
	var c = item(item_name)
	if c is TextureRect:
		c.texture = tex

# PROGRESS: Füllstand 0 - 100
func set_progress(item_name: String, value: float) -> void:
	var c = item(item_name)
	if c is Range:
		c.value = value

# Färbt das Element (AUI SetItemColor)
func set_color(item_name: String, color: Color) -> void:
	var c = item(item_name)
	if c != null:
		c.self_modulate = color

func edits() -> Array:
	return _edits

func send(cmd: String) -> void:
	if visible:
		command.emit(cmd)


# ====================================================
# INNERES
# ====================================================
# Steuerelemente (Meta aui_type) samt eingebetteter Unterdialoge einsammeln und verbinden
func _collect(node: Node) -> void:
	for c in node.get_children():
		if c.has_meta("aui_type"):
			var n = String(c.name)
			if not _items.has(n):
				_items[n] = c
			_connect(c)
		_collect(c)

func _connect(c: Control) -> void:
	var cmd = str(c.get_meta("command", c.name))
	var type = str(c.get_meta("aui_type"))
	if c is LineEdit:
		_edits.append(c)
		c.text_submitted.connect(_on_submit.bind(c))
		c.gui_input.connect(_on_edit_input.bind(c))
	elif c is Range and type == "SLIDER":
		c.value_changed.connect(_on_slider.bind(cmd))
	elif c is BaseButton:
		if type == "RADIO":
			c.toggled.connect(_on_radio.bind(cmd))
		elif type == "CHECK":
			c.toggled.connect(_on_check.bind(cmd))
		else:
			c.pressed.connect(send.bind(cmd))

func _on_submit(_text: String, edit: LineEdit) -> void:
	if edit.has_meta("command"):
		send(str(edit.get_meta("command")))
		return
	var i = _edits.find(edit)
	for j in range(i + 1, _edits.size()):
		var e: LineEdit = _edits[j]
		if e.is_visible_in_tree() and e.editable and e.text == "":
			e.grab_focus()
			return
	send("IDOK")

# Esc im Eingabefeld: das LineEdit beendet sonst nur die Eingabe und der Dialog bliebe offen
func _on_edit_input(event: InputEvent, edit: LineEdit) -> void:
	var k = event as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == KEY_ESCAPE and (can_esc_close or message_box):
		edit.accept_event()
		send("IDCANCEL")

func _on_slider(_value: float, cmd: String) -> void:
	send(cmd)

func _on_radio(on: bool, cmd: String) -> void:
	if on:
		send(cmd)

func _on_check(_on: bool, cmd: String) -> void:
	send(cmd)

# Tab-Reihenfolge der sichtbaren, bearbeitbaren Eingabefelder (ringförmig)
func _link_tabs() -> void:
	var list = []
	for e in _edits:
		if e.is_visible_in_tree() and e.editable:
			list.append(e)
	for i in list.size():
		var e: LineEdit = list[i]
		e.focus_next = e.get_path_to(list[(i + 1) % list.size()])
		e.focus_previous = e.get_path_to(list[(i - 1 + list.size()) % list.size()])
