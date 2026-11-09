extends Node

# ====================================================
# Figurenauswahl und -erstellung im Stil des Spiels, Teil von login_screen.gd (dessen Oberfläche,
# Sitzung und Einstellungen). Dialoge aus loginui.dcf, Abläufe nach DlgCharList, DlgSelectLine,
# DlgCharEnterWorld, DlgCreate_SelRace, DlgCreateSelectStyle, DlgCreateNameAndBirth und
# DlgCreate_CamControl; 3D-Vorschau der Figur (char_preview.gd) zwischen Hintergrund und Dialogen.
# Auswahl (Hintergrund LoginWorld\CharListBack.dds): Win_CharList (8 Plätze: Name,
#   "Klasse (Rasse) LvX", Klassen-Symbol), Win_CharSelectLine (letzter Login, "Beenden" = zurück
#   zum Login), Win_CharEnterWorld ("Start": Figur wählen und die Welt betreten, world_screen.gd).
#   "Erstellen", "Löschen" (Rückfrage loginui.stf 206).
# Erstellung (Hintergrund LoginWorld\CreateBack.dds), Win_CreateControl wie DlgCreate_CamControl:
#   drehen und Kamera vor / zurück (gedrückt halten), "Zurück", "Weiter" (Phase 1 / 2),
#   "Erstellen" (Phase 3)
#   Phase 1 Win_Create1  Rasse, Geschlecht, Klasse (nur Kombinationen mit Startvorlage des Servers,
#                        char_list.classes); Klasse, Schwierigkeit und Beschreibung (stf 501 + Klasse)
#                        im Dialog Win_CreateProfDesc rechts (in Win_Create1 überdecken sie die Wahl)
#   Phase 2 Win_Create2  Gesicht, Maske, Haut (19), Frisur, Haarfarbe (54 Vorgaben, R / G / B);
#                        Anzahl und Namen aus loginui.stf wie FillFace / FillHair / FillAccessories;
#                        Kamera auf den Kopf
#   Phase 3 Win_Create3  Name
#   Zurück auch mit Esc oder den Phasen-Häkchen; aus Phase 1 mit Rückfrage (stf 230) zur Liste.
# Ausgeblendet: Wiederherstellen, Server-Linien, Passwort-Karte, IP-Anzeige, PvP-Logos und Stempel
# der Liste, Dämon,
# Hörner, Sättigung, Geburtstag / Sternzeichen (noch ohne Bedeutung im Spiel).
# ====================================================

const Proto = preload("../common/protocol.gd")
const Preview = preload("char_preview.gd")
const AuiManager = preload("ui/aui_manager.gd")
const MAX_SLOTS = 8
const SELECT_BACK = "LoginWorld\\CharListBack.dds"
const CREATE_BACK = "LoginWorld\\CreateBack.dds"
const STF_CLASS = 101 # + Klasse
const STF_DESC = 501 # + Klasse
const STF_FACE = 601 # + (Rasse - 1) * 200 + Geschlecht * 50 + Nr.
const STF_HAIR = 701
const STF_MASK = 2000 # + Geschlecht * 1000 + Rasse * 100 + (Gesicht + 1) * 10 + Nr.
const STF_DELETE_ASK = 206
const STF_CANCEL_ASK = 230
const SKIN_COLORS = 19
const COLOR_LOW = 30 # Haarfarbe R / G / B: Regler von 30 bis 220
const COLOR_HIGH = 220
const STARS = "SM\\smcreate\\Blue_Star_%d.tga"
const RACES = [1, 2, 3, 4, 5, 6]
const HIDDEN = {
	"Win_CharList": ["Btn_Restore", "Gfx1", "Gfx2"],
	"Win_CharSelectLine": ["Combo_Selectline", "Gfx_0", "Txt_Password", "Btn_Link", "Txt_PwdCard", "Img_Line1",
		"Img_Line2", "Txt_IP_1", "Txt_IP_2", "Txt_Accord"],
	"Win_Create1": ["Rdo_Race7", "Rdo_7_10", "Txt_Des", "Txt_Prof", "Img_Icon", "Lab_Hard", "Img_Hard"],
	"Win_Create2": ["Rdo_6", "Sli_9", "Btn_HornL", "Btn_HornR", "Sli_8", "Btn_HairColorH1", "Btn_HairColorH2",
		"Lab_HairColorH", "Lst_Month", "Lst_Day"],
	"Win_Create3": ["Img_Title", "Img_1", "Img_2", "Lab_Birth", "Lab_Month", "Lab_Day", "Img_Star", "Txt_Star",
		"Lab_Star", "Txt_StarDetail", "Combo_Month", "Combo_Day"],
}
const TEXTS = {
	"Deu": {"never": "-"},
	"Eng": {"never": "-"},
	"Franz": {"never": "-"},
}

