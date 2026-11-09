extends SceneTree

# ====================================================
# Test des Clients bei Verbindungsverlust (Fahrplan 11.2) mit eigenem Server (tests/test_server.gd:
# Ordner user://test_server/wiederverbinden, frische Datenbank, nur s9); die Startmap s9 muss
# importiert sein (maps_root, wie world_test.gd):
#   godot [--headless | --rendering-driver vulkan | --rendering-method gl_compatibility] --path <Projekt>
#         -s res://game/tests/reconnect_test.gd [-- --port=29130] [--language=Eng]
# Prüft: über das Login anmelden, Figur anlegen, s9 betreten, mit W laufen, eine Autoroute starten
# (Wegsuche im Thread) und sofort den Server beenden -> zurück im Login mit der Meldung "Der Server
# wird beendet", Welt freigegeben; Server neu starten, Enter schließt die Meldung, das Konto steht
# noch im Feld, anmelden, Start -> Figur an der gelaufenen Stelle mit vollem Leben. Dann meldet sich
# eine zweite Sitzung erzwungen mit demselben Konto an -> Meldung "jemand anderes angemeldet", zurück im
# Login; ohne "Anmeldung erzwingen" abgewiesen, mit Haken angemeldet (die zweite Sitzung fliegt),
# wieder in der Welt an derselben Stelle. Keine Fehler im Server-Log.
# Ende: "WIEDERVERBINDEN-TEST OK" (Exit 0) oder "WIEDERVERBINDEN-TEST FEHLER" (Exit 1), nach 300 s
# Abbruch (Exit 2).
# ====================================================

const Settings = preload("../common/settings.gd")
const Proto = preload("../common/protocol.gd")
const Net = preload("../common/net.gd")
const Session = preload("../client/session.gd")
const LoginScreen = preload("../client/login_screen.gd")
const TestServer = preload("test_server.gd")
const DIR = "user://test_server/wiederverbinden"
const DEFAULT_PORT = 29130
const PASSWORD = "geheim-123"
const LOOK = {"face": 0, "mask": 0, "hair": 1, "skin": 0, "hair_color": 0x902E1E}
const TIMEOUT = 300.0

var srv: TestServer
var port = DEFAULT_PORT
var ls
var checks = 0
var failures = 0
var _ended = false


func _initialize() -> void:
	# Der Client nimmt Host / Port aus der Kommandozeile: ohne --port der eigene Test-Port
	port = int(Settings.user_args().get("port", str(DEFAULT_PORT)))
	srv = TestServer.new(DIR, port, ["--maps=s9"])
	create_timer(TIMEOUT).timeout.connect(func(): _end(2))
	_run.call_deferred()

func _run() -> void:
	srv.fresh()
	_check("Server startet (Port %d)" % port, await srv.start(self))
	if not srv.running():
		_end(1)
		return
	var game = load("res://game/main.tscn").instantiate()
	root.add_child(game)
	await _frames(5)
	ls = game.get_node_or_null("Login")
	if ls == null:
		_check("Login im Spielstil", false)
		_end(1)
		return
	ls.session.port = port
	var acc = "Wv_%05d" % (randi() % 100000)
	await ls.session.register(acc, PASSWORD)
	if not await _login(acc, false):
		_check("anmelden über das Login", false)
		_end(1)
		return
	var hero = "Heimkehrer%02d" % (randi() % 100)
	var r = await ls.session.create_char(hero, 1, 1, 0, LOOK)
	_check("Figur %s angelegt" % hero, r["code"] == Proto.Code.OK)
	var w = await _start_world()
	_check("Welt s9 geladen", w != null)
	if w == null:
		_end(1)
		return

	# laufen, Autoroute anstoßen, Server weg
	_key(KEY_W, true)
	await create_timer(1.2).timeout
	_key(KEY_W, false)
	await _until(func(): return w.player.state == Proto.MOVE_STAND, 3.0)
	await create_timer(0.3).timeout
	var pos: Vector3 = w.player.global_position
	var hp = int(w.info["hp"])
	w.route_to(pos + Vector3(40, 0, 40), "Test")
	_check("Autoroute läuft (Wegsuche)", w.routing())
	_check("Server beendet", await srv.stop(self))
	var back = func(): return ls.state == LoginScreen.State.LOGIN and ls.world == null and ls.aui.has_message_box()
	_check("zurück im Login mit Meldungsfenster, Welt freigegeben", await _until_ok(back, 10.0))
	var msg = _message_text()
	_check("Meldung: %s" % msg.strip_edges(), msg.contains(Proto.text(Proto.Code.SERVER_CLOSING, ls.language)))
	await _frames(5)
	_check("Welt-Knoten freigegeben", not is_instance_valid(w))

	# Server wieder da, neu anmelden
	_check("Server startet neu", await srv.start(self))
	await _press(KEY_ENTER)
	_check("Enter schließt die Meldung", await _until_ok(func(): return not ls.aui.has_message_box(), 3.0))
	_check("Konto steht noch im Feld", ls.dlg_login.get_text("DEFAULT_Txt_Account") == acc)
	if not await _login(acc, false):
		_check("wieder angemeldet", false)
		_end(1)
		return
	_check("wieder angemeldet", true)
	w = await _start_world()
	_check("wieder in der Welt", w != null)
	if w == null:
		_end(1)
		return
	await _physics(10)
	var at: Vector3 = w.player.global_position
	_check("Figur an der gelaufenen Stelle (%.1f m daneben), Leben %d (vorher %d)" % [Vector2(at.x - pos.x, at.z - pos.z).length(),
		int(w.info["hp"]), hp], Vector2(at.x - pos.x, at.z - pos.z).length() < 3.0 and int(w.info["hp"]) == hp)
	pos = at

	# zweite Anmeldung desselben Kontos
	var other = _session()
	r = await other.login(acc, PASSWORD, true)
	_check("zweite Sitzung meldet sich erzwungen an", r["code"] == Proto.Code.OK)
	_check("zurück im Login mit Meldungsfenster", await _until_ok(back, 10.0))
	msg = _message_text()
	_check("Meldung: %s" % msg.strip_edges(), msg.contains(Proto.text(Proto.Code.LOGGED_IN_ELSEWHERE, ls.language)))
	await _press(KEY_ENTER)
	await _until(func(): return not ls.aui.has_message_box(), 3.0)
	ls.dlg_login.check_item("Chk_Forcelog", false)
	_check("ohne 'Anmeldung erzwingen' abgewiesen", not await _login(acc, false) and ls.aui.has_message_box()
		and _message_text().contains(Proto.text(Proto.Code.ACCOUNT_ONLINE, ls.language).left(20)))
	await _press(KEY_ENTER)
	await _until(func(): return not ls.aui.has_message_box(), 3.0)
	_check("mit 'Anmeldung erzwingen' angemeldet", await _login(acc, true))
	var kicked = func(): return other.state == Session.State.OFFLINE and other.last_kick == Proto.Code.LOGGED_IN_ELSEWHERE
	_check("die zweite Sitzung fliegt", await _until_ok(kicked, 5.0))
	w = await _start_world()
	_check("wieder in der Welt", w != null)
	if w != null:
		await _physics(10)
		at = w.player.global_position
		_check("Figur an derselben Stelle (%.1f m daneben)" % Vector2(at.x - pos.x, at.z - pos.z).length(),
			Vector2(at.x - pos.x, at.z - pos.z).length() < 0.5)
	var bad_lines = Array(srv.log_text().split("\n")).filter(func(l): return l.contains("FEHLER"))
	_check("keine Fehler im Server-Log %s" % str(bad_lines.slice(0, 3)), bad_lines.is_empty())
	_end(0 if failures == 0 else 1)


