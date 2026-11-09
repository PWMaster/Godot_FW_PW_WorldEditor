extends Node

# ====================================================
# Login des Clients im Stil des Spiels (EC_LoginUIMan, DlgLogin, DlgLoginWait): Dialoge aus den
# Spieldaten (loginui.dcf / loginui.stf, Sprache aus user://settings.cfg) über ui/aui_manager.gd.
# Zustände wie EC_LoginUIMan::SetState (SHOW_DLGS):
#   LOGIN        Win_LoginControl + Win_Login
#   WAITING      Win_LoginWait "Anmelden, bitte warten..." (Abbrechen trennt)
#   SELECT_CHAR  Figurenauswahl und -erstellung (char_select.gd); "Beenden" meldet ab
#   IN_WORLD     Spielwelt (world_screen.gd); Esc führt zurück zur Figurenauswahl
# Hintergrund LoginWorld\LoginBack.dds auf den Bildschirm gestreckt (das Spiel zeigt dort sonst ein
# Video; Win_LoginBack1 / 2 sind die Balken darum und bleiben aus).
# Login: Konto und Passwort, "Anmeldung erzwingen" (Chk_Forcelog: eine andere Sitzung des Kontos
# wird getrennt), "Merken" (Chk_Memorize: Kontoname in settings.cfg). "Registrieren" und
# "Wechseln" öffnen eigene Dialoge im Format des Spiels: ui/register.xml (Konto anlegen; das
# Original nahm dafür eine Webseite) und ui/server.xml (Adresse, Port, DTLS). Dienste, die es hier
# nicht gibt (Passwort vergessen, Aufladen, Passwort zurücksetzen), sind ausgeblendet.
# Fehler als Meldungsfenster: leere Felder (loginui.stf 203), Zeitüberschreitung (226), sonst die
# Texte aus protocol.gd in der Sprache; eigene Texte in TEXTS.
# ====================================================

const Proto = preload("../common/protocol.gd")
const Settings = preload("../common/settings.gd")
const Session = preload("session.gd")
const AuiManager = preload("ui/aui_manager.gd")
const CharSelect = preload("char_select.gd")
const WorldScreen = preload("world_screen.gd")
const BACKGROUND = "LoginWorld\\LoginBack.dds"
const HIDDEN = {
	"Win_Login": ["Btn_Link", "Chk_Third"],
	"Win_LoginControl": ["Btn_QSBStipple", "Btn_ResetPass"],
}
const STF_EMPTY_FIELDS = 203
const STF_WAIT = 205
const STF_TIMEOUT = 226
const SERVER_NAME_CHARS = 15

# Texte der eigenen Dialoge (Steuerelement -> Text) und Meldungen, je Sprachordner
const TEXTS = {
	"Deu": {
		"Win_Register": {"Lab_Title": "Konto anlegen", "Lab_Account": "Konto:", "Lab_Password": "Passwort:",
			"Lab_Password2": "Wiederholen:", "Lab_Rules": "Konto 4 - 20 Zeichen, Passwort mindestens 6",
			"Btn_Create": "Anlegen", "Btn_Cancel": "Abbrechen"},
		"Win_Server": {"Lab_Title": "Server", "Lab_Host": "Adresse:", "Lab_Port": "Port:",
			"Chk_Dtls": "Verschlüsselt (DTLS)", "Btn_Ok": "OK", "Btn_Cancel": "Abbrechen"},
		"placeholder": {"DEFAULT_Txt_Account": "Konto", "Txt_PassWord": "Passwort"},
		"password_mismatch": "Die Passwörter stimmen nicht überein.",
		"registered": "Konto %s wurde angelegt. Du kannst dich jetzt anmelden.",
		"server_invalid": "Bitte eine Adresse und einen Port (1 - 65535) angeben.",
	},
	"Eng": {
		"Win_Register": {"Lab_Title": "Create account", "Lab_Account": "Account:", "Lab_Password": "Password:",
			"Lab_Password2": "Repeat:", "Lab_Rules": "Account 4 - 20 characters, password at least 6",
			"Btn_Create": "Create", "Btn_Cancel": "Cancel"},
		"Win_Server": {"Lab_Title": "Server", "Lab_Host": "Address:", "Lab_Port": "Port:",
			"Chk_Dtls": "Encrypted (DTLS)", "Btn_Ok": "OK", "Btn_Cancel": "Cancel"},
		"placeholder": {"DEFAULT_Txt_Account": "Account", "Txt_PassWord": "Password"},
		"password_mismatch": "The passwords do not match.",
		"registered": "Account %s has been created. You can log in now.",
		"server_invalid": "Please enter an address and a port (1 - 65535).",
	},
	"Franz": {
		"Win_Register": {"Lab_Title": "Créer un compte", "Lab_Account": "Compte :", "Lab_Password": "Mot de passe :",
			"Lab_Password2": "Répéter :", "Lab_Rules": "Compte 4 à 20 caractères, mot de passe au moins 6",
			"Btn_Create": "Créer", "Btn_Cancel": "Annuler"},
		"Win_Server": {"Lab_Title": "Serveur", "Lab_Host": "Adresse :", "Lab_Port": "Port :",
			"Chk_Dtls": "Chiffré (DTLS)", "Btn_Ok": "OK", "Btn_Cancel": "Annuler"},
		"placeholder": {"DEFAULT_Txt_Account": "Compte", "Txt_PassWord": "Mot de passe"},
		"password_mismatch": "Les mots de passe ne correspondent pas.",
		"registered": "Le compte %s a été créé. Vous pouvez vous connecter.",
		"server_invalid": "Veuillez indiquer une adresse et un port (1 - 65535).",
	},
}