signal back_to_login

var login # login_screen.gd
var aui
var session
var preview: Preview
var chars: Array = []
var classes: Array = [] # "<Rasse>_<Klasse>_<Geschlecht>"
var max_chars = MAX_SLOTS
var selected = -1
var phase = 0 # 0 Auswahl, 1 - 3 Erstellung
var race = 1
var gender = 0
var cls = 1
var look = {}
var race_names = {}
var dlg_list
var dlg_line
var dlg_enter
var dlg_create1
var dlg_create2
var dlg_create3
var dlg_control
var dlg_desc
var _busy = false
var _hard_label = ""


func setup(p_login) -> String:
	login = p_login
	aui = login.aui
	session = login.session
	preview = Preview.new()
	preview.name = "Vorschau"
	add_child(preview)
	preview.setup(login.settings.value("data_root"))
	dlg_list = aui.dialog("CharList.xml")
	dlg_line = aui.dialog("Char_SelectLine.xml")
	dlg_enter = aui.dialog("Char_EnterWorld.xml")
	dlg_create1 = aui.dialog("Create_1.xml")
	dlg_create2 = aui.dialog("Create_2.xml")
	dlg_create3 = aui.dialog("Create_3.xml")
	dlg_control = aui.dialog("Create_Control.xml")
	dlg_desc = aui.dialog("Create_ProfDesc.xml")
	for d in _dialogs():
		if d == null:
			return "Dialog der Figurenauswahl fehlt (%s)" % ", ".join(aui.warnings)
		for item_name in HIDDEN.get(d.dlg_name, []):
			d.show_item(item_name, false)
	dlg_list.command.connect(_on_list_command)
	dlg_line.command.connect(_on_line_command)
	dlg_enter.command.connect(_on_enter_command)
	dlg_create1.command.connect(_on_create1_command)
	dlg_create2.command.connect(_on_create2_command)
	dlg_create3.command.connect(_on_create3_command)
	dlg_control.command.connect(_on_control_command)
	# gedrückt halten: drehen, Kamera vor / zurück
	for hold in [["Btn_Left", preview.turn, 1], ["Btn_Right", preview.turn, -1],
			["Btn_CameraMoveFront", preview.zoom, 1], ["Btn_CameraMoveBack", preview.zoom, -1]]:
		var b = dlg_control.item(hold[0])
		if b is BaseButton:
			b.button_down.connect(hold[1].bind(hold[2]))
			b.button_up.connect(hold[1].bind(0))
	for r in RACES:
		race_names[r] = dlg_create1.get_text("Rdo_Race%d" % r).strip_edges()
	_hard_label = dlg_create1.get_text("Lab_Hard").strip_edges()
	var name_edit = dlg_create3.item("DEFAULT_CharName")
	if name_edit is LineEdit:
		name_edit.max_length = 12
	return ""

func _dialogs() -> Array:
	return [dlg_list, dlg_line, dlg_enter, dlg_create1, dlg_create2, dlg_create3, dlg_control, dlg_desc]

func _texts() -> Dictionary:
	return TEXTS.get(login.language, TEXTS["Deu"])

# Nach der Anmeldung: Liste holen und zeigen
func open() -> void:
	aui.set_scene(preview.texture())
	await refresh()
	show_list()

func close() -> void:
	for d in _dialogs():
		aui.hide_dialog(d)
	preview.clear()
	preview.turn(0)
	aui.set_scene(null)
	phase = 0

func refresh() -> void:
	var r = await session.list_chars()
	if r["code"] != Proto.Code.OK:
		await login.message(Proto.text(r["code"], login.language))
		return
	chars = r["data"].get("chars", [])
	classes = r["data"].get("classes", [])
	max_chars = int(r["data"].get("max", MAX_SLOTS))
	if selected >= chars.size():
		selected = chars.size() - 1
	if selected < 0 and not chars.is_empty():
		selected = 0


