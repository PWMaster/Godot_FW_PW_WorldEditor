extends SceneTree

# ====================================================
# Test des Logins im Spielstil (client/login_screen.gd) gegen einen laufenden Server:
#   godot [--headless | --rendering-driver vulkan | --rendering-method gl_compatibility] --path <Projekt>
#         -s res://game/tests/login_test.gd -- --port=29000 [--language=Eng] [--shots=<Ordner>]
# Prüft: Dialoge da (ohne Warnungen), Tastatur (Enter springt zum leeren Passwortfeld, Tab im Kreis,
# Esc schließt "Konto anlegen", Enter schließt ein Meldungsfenster), Konto anlegen (Passwörter
# verschieden, dann richtig), falsches Passwort, leere Felder, Anmelden mit Enter (-> Figurenauswahl),
# "Beenden" (abmelden),
# Server-Dialog mit ungültigem Port. Mit --shots ein Bild je Schritt (nur mit Fenster).
# Ende: "LOGIN-TEST OK" (Exit 0) oder "LOGIN-TEST FEHLER" (Exit 1), nach 120 s Abbruch (Exit 2).
# Braucht die Spieldaten (Oberfläche) und schreibt user://settings.cfg (Konto merken).
# ====================================================

const Settings = preload("../common/settings.gd")
const Proto = preload("../common/protocol.gd")
const LoginScreen = preload("../client/login_screen.gd")
const Session = preload("../client/session.gd")
const PASSWORD = "geheim-123"

var shots = ""
var ls # login_screen.gd
var checks = 0
var failures = 0


func _initialize() -> void:
	shots = str(Settings.user_args().get("shots", ""))
	var game = load("res://game/main.tscn").instantiate()
	root.add_child(game)
	create_timer(120.0).timeout.connect(func(): _end(2))
	_run.call_deferred(game)

