extends Control

# ====================================================
# Vorläufiges Anmelde-Fenster des Clients, bis Schritt 4 den FW-Login aus den AUI-Dialogen
# bringt: Server, Port, Sprache, Konto, Passwort; "Anmelden", "Konto anlegen", "Abmelden".
# Server, Port, Sprache und Konto (nie das Passwort) bleiben in user://settings.cfg [client];
# --host / --port / --account auf der Kommandozeile füllen die Felder vor.
# ====================================================

const Proto = preload("../common/protocol.gd")
const Settings = preload("../common/settings.gd")
const Session = preload("session.gd")
const LANGUAGES = [["Deutsch", "Deu"], ["Englisch", "Eng"], ["Französisch", "Franz"]]

var session: Session
var settings: Settings
var _host: LineEdit
var _port: SpinBox
var _language: OptionButton
var _account: LineEdit
var _password: LineEdit
var _login_btn: Button
var _register_btn: Button
var _logout_btn: Button
var _status: Label
var _busy = false


func _ready() -> void:
	session = get_parent().get_node("Session")
	settings = Settings.new("client")
	get_window().title = "Godot-FW Client"
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_build()
	_host.text = settings.value("host")
	_port.value = settings.value("port")
	_account.text = settings.value("account")
	for i in LANGUAGES.size():
		if LANGUAGES[i][1] == settings.value("language"):
			_language.select(i)
	session.dtls = settings.value("dtls")
	session.dtls_cert = settings.value("dtls_cert")
	session.state_changed.connect(_on_state)
	session.kicked.connect(_on_kicked)
	_show("Bitte anmelden oder ein Konto anlegen.")
	_update()
	if _account.text != "":
		_password.grab_focus.call_deferred()

func _on_login() -> void:
	if not _begin("Anmelden ..."):
		return
	var r = await session.login(_account.text.strip_edges(), _password.text)
	_end(r, "Angemeldet als %s (%s, Protokoll %d)." % [session.account, session.server_info.get("server", "?"), Proto.VERSION])

func _on_register() -> void:
	if not _begin("Konto wird angelegt ..."):
		return
	var r = await session.register(_account.text.strip_edges(), _password.text)
	_end(r, "Konto %s angelegt, jetzt anmelden." % _account.text.strip_edges())

func _on_logout() -> void:
	if not _begin("Abmelden ..."):
		return
	var r = await session.logout()
	_end(r, "Abgemeldet.")

func _begin(text: String) -> bool:
	if _busy:
		return false
	_busy = true
	_apply_fields()
	_show(text)
	_update()
	return true

func _end(r: Dictionary, ok_text: String) -> void:
	_busy = false
	_show(ok_text if r["code"] == Proto.Code.OK else Proto.text(r["code"]))
	_update()

# Feldwerte übernehmen und speichern; andere Adresse -> neu verbinden
func _apply_fields() -> void:
	var host = _host.text.strip_edges()
	var port = int(_port.value)
	if session.state != Session.State.OFFLINE and (host != session.host or port != session.port):
		session.close()
	session.host = host
	session.port = port
	settings.set_value("host", host)
	settings.set_value("port", port)
	settings.set_value("language", LANGUAGES[_language.selected][1])
	settings.set_value("account", _account.text.strip_edges())
	settings.save()

func _on_state(_s: int) -> void:
	_update()

func _on_kicked(code: int) -> void:
	_show(Proto.text(code))

func _show(text: String) -> void:
	_status.text = text
	print("Client: ", text)

func _update() -> void:
	var logged_in = session.state == Session.State.LOGGED_IN
	_login_btn.disabled = _busy or logged_in
	_register_btn.disabled = _busy or logged_in
	_logout_btn.disabled = _busy or not logged_in
	for f in [_host, _account, _password]:
		f.editable = not _busy and not logged_in
	_port.editable = not _busy and not logged_in


# ====================================================
# OBERFLÄCHE
# ====================================================
func _build() -> void:
	var center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)
	var panel = PanelContainer.new()
	center.add_child(panel)
	var margin = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	panel.add_child(margin)
	var box = VBoxContainer.new()
	box.custom_minimum_size = Vector2(380, 0)
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)
	var title = Label.new()
	title.text = "Godot-FW - Anmeldung (vorläufig)"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var grid = GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	_host = _field(grid, "Server:", LineEdit.new())
	_port = _field(grid, "Port:", SpinBox.new())
	_port.min_value = 1
	_port.max_value = 65535
	_language = _field(grid, "Sprache:", OptionButton.new())
	for l in LANGUAGES:
		_language.add_item(l[0])
	_account = _field(grid, "Konto:", LineEdit.new())
	_account.max_length = Proto.ACCOUNT_MAX
	_password = _field(grid, "Passwort:", LineEdit.new())
	_password.secret = true
	_password.max_length = Proto.PASSWORD_MAX
	_password.text_submitted.connect(func(_t): _on_login())
	var bar = HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(bar)
	_login_btn = _button(bar, "Anmelden", _on_login)
	_register_btn = _button(bar, "Konto anlegen", _on_register)
	_logout_btn = _button(bar, "Abmelden", _on_logout)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(380, 48)
	box.add_child(_status)

func _field(grid: GridContainer, label: String, control: Control) -> Control:
	var l = Label.new()
	l.text = label
	grid.add_child(l)
	control.size_flags_horizontal = SIZE_EXPAND_FILL
	grid.add_child(control)
	return control

func _button(bar: HBoxContainer, text: String, action: Callable) -> Button:
	var b = Button.new()
	b.text = text
	b.pressed.connect(action)
	bar.add_child(b)
	return b