# ====================================================
# AUSWAHL
# ====================================================
func show_list() -> void:
	phase = 0
	aui.set_background(SELECT_BACK)
	for d in [dlg_create1, dlg_create2, dlg_create3, dlg_control, dlg_desc]:
		aui.hide_dialog(d)
	for i in MAX_SLOTS:
		var n = i + 1
		var has = i < chars.size()
		for item_name in ["Rdo_Char%d", "Txt_Name%d", "Txt_Desc%d", "Img_Prof%d"]:
			dlg_list.show_item(item_name % n, has)
		dlg_list.show_item("Img_PVP_%d" % n, false)
		dlg_list.show_item("Img_Char%d" % n, false)
		if has:
			var c = chars[i]
			dlg_list.set_text("Txt_Name%d" % n, c["name"])
			dlg_list.set_text("Txt_Desc%d" % n, "%s (%s) Lv%d" % [class_name_of(c["class"]), race_names.get(int(c["race"]), "?"), c["level"]])
			dlg_list.set_frame("Img_Prof%d" % n, int(c["class"]))
	dlg_list.enable_item("Btn_Create", chars.size() < max_chars)
	dlg_list.enable_item("Btn_Delete", selected >= 0)
	dlg_enter.enable_item("Btn_EnterWorld", selected >= 0)
	aui.show_dialog(dlg_list)
	aui.show_dialog(dlg_line)
	aui.show_dialog(dlg_enter)
	_select(selected)
	# Figur mittig zwischen Liste (links) und rechter Leiste
	var w = aui.size.x
	preview.set_close_up(false)
	preview.reset_turn()
	preview.set_screen_x(clampf((dlg_list.size.x + (w - dlg_line.size.x)) / 2.0 / w, 0.3, 0.7))

func _select(index: int) -> void:
	selected = index
	for i in MAX_SLOTS:
		dlg_list.check_item("Rdo_Char%d" % (i + 1), i == index)
	dlg_list.enable_item("Btn_Delete", index >= 0)
	dlg_enter.enable_item("Btn_EnterWorld", index >= 0)
	if index < 0:
		preview.clear()
		dlg_line.set_text("Txt_Time", _texts()["never"])
		return
	var c = chars[index]
	var t = int(c.get("last_played", 0))
	var local = t + int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	dlg_line.set_text("Txt_Time", Time.get_datetime_string_from_unix_time(local, true) if t > 0 else _texts()["never"])
	_show_preview(int(c["race"]), int(c["gender"]), int(c["class"]), c.get("appearance", {}))

func _on_list_command(cmd: String) -> void:
	if _busy or aui.has_message_box():
		return
	if cmd.begins_with("Rdo_Char"):
		_select(cmd.trim_prefix("Rdo_Char").to_int() - 1)
	elif cmd == "Btn_Create":
		start_create()
	elif cmd == "Btn_Delete" and selected >= 0:
		var c = chars[selected]
		if await aui.message_box(aui.text(STF_DELETE_ASK), AuiManager.MB_YESNO) != "IDYES":
			return
		_busy = true
		var r = await session.delete_char(int(c["id"]))
		_busy = false
		if r["code"] != Proto.Code.OK:
			await login.message(Proto.text(r["code"], login.language))
		await refresh()
		show_list()

func _on_line_command(cmd: String) -> void:
	if cmd == "Btn_CharReturn" and not _busy:
		back_to_login.emit()

func _on_enter_command(cmd: String) -> void:
	if cmd != "Btn_EnterWorld" or selected < 0 or _busy or aui.has_message_box():
		return
	_busy = true
	var r = await session.enter_char(int(chars[selected]["id"]))
	_busy = false
	if r["code"] != Proto.Code.OK:
		await login.message(Proto.text(r["code"], login.language))
		return
	login.enter_world(r["data"])


# ====================================================
# ERSTELLUNG
# ====================================================
func start_create() -> void:
	if chars.size() >= max_chars:
		await login.message(Proto.text(Proto.Code.CHAR_LIMIT, login.language))
		return
	race = 1
	gender = 0
	cls = 1
	_fix_gender_class()
	look = {"face": 0, "mask": 0, "hair": 0, "skin": 0, "hair_color": _rgb_int(preview_data("default_hair_color", [234, 248, 253]))}
	dlg_create3.set_text("DEFAULT_CharName", "")
	for d in [dlg_list, dlg_line, dlg_enter]:
		aui.hide_dialog(d)
	aui.set_background(CREATE_BACK)
	preview.reset_turn()
	_set_phase(1)