func _run(game: Node) -> void:
	await _frames(5)
	ls = game.get_node_or_null("Login")
	_check("Login im Spielstil", ls != null and ls.dlg_login != null)
	if ls == null or ls.dlg_login == null:
		_end(1)
		return
	_check("ohne Warnungen der Oberfläche (%s)" % ", ".join(ls.aui.warnings), ls.aui.warnings.is_empty())
	_check("Win_Login und Win_LoginControl sichtbar", ls.dlg_login.visible and ls.dlg_control.visible)
	await _shot("1_login")
	var texts = ls._texts()

	# Tastatur
	var account: LineEdit = ls.dlg_login.item("DEFAULT_Txt_Account")
	var password: LineEdit = ls.dlg_login.item("Txt_PassWord")
	account.text = "Lt_%05d" % (randi() % 100000)
	password.text = ""
	account.grab_focus()
	await _key(KEY_ENTER)
	_check("Enter im Kontofeld -> Passwortfeld", _focus() == password and not ls.aui.has_message_box())
	await _key(KEY_TAB)
	_check("Tab -> zurück zum Kontofeld", _focus() == account)

	# Konto anlegen
	ls._on_login_command("Btn_Register")
	await _frames(2)
	_check("Konto anlegen offen", ls.dlg_register.visible)
	await _key(KEY_ESCAPE)
	_check("Esc schließt Konto anlegen", not ls.dlg_register.visible)
	ls._on_login_command("Btn_Register")
	await _frames(2)
	ls.dlg_register.set_text("Edt_Password", PASSWORD)
	ls.dlg_register.set_text("Edt_Password2", PASSWORD + "x")
	await _shot("2_register")
	ls._on_register_command("IDOK")
	await _message_shown()
	_check("verschiedene Passwörter gemeldet", _message() == texts["password_mismatch"])
	await _shot("3_mismatch")
	await _key(KEY_ENTER)
	_check("Enter schließt das Meldungsfenster", not ls.aui.has_message_box())
	ls.dlg_register.set_text("Edt_Password2", PASSWORD)
	ls._on_register_command("IDOK")
	await _message_shown()
	var acc = ls.dlg_register.get_text("DEFAULT_Edt_Account")
	_check("Konto %s angelegt" % acc, _message() == texts["registered"] % acc)
	await _shot("4_registered")
	_close_message()
	await _frames(2)
	_check("Kontoname im Login eingetragen", account.text == acc and not ls.dlg_register.visible)

	# Fehler
	password.text = PASSWORD + "x"
	ls._on_login_command("Btn_Login")
	await _message_shown()
	_check("falsches Passwort gemeldet", _message() == Proto.text(Proto.Code.WRONG_LOGIN, ls.language))
	await _shot("5_wrong")
	_close_message()
	await _frames(2)
	_check("zurück im Login", ls.state == LoginScreen.State.LOGIN and ls.dlg_login.visible)
	account.text = ""
	password.text = ""
	ls._on_login_command("Btn_Login")
	await _message_shown()
	_check("leere Felder gemeldet (loginui.stf 203)", _message() == ls.aui.text(203).replace("\r", "\n"))
	_close_message()
	await _frames(2)

	# Anmelden mit Enter im Passwortfeld, abmelden
	account.text = acc
	password.text = PASSWORD
	password.grab_focus()
	await _key(KEY_ENTER)
	await _until(func(): return ls.state == LoginScreen.State.SELECT_CHAR or ls.aui.has_message_box())
	_check("angemeldet als %s, Figurenauswahl" % acc, ls.state == LoginScreen.State.SELECT_CHAR and ls.session.account == acc)
	await _until(func(): return ls.chars.dlg_list.visible)
	await _shot("6_logged_in")
	ls.chars.dlg_line.item("Btn_CharReturn").pressed.emit()
	await _until(func(): return ls.state == LoginScreen.State.LOGIN and not ls._busy)
	_check("abgemeldet, zurück im Login", ls.state == LoginScreen.State.LOGIN and ls.session.state == Session.State.OFFLINE)

	# Server-Dialog
	ls._on_control_command("Btn_ServerList")
	await _frames(2)
	var port_text = ls.dlg_server.get_text("Edt_Port")
	ls.dlg_server.set_text("Edt_Port", "0")
	await _shot("7_server")
	ls._on_server_command("IDOK")
	await _message_shown()
	_check("ungültiger Port gemeldet", _message() == texts["server_invalid"])
	_close_message()
	ls.dlg_server.set_text("Edt_Port", port_text)
	await _key(KEY_ESCAPE)
	_check("Esc schließt den Server-Dialog", not ls.dlg_server.visible)
	_end(0 if failures == 0 else 1)


# ====================================================
# HILFEN
# ====================================================
func _key(code: Key) -> void:
	for pressed in [true, false]:
		var ev = InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		root.push_input(ev)
	await _frames(3)

func _focus() -> Control:
	return root.gui_get_focus_owner()

func _message_shown() -> void:
	await _until(func(): return ls.aui.has_message_box())

func _top_message():
	return ls.aui._top.get_child(ls.aui._top.get_child_count() - 1)

func _message() -> String:
	return _top_message().get_text("Txt_Message") if ls.aui.has_message_box() else ""

func _close_message() -> void:
	if ls.aui.has_message_box():
		_top_message().send("IDOK")

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _until(cond: Callable, seconds: float = 10.0) -> void:
	var end = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < end:
		await process_frame
	await _frames(2)

func _shot(shot_name: String) -> void:
	await _frames(2)
	if shots == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(shots)
	root.get_texture().get_image().save_png(shots.path_join(shot_name + ".png"))

func _check(what: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("LOGIN-TEST: ", "ok      " if ok else "FEHLER  ", what)

func _end(code: int) -> void:
	if ls != null and ls.session != null:
		ls.session.close()
	if code == 2:
		print("LOGIN-TEST FEHLER: Zeitlimit (%d Prüfungen bis dahin)" % checks)
	elif failures == 0:
		print("LOGIN-TEST OK (%d Prüfungen)" % checks)
	else:
		print("LOGIN-TEST FEHLER: %d von %d Prüfungen" % [failures, checks])
	quit(code)
