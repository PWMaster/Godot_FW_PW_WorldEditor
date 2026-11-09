extends SceneTree

# ====================================================
# Test von Figurenauswahl und -erstellung (client/char_select.gd) gegen einen laufenden Server:
#   godot [--headless | --rendering-driver vulkan | --rendering-method gl_compatibility] --path <Projekt>
#         -s res://game/tests/char_test.gd -- --port=29000 [--language=Eng] [--shots=<Ordner>]
# Legt ein Konto an, meldet sich an und prüft: leere Liste, Erstellung Phase 1 (Elf, weiblich,
# Barde; Vorschau gebaut), Phase 2 (Gesicht, Haut, Haarfarbe; Kopf groß), Esc zurück, Phase 3
# (ungültiger Name, gültiger Name), Figur in der Liste mit Vorschau, Welt betreten (Startmap
# s10; ohne Import Meldung und zurück), Löschen mit Rückfrage, "Beenden". Mit --shots ein Bild je Schritt (nur mit Fenster).
# Ende: "FIGUREN-TEST OK" (Exit 0) oder "FIGUREN-TEST FEHLER" (Exit 1), nach 150 s Abbruch (Exit 2).
# ====================================================

const Settings = preload("../common/settings.gd")
const Proto = preload("../common/protocol.gd")
const LoginScreen = preload("../client/login_screen.gd")
const PASSWORD = "geheim-123"

var shots = ""
var ls
var cs # char_select.gd
var checks = 0
var failures = 0


func _initialize() -> void:
	shots = str(Settings.user_args().get("shots", ""))
	var game = load("res://game/main.tscn").instantiate()
	root.add_child(game)
	create_timer(150.0).timeout.connect(func(): _end(2))
	_run.call_deferred(game)