func _set_phase(p: int) -> void:
	phase = p
	var shown = [dlg_create1, dlg_create2, dlg_create3][p - 1]
	for d in [dlg_create1, dlg_create2, dlg_create3]:
		if d != shown:
			aui.hide_dialog(d)
	for d in [dlg_create1, dlg_create2, dlg_create3]:
		for i in range(1, 4):
			d.check_item("Chk_Phase%d" % i, i == p)
			d.enable_item("Chk_Phase%d" % i, i < p)
	dlg_control.show_item("Btn_Next", p < 3)
	dlg_control.show_item("Btn_Confirm", p == 3)
	aui.show_dialog(shown)
	aui.show_dialog(dlg_control)
	if p == 1:
		aui.show_dialog(dlg_desc)
	else:
		aui.hide_dialog(dlg_desc)
	# Figur rechts neben den Erstellungs-Dialogen, in Phase 2 der Kopf groß
	var w = aui.size.x
	var left = dlg_create1.size.x * 0.5
	preview.reset_zoom()
	preview.set_close_up(p == 2)
	preview.set_screen_x(clampf((left + w) / 2.0 / w, 0.45, 0.75))
	if p == 1:
		_update_create1()
	elif p == 2:
		_fill_style()
	_show_preview(race, gender, cls, look)

func _on_control_command(cmd: String) -> void:
	if _busy or aui.has_message_box():
		return
	match cmd:
		"Btn_Next":
			if phase < 3:
				_set_phase(phase + 1)
		"Btn_Confirm":
			create()
		"Btn_Return":
			previous()

# Eine Phase zurück, aus Phase 1 mit Rückfrage zur Liste
func previous() -> void:
	if phase > 1:
		_set_phase(phase - 1)
	elif phase == 1 and await aui.message_box(aui.text(STF_CANCEL_ASK), AuiManager.MB_YESNO) == "IDYES":
		show_list()

# Zurück: Phasen-Häkchen
func _on_phase_command(cmd: String) -> bool:
	if cmd.begins_with("Chk_Phase"):
		var p = cmd.trim_prefix("Chk_Phase").to_int()
		if p >= 1 and p < phase:
			_set_phase(p)
		else:
			_set_phase(phase) # Häkchen wieder richtig setzen
		return true
	return false

func _unhandled_key_input(event: InputEvent) -> void:
	var k = event as InputEventKey
	if k == null or not k.pressed or k.echo or k.keycode != KEY_ESCAPE or phase == 0 or aui.has_message_box():
		return
	get_viewport().set_input_as_handled()
	previous()

func create() -> void:
	var char_name = dlg_create3.get_text("DEFAULT_CharName").strip_edges()
	if char_name == "":
		await login.message(Proto.text(Proto.Code.CHAR_NAME_INVALID, login.language))
		return
	_busy = true
	dlg_control.enable_item("Btn_Confirm", false)
	var r = await session.create_char(char_name, race, cls, gender, look)
	_busy = false
	dlg_control.enable_item("Btn_Confirm", true)
	if r["code"] != Proto.Code.OK:
		await login.message(Proto.text(r["code"], login.language))
		return
	await refresh()
	var new_id = r["data"]["char"]["id"]
	for i in chars.size():
		if chars[i]["id"] == new_id:
			selected = i
	show_list()

# --- Phase 1: Rasse, Geschlecht, Klasse (DlgCreate_SelRace) ---
func _on_create1_command(cmd: String) -> void:
	if _on_phase_command(cmd):
		return
	if cmd.begins_with("Rdo_Race"):
		race = cmd.trim_prefix("Rdo_Race").to_int()
	elif cmd == "Rdo_Male":
		gender = 0
	elif cmd == "Rdo_Female":
		gender = 1
	elif cmd.begins_with("Rdo_%d_" % race):
		cls = cmd.get_slice("_", 2).to_int()
	else:
		return
	_fix_gender_class()
	_update_create1()
	_show_preview(race, gender, cls, look)