enum State {LOGIN, WAITING, SELECT_CHAR, IN_WORLD}

var aui: AuiManager
var session: Session
var settings: Settings
var language = "Deu"
var state = State.LOGIN
var dlg_login
var dlg_control
var dlg_wait
var dlg_register
var dlg_server
var chars: CharSelect
var world: WorldScreen
var _busy = false
var _wait_cancel_text = ""


static func available(p_settings: Settings) -> bool:
	return AuiManager.data_available(p_settings.value("data_root"), p_settings.value("language"))

func _ready() -> void:
	session = get_parent().get_node("Session")
	settings = Settings.new("client")
	language = settings.value("language")
	get_window().title = "Godot-FW"
	aui = AuiManager.new()
	add_child(aui)
	var err = aui.setup(settings.value("data_root"), language)
	if err != "":
		push_error("Login: " + err)
		return
	aui.load_layout("loginui")
	aui.set_background(BACKGROUND)
	var ui_dir = get_script().resource_path.get_base_dir().path_join("ui")
	dlg_login = aui.dialog("Login.xml")
	dlg_control = aui.dialog("LoginControl.xml")
	dlg_wait = aui.dialog("LoginWait.xml")
	dlg_register = aui.dialog(ui_dir.path_join("register.xml"))
	dlg_server = aui.dialog(ui_dir.path_join("server.xml"))
	for d in [dlg_login, dlg_control, dlg_wait, dlg_register, dlg_server]:
		if d == null:
			push_error("Login: Dialog fehlt (%s)" % ", ".join(aui.warnings))
			return
		for item_name in HIDDEN.get(d.dlg_name, []):
			d.show_item(item_name, false)
		var texts: Dictionary = _texts().get(d.dlg_name, {})
		for item_name in texts:
			d.set_text(item_name, texts[item_name])
	# Die Passwort-Zeile hat im Spiel keine Beschriftung (daneben steht "Registrieren"): grauer Platzhalter
	var hints: Dictionary = _texts()["placeholder"]
	for item_name in hints:
		var e = dlg_login.item(item_name)
		if e is LineEdit:
			e.placeholder_text = hints[item_name]
			e.add_theme_color_override("font_placeholder_color", Color(0.72, 0.94, 0.96, 0.35))
	dlg_login.command.connect(_on_login_command)
	dlg_control.command.connect(_on_control_command)
	dlg_wait.command.connect(_on_wait_command)
	dlg_register.command.connect(_on_register_command)
	dlg_server.command.connect(_on_server_command)
	chars = CharSelect.new()
	chars.name = "Figuren"
	add_child(chars)
	err = chars.setup(self)
	if err != "":
		push_error("Login: " + err)
		return
	chars.back_to_login.connect(_on_back_to_login)
	_wait_cancel_text = dlg_wait.get_text("Btn_Cancel")
	session.host = settings.value("host")
	session.port = settings.value("port")
	session.dtls = settings.value("dtls")
	session.dtls_cert = settings.value("dtls_cert")
	session.disconnected.connect(_on_disconnected)
	dlg_login.check_item("Chk_Memorize", settings.value("remember"))
	dlg_login.check_item("Chk_Forcelog", false)
	if settings.value("remember"):
		dlg_login.set_text("DEFAULT_Txt_Account", settings.value("account"))
	_show_server()
	set_state(State.LOGIN)