func _run(game: Node) -> void:
	await _frames(5)
	ls = game.get_node_or_null("Login")
	if ls == null or ls.chars == null:
		_check("Login mit Figurenauswahl", false)
		_end(1)
		return
	cs = ls.chars
	var acc = "Ct_%05d" % (randi() % 100000)
	var r = await ls.session.register(acc, PASSWORD)
	_check("Konto %s anlegen" % acc, r["code"] == Proto.Code.OK)
	ls.dlg_login.set_text("DEFAULT_Txt_Account", acc)
	ls.dlg_login.set_text("Txt_PassWord", PASSWORD)
	ls._on_login_command("Btn_Login")
	await _until(func(): return ls.state == LoginScreen.State.SELECT_CHAR and cs.dlg_list.visible)
	_check("Figurenauswahl offen", cs.dlg_list.visible and cs.dlg_line.visible and cs.dlg_enter.visible)
	_check("Liste leer, Erstellen möglich", cs.chars.is_empty() and not cs.dlg_list.is_shown("Rdo_Char1")
		and not cs.dlg_list.item("Btn_Create").disabled)
	_check("Startvorlagen bekannt (%d)" % cs.classes.size(), cs.classes.size() >= 20)
	await _shot("1_list_empty")

	# Phase 1
	cs._on_list_command("Btn_Create")
	await _frames(3)
	_check("Phase 1 offen", cs.phase == 1 and cs.dlg_create1.visible and cs.dlg_control.visible)
	cs._on_create1_command("Rdo_Race2")
	cs._on_create1_command("Rdo_Female")
	cs._on_create1_command("Rdo_2_8")
	await _frames(3)
	_check("Elf, weiblich, Barde", cs.race == 2 and cs.gender == 1 and cs.cls == 8)
	_check("nur Elfen-Klassen sichtbar", cs.dlg_create1.is_shown("Rdo_2_8") and not cs.dlg_create1.is_shown("Rdo_1_1"))
	_check("Beschreibung rechts (Win_CreateProfDesc)", cs.dlg_desc.visible and cs.dlg_desc.get_text("Txt_Desc").contains(cs.class_name_of(8)))
	_check("Vorschau gebaut", cs.preview.model != null and cs.preview.model.root != null and cs.preview.model.race == 2)
	cs._on_create1_command("Rdo_Race4")
	await _frames(2)
	_check("Steinmensch: nur männlich", cs.gender == 0 and not cs.dlg_create1.is_shown("Rdo_Female"))
	cs._on_create1_command("Rdo_Race2")
	cs._on_create1_command("Rdo_Female")
	cs._on_create1_command("Rdo_2_8")
	await _frames(3)
	await _shot("2_phase1")

	# Phase 2
	cs._on_control_command("Btn_Next")
	await _frames(3)
	_check("Phase 2 offen, Kopf groß", cs.phase == 2 and cs.dlg_create2.visible and cs.preview.close_up)
	cs._on_create2_command("Btn_FaceR")
	cs._on_create2_command("Btn_FaceColorR")
	cs._on_create2_command("Btn_FaceColorR")
	cs._on_create2_command("Rdo_C16")
	await _frames(3)
	_check("Gesicht 1, Haut 2, Haarfarbe Vorgabe 16", cs.look["face"] == 1 and cs.look["skin"] == 2
		and cs.look["hair_color"] == 0x43B8FF)
	await _shot("3_phase2")
	await _key(KEY_ESCAPE)
	_check("Esc -> Phase 1", cs.phase == 1)
	cs._on_control_command("Btn_Next")
	cs._on_control_command("Btn_Next")
	cs._on_control_command("Btn_Return")
	cs._on_control_command("Btn_Next")
	await _frames(3)
	_check("Zurück / Weiter -> Phase 3, Aussehen behalten", cs.phase == 3 and cs.dlg_create3.visible and cs.look["face"] == 1)
	_check("Phase 3: Erstellen statt Weiter", cs.dlg_control.is_shown("Btn_Confirm") and not cs.dlg_control.is_shown("Btn_Next"))

	# Phase 3: Name
	cs.dlg_create3.set_text("DEFAULT_CharName", "x")
	cs._on_control_command("Btn_Confirm")
	await _message_shown()
	_check("ungültiger Name gemeldet", _message() == Proto.text(Proto.Code.CHAR_NAME_INVALID, ls.language))
	_close_message()
	var hero = "Liedel%03d" % (randi() % 1000)
	cs.dlg_create3.set_text("DEFAULT_CharName", hero)
	await _shot("4_phase3")
	cs._on_control_command("Btn_Confirm")
	await _until(func(): return cs.phase == 0 and not cs.chars.is_empty())
	_check("Figur %s angelegt und gewählt" % hero, cs.chars.size() == 1 and cs.chars[0]["name"] == hero and cs.selected == 0)
	_check("Liste zeigt Name und Klasse", cs.dlg_list.get_text("Txt_Name1") == hero
		and cs.dlg_list.get_text("Txt_Desc1").begins_with(cs.class_name_of(8)))
	_check("Vorschau der Figur", cs.preview.model.root != null and cs.preview.model.appearance.get("hair_color") == 0x43B8FF)
	await _frames(5)
	await _shot("5_list")

	# Welt betreten, löschen, beenden
	# Startmap des Elfen ist s10; im Testprojekt nicht importiert -> Meldung, zurück zur Auswahl
	cs._on_enter_command("Btn_EnterWorld")
	await _until(func(): return ls.aui.has_message_box(), 30.0)
	_check("Welt betreten: Startmap s10 (nicht importiert gemeldet)", _message().contains("s10"))
	_close_message()
	await _until(func(): return ls.state == LoginScreen.State.SELECT_CHAR and cs.dlg_list.visible and not cs._busy)
	_check("zurück in der Figurenauswahl", cs.dlg_list.visible and cs.chars.size() == 1)
	cs._select(0)
	await _frames(2)
	cs._on_list_command("Btn_Delete")
	await _message_shown()
	_check("Löschen fragt nach (stf 206)", _message() == ls.aui.text(206).replace("\r", "\n"))
	_top_message().send("IDYES")
	await _until(func(): return cs.chars.is_empty() and not cs._busy)
	_check("Figur gelöscht", cs.chars.is_empty() and not cs.dlg_list.is_shown("Rdo_Char1"))
	cs.dlg_line.item("Btn_CharReturn").pressed.emit()
	await _until(func(): return ls.state == LoginScreen.State.LOGIN and not ls._busy)
	_check("Beenden -> Login", ls.state == LoginScreen.State.LOGIN and ls.dlg_login.visible and not cs.dlg_list.visible)
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
	print("FIGUREN-TEST: ", "ok      " if ok else "FEHLER  ", what)

func _end(code: int) -> void:
	if ls != null and ls.session != null:
		ls.session.close()
	if code == 2:
		print("FIGUREN-TEST FEHLER: Zeitlimit (%d Prüfungen bis dahin)" % checks)
	elif failures == 0:
		print("FIGUREN-TEST OK (%d Prüfungen)" % checks)
	else:
		print("FIGUREN-TEST FEHLER: %d von %d Prüfungen" % [failures, checks])
	quit(code)