# Wie PlayerUtil::FixGenderProfession: nur Kombinationen mit Startvorlage
func _fix_gender_class() -> void:
	if not _has(race, cls, gender):
		var for_gender = _classes_of(race, gender)
		if not for_gender.is_empty():
			cls = for_gender[0]
		else:
			gender = 1 - gender
			var other = _classes_of(race, gender)
			if not other.is_empty() and not cls in other:
				cls = other[0]

func _has(r: int, c: int, g: int) -> bool:
	return classes.has("%d_%d_%d" % [r, c, g])

func _classes_of(r: int, g: int) -> Array:
	var out = []
	for c in range(1, 11):
		if _has(r, c, g):
			out.append(c)
	return out

func _update_create1() -> void:
	for r in RACES:
		dlg_create1.check_item("Rdo_Race%d" % r, r == race)
		dlg_create1.show_item("Img_Select%d" % r, r == race)
		dlg_create1.enable_item("Rdo_Race%d" % r, not _classes_of(r, 0).is_empty() or not _classes_of(r, 1).is_empty())
	dlg_create1.show_item("Img_Select7", false)
	dlg_create1.check_item("Rdo_Male", gender == 0)
	dlg_create1.check_item("Rdo_Female", gender == 1)
	dlg_create1.show_item("Rdo_Female", not _classes_of(race, 1).is_empty())
	dlg_create1.show_item("Rdo_Male", not _classes_of(race, 0).is_empty())
	for r in range(1, 8):
		for c in range(1, 11):
			var item_name = "Rdo_%d_%d" % [r, c]
			if dlg_create1.item(item_name) != null:
				dlg_create1.show_item(item_name, r == race and _has(r, c, gender))
				dlg_create1.check_item(item_name, r == race and c == cls)
	# Schwierigkeit wie UpdateView: Blue_Star_5 / 3 / 4
	var stars = 5 if cls in [1, 3, 9] else (3 if cls in [2, 5, 6] else 4)
	dlg_desc.set_text("Txt_Desc", "^ffd27f%s^ffffff\n%s %s\n\n%s" % [class_name_of(cls), _hard_label, "★".repeat(stars),
		aui.text(STF_DESC + cls)])
	dlg_control.enable_item("Btn_Next", _has(race, cls, gender))

# --- Phase 2: Aussehen (DlgCreateSelectStyle) ---
func _fill_style() -> void:
	dlg_create2.set_total("Sli_1", _count(STF_FACE + (race - 1) * 200 + gender * 50))
	dlg_create2.set_total("Sli_3", _count(STF_HAIR + (race - 1) * 200 + gender * 50))
	dlg_create2.set_total("Sli_2", SKIN_COLORS)
	for s in ["Sli_4", "Sli_6", "Sli_7"]:
		dlg_create2.set_total(s, COLOR_HIGH - COLOR_LOW + 1)
	_fill_masks()
	_style_to_controls()

func _fill_masks() -> void:
	var n = _count(_mask_base())
	dlg_create2.set_total("Sli_5", n)
	look["mask"] = clampi(look.get("mask", 0), 0, maxi(0, n - 1))

func _mask_base() -> int:
	return STF_MASK + gender * 1000 + race * 100 + (int(look.get("face", 0)) + 1) * 10

func _style_to_controls() -> void:
	dlg_create2.set_level("Sli_1", look["face"])
	dlg_create2.set_level("Sli_5", look["mask"])
	dlg_create2.set_level("Sli_2", look["skin"])
	dlg_create2.set_level("Sli_3", look["hair"])
	var c = look["hair_color"]
	dlg_create2.set_level("Sli_4", clampi((c >> 16) & 0xFF, COLOR_LOW, COLOR_HIGH) - COLOR_LOW)
	dlg_create2.set_level("Sli_6", clampi((c >> 8) & 0xFF, COLOR_LOW, COLOR_HIGH) - COLOR_LOW)
	dlg_create2.set_level("Sli_7", clampi(c & 0xFF, COLOR_LOW, COLOR_HIGH) - COLOR_LOW)
	dlg_create2.set_color("Img_Input", Color.hex((c << 8) | 0xFF))
	_hint("Sli_1", STF_FACE + (race - 1) * 200 + gender * 50 + look["face"])
	_hint("Sli_5", _mask_base() + look["mask"])
	_hint("Sli_3", STF_HAIR + (race - 1) * 200 + gender * 50 + look["hair"])