func set_state(s: int) -> void:
	var was = state
	state = s
	var shown = {State.LOGIN: [dlg_control, dlg_login], State.WAITING: [dlg_wait], State.SELECT_CHAR: [], State.IN_WORLD: []}[s]
	for d in [dlg_login, dlg_control, dlg_wait, dlg_register, dlg_server]:
		if not d in shown:
			aui.hide_dialog(d)
	if s == State.WAITING:
		dlg_wait.set_text("Txt_Message", aui.text(STF_WAIT).strip_edges())
		dlg_wait.set_text("Btn_Cancel", _wait_cancel_text)
	if was == State.SELECT_CHAR and s != State.SELECT_CHAR:
		chars.close()
		aui.set_background(BACKGROUND)
	if was == State.IN_WORLD and s != State.IN_WORLD and world != null:
		world.queue_free()
		world = null
		aui.set_background(BACKGROUND)
	for d in shown:
		aui.show_dialog(d)
	if s == State.LOGIN:
		_focus_login()
	elif s == State.SELECT_CHAR:
		chars.open()


# ====================================================
# LOGIN
# ====================================================
func _on_login_command(cmd: String) -> void:
	match cmd:
		"Btn_Login", "IDOK":
			login()
		"Btn_Register":
			_open_register()
		"Chk_Memorize":
			settings.set_value("remember", dlg_login.is_checked("Chk_Memorize"))
			if not dlg_login.is_checked("Chk_Memorize"):
				settings.set_value("account", "")
			settings.save()

func _on_control_command(cmd: String) -> void:
	match cmd:
		"Btn_ServerList":
			_open_server()
		"Btn_LogOut2":
			session.close()
			get_tree().quit()

func login() -> void:
	if _busy or state != State.LOGIN or aui.has_message_box():
		return
	var acc = dlg_login.get_text("DEFAULT_Txt_Account").strip_edges()
	var pw = dlg_login.get_text("Txt_PassWord")
	if acc == "" or pw == "":
		await _message(aui.text(STF_EMPTY_FIELDS))
		return
	dlg_login.set_text("Txt_PassWord", "")
	_busy = true
	set_state(State.WAITING)
	var r = await session.login(acc, pw, dlg_login.is_checked("Chk_Forcelog"))
	_busy = false
	if state != State.WAITING: # abgebrochen
		return
	if r["code"] == Proto.Code.OK:
		if dlg_login.is_checked("Chk_Memorize"):
			settings.set_value("account", session.account)
			settings.save()
		set_state(State.SELECT_CHAR)
	else:
		set_state(State.LOGIN)
		await _message(_error_text(r["code"]))

func _on_wait_command(cmd: String) -> void:
	if cmd != "IDCANCEL" and cmd != "Btn_Cancel":
		return
	if state == State.WAITING:
		session.close()
		set_state(State.LOGIN)

# "Start" in der Figurenauswahl (Antwort von char_enter)
func enter_world(info: Dictionary) -> void:
	set_state(State.IN_WORLD)
	world = WorldScreen.new()
	add_child(world)
	world.left_world.connect(_on_left_world)
	world.start(self, info)

func _on_left_world() -> void:
	if state == State.IN_WORLD:
		set_state(State.SELECT_CHAR)

# "Beenden" in der Figurenauswahl: abmelden, zurück zum Login
func _on_back_to_login() -> void:
	if _busy or state != State.SELECT_CHAR:
		return
	_busy = true
	await session.logout()
	session.close()
	_busy = false
	set_state(State.LOGIN)

# Verbindung weg, während angemeldet (andere Anmeldung, Server beendet ...)
func _on_disconnected(code: int) -> void:
	if (state == State.SELECT_CHAR or state == State.IN_WORLD) and not _busy:
		set_state(State.LOGIN)
		await _message(_error_text(code))


# ====================================================
# KONTO ANLEGEN
# ====================================================
func _open_register() -> void:
	if _busy:
		return
	dlg_register.set_text("DEFAULT_Edt_Account", dlg_login.get_text("DEFAULT_Txt_Account").strip_edges())
	dlg_register.set_text("Edt_Password", "")
	dlg_register.set_text("Edt_Password2", "")
	aui.show_dialog(dlg_register)