# ====================================================
# HILFEN
# ====================================================
# Anmelden über das Login (Kontoname im Feld, Passwort, ggf. "Anmeldung erzwingen") -> in der Figurenauswahl?
func _login(acc: String, force: bool) -> bool:
	ls.dlg_login.set_text("DEFAULT_Txt_Account", acc)
	ls.dlg_login.set_text("Txt_PassWord", PASSWORD)
	ls.dlg_login.check_item("Chk_Forcelog", force)
	ls._on_login_command("Btn_Login")
	await _until(_login_done, 15.0)
	return ls.state == LoginScreen.State.SELECT_CHAR

func _login_done() -> bool:
	if ls.state == LoginScreen.State.SELECT_CHAR:
		return ls.chars.dlg_list.visible
	return ls.state == LoginScreen.State.LOGIN and ls.aui.has_message_box()

# "Start" in der Figurenauswahl -> world_screen.gd, sobald die Figur in der Welt steht, sonst null
func _start_world():
	await ls.chars.refresh()
	ls.chars.show_list()
	ls.chars._on_enter_command("Btn_EnterWorld")
	await _until(func(): return ls.world != null and ls.world.ready_in_world, 90.0)
	if ls.world == null or not ls.world.ready_in_world:
		return null
	await _physics(10)
	return ls.world

# Zweite Sitzung im selben Prozess (eigene Multiplayer-API, wie world_test.gd)
func _session() -> Session:
	var branch = Node.new()
	branch.name = "Zweiter"
	root.add_child(branch)
	set_multiplayer(SceneMultiplayer.new(), branch.get_path())
	var g = Node.new()
	g.name = "Game"
	branch.add_child(g)
	var n = Net.new()
	n.name = "Net"
	g.add_child(n)
	var s = Session.new()
	s.name = "Session"
	s.port = port
	g.add_child(s)
	return s

# Texte im obersten Meldungsfenster
func _message_text() -> String:
	var out = ""
	for c in ls.aui._top.get_children():
		for n in c.find_children("*", "Label", true, false) + c.find_children("*", "RichTextLabel", true, false):
			out += n.text + " "
	return out

# Taste für die Oberfläche (Meldungsfenster: _unhandled_key_input) über den Viewport
func _press(code: Key) -> void:
	for pressed in [true, false]:
		var ev = InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		root.push_input(ev)
	await _frames(3)

# Taste für die Steuerung der Figur (Input-Abfrage)
func _key(code: Key, pressed: bool) -> void:
	var ev = InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _physics(n: int) -> void:
	for i in n:
		await physics_frame

func _until(cond: Callable, seconds: float = 10.0) -> void:
	var end = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < end:
		await process_frame
	await _frames(2)

func _until_ok(cond: Callable, seconds: float) -> bool:
	await _until(cond, seconds)
	return cond.call()

func _check(what: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("WIEDERVERBINDEN-TEST: ", "ok      " if ok else "FEHLER  ", what)

func _end(code: int) -> void:
	if _ended:
		return
	_ended = true
	if ls != null and ls.session != null:
		ls.session.close()
	if ls != null and ls.world != null:
		ls.world.stop_sounds()
		await _frames(3)
	if srv != null and srv.running():
		await srv.stop(self)
	if code == 2:
		print("WIEDERVERBINDEN-TEST FEHLER: Zeitlimit (%d Prüfungen bis dahin)" % checks)
	elif failures == 0:
		print("WIEDERVERBINDEN-TEST OK (%d Prüfungen)" % checks)
	else:
		print("WIEDERVERBINDEN-TEST FEHLER: %d von %d Prüfungen" % [failures, checks])
	quit(code if code == 2 else (0 if failures == 0 else 1))