func _hint(item_name: String, stf: int) -> void:
	var c = dlg_create2.item(item_name)
	if c != null:
		c.tooltip_text = aui.text(stf)

func _on_create2_command(cmd: String) -> void:
	if _on_phase_command(cmd):
		return
	var steps = {"Btn_FaceL": ["Sli_1", -1], "Btn_FaceR": ["Sli_1", 1], "Btn_FaceDetailL": ["Sli_5", -1],
		"Btn_FaceDetailR": ["Sli_5", 1], "Btn_FaceColorL": ["Sli_2", -1], "Btn_FaceColorR": ["Sli_2", 1],
		"Btn_HairL": ["Sli_3", -1], "Btn_HairR": ["Sli_3", 1], "Btn_HairColorR1": ["Sli_4", -1],
		"Btn_HairColorR2": ["Sli_4", 1], "Btn_HairColorG1": ["Sli_6", -1], "Btn_HairColorG2": ["Sli_6", 1],
		"Btn_HairColorB1": ["Sli_7", -1], "Btn_HairColorB2": ["Sli_7", 1]}
	if steps.has(cmd):
		var s = steps[cmd]
		dlg_create2.set_level(s[0], dlg_create2.get_level(s[0]) + s[1])
		cmd = s[0]
	if cmd.begins_with("Rdo_C") and cmd.trim_prefix("Rdo_C").is_valid_int():
		var colors: Array = preview_data("hair_colors", [])
		var i = cmd.trim_prefix("Rdo_C").to_int() - 1
		if i >= 0 and i < colors.size():
			look["hair_color"] = _rgb_int(colors[i])
	elif cmd == "Btn_CreateRandomSelect":
		look["face"] = randi() % maxi(1, _count(STF_FACE + (race - 1) * 200 + gender * 50))
		_fill_masks()
		look["mask"] = randi() % maxi(1, _count(_mask_base()))
		look["hair"] = randi() % maxi(1, _count(STF_HAIR + (race - 1) * 200 + gender * 50))
		look["skin"] = randi() % SKIN_COLORS
		look["hair_color"] = (randi_range(COLOR_LOW, COLOR_HIGH) << 16) | (randi_range(COLOR_LOW, COLOR_HIGH) << 8) | randi_range(COLOR_LOW, COLOR_HIGH)
	elif cmd == "Sli_1":
		look["face"] = dlg_create2.get_level("Sli_1")
		look["mask"] = 0
		_fill_masks()
	elif cmd == "Sli_5":
		look["mask"] = dlg_create2.get_level("Sli_5")
	elif cmd == "Sli_2":
		look["skin"] = dlg_create2.get_level("Sli_2")
	elif cmd == "Sli_3":
		look["hair"] = dlg_create2.get_level("Sli_3")
	elif cmd in ["Sli_4", "Sli_6", "Sli_7"]:
		look["hair_color"] = ((dlg_create2.get_level("Sli_4") + COLOR_LOW) << 16) | ((dlg_create2.get_level("Sli_6") + COLOR_LOW) << 8) \
			| (dlg_create2.get_level("Sli_7") + COLOR_LOW)
		for i in range(1, 55):
			dlg_create2.check_item("Rdo_C%d" % i, false)
	else:
		return
	_style_to_controls()
	_show_preview(race, gender, cls, look)

# --- Phase 3: Name (DlgCreateNameAndBirth) ---
func _on_create3_command(cmd: String) -> void:
	if _on_phase_command(cmd):
		return
	if cmd == "IDOK":
		create()


# ====================================================
# HILFEN
# ====================================================
func class_name_of(c: int) -> String:
	return aui.text(STF_CLASS + c)

# Anzahl aufeinanderfolgender, nicht leerer Texte ab einer Nummer (wie FillFace / FillHair)
func _count(first: int) -> int:
	var n = 0
	while aui.text(first + n) != "":
		n += 1
	return n

func _show_preview(r: int, g: int, c: int, appearance: Dictionary) -> void:
	var err = preview.show_char(r, g, c, appearance)
	if err != "":
		push_warning("Vorschau: " + err)

func preview_data(key: String, fallback):
	if preview.model == null:
		return fallback
	return preview.model.data.get(key, fallback)

static func _rgb_int(rgb: Array) -> int:
	return (int(rgb[0]) << 16) | (int(rgb[1]) << 8) | int(rgb[2])