func _on_register_command(cmd: String) -> void:
	match cmd:
		"IDCANCEL":
			aui.hide_dialog(dlg_register)
			_focus_login()
		"IDOK":
			register()

func register() -> void:
	if _busy or aui.has_message_box():
		return
	var acc = dlg_register.get_text("DEFAULT_Edt_Account").strip_edges()
	var pw = dlg_register.get_text("Edt_Password")
	if acc == "" or pw == "":
		await _message(aui.text(STF_EMPTY_FIELDS))
		return
	if pw != dlg_register.get_text("Edt_Password2"):
		await _message(_texts()["password_mismatch"])
		return
	_busy = true
	dlg_register.enable_item("Btn_Create", false)
	var r = await session.register(acc, pw)
	_busy = false
	dlg_register.enable_item("Btn_Create", true)
	if r["code"] != Proto.Code.OK:
		await _message(_error_text(r["code"]))
		return
	aui.hide_dialog(dlg_register)
	dlg_login.set_text("DEFAULT_Txt_Account", acc)
	dlg_login.set_text("Txt_PassWord", "")
	await _message(_texts()["registered"] % acc)
	_focus_login()


# ====================================================
# SERVER
# ====================================================
func _open_server() -> void:
	if _busy:
		return
	dlg_server.set_text("DEFAULT_Edt_Host", session.host)
	dlg_server.set_text("Edt_Port", str(session.port))
	dlg_server.check_item("Chk_Dtls", session.dtls)
	aui.show_dialog(dlg_server)

func _on_server_command(cmd: String) -> void:
	match cmd:
		"IDCANCEL":
			aui.hide_dialog(dlg_server)
			_focus_login()
		"IDOK":
			var host = dlg_server.get_text("DEFAULT_Edt_Host").strip_edges()
			var port_text = dlg_server.get_text("Edt_Port").strip_edges()
			var port = port_text.to_int() if port_text.is_valid_int() else 0
			if host == "" or port < 1 or port > 65535:
				await _message(_texts()["server_invalid"])
				return
			var dtls = dlg_server.is_checked("Chk_Dtls")
			if host != session.host or port != session.port or dtls != session.dtls:
				session.close()
			session.host = host
			session.port = port
			session.dtls = dtls
			settings.set_value("host", host)
			settings.set_value("port", port)
			settings.set_value("dtls", dtls)
			settings.save()
			_show_server()
			aui.hide_dialog(dlg_server)
			_focus_login()

# Anzeige oben rechts (Platz wie "Servername"): nur die Adresse, gekürzt; Port im Dialog Server
func _show_server() -> void:
	var s: String = session.host
	dlg_control.set_text("Txt_CurrentServer", s if s.length() <= SERVER_NAME_CHARS else s.left(SERVER_NAME_CHARS - 1) + "…")
	# "Aktueller Server:" steht links davon; ist der Name länger als im Spiel vorgesehen, weicht sie aus
	var lab = dlg_control.item("Lab_Server")
	var cur = dlg_control.item("Txt_CurrentServer")
	if lab != null and cur != null:
		if not lab.has_meta("x0"):
			lab.set_meta("x0", lab.position.x)
		lab.position.x = minf(lab.get_meta("x0"), cur.position.x - 6.0 - lab.size.x)


# ====================================================
# HILFEN
# ====================================================
func message(text: String) -> void:
	get_viewport().gui_release_focus()
	await aui.message_box(text)

func _message(text: String) -> void:
	await message(text)

func _error_text(code: int) -> String:
	if code == Proto.Code.TIMEOUT and aui.text(STF_TIMEOUT) != "":
		return aui.text(STF_TIMEOUT)
	return Proto.text(code, language)

func _texts() -> Dictionary:
	return TEXTS.get(language, TEXTS["Deu"])

# Fokus wie DlgLogin::OnShowDialog: Passwort, wenn der Kontoname schon da ist
func _focus_login() -> void:
	if state != State.LOGIN or not dlg_login.visible:
		return
	var field = "Txt_PassWord" if dlg_login.get_text("DEFAULT_Txt_Account") != "" else "DEFAULT_Txt_Account"
	var e = dlg_login.item(field)
	if e != null:
		e.grab_focus.call_deferred()
