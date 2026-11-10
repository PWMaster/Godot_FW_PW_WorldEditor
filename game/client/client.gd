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
const LocalMap = preload("local_map.gd")
const LANGUAGES = [["Русский", "Deu"]]

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
var _login_ui: Control
var _local_view: SubViewportContainer
var _local_overlay: Control
var _local_world
var _local_dialog: ConfirmationDialog
var _map_path: LineEdit
var _data_root: LineEdit
var _race: SpinBox
var _gender: SpinBox
var _profession: SpinBox
var _characters_ui: Control
var _characters_list: ItemList
var _characters_status: Label
var _create_character_dialog: ConfirmationDialog
var _create_character_name: LineEdit
var _create_character_race: OptionButton
var _create_character_class: OptionButton
var _create_character_gender: OptionButton
var _available_roles: Array = []
var _online_view: SubViewportContainer
var _online_overlay: Control
var _online_world
var _online_active = false
var _online_send_elapsed = 0.0
var _busy = false


func _ready() -> void:
	session = get_parent().get_node("Session")
	settings = Settings.new("client")
	get_window().title = "Клиент Godot-FW"
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_build()
	_host.text = settings.value("host")
	_port.value = settings.value("port")
	_account.text = settings.value("account")
	_language.select(0)
	for i in LANGUAGES.size():
		if LANGUAGES[i][1] == settings.value("language"):
			_language.select(i)
	session.dtls = settings.value("dtls")
	session.dtls_cert = settings.value("dtls_cert")
	session.state_changed.connect(_on_state)
	session.kicked.connect(_on_kicked)
	session.disconnected.connect(_on_disconnected)
	_show("Войдите или создайте учётную запись.")
	_update()
	
	if _account.text != "":
		_password.grab_focus.call_deferred()

func _on_login() -> void:
	if not _begin("Выполняется вход..."):
		return
	var r = await session.login(_account.text.strip_edges(), _password.text)
	_end(r, "Вход выполнен: %s (%s, протокол %d)." % [session.account, session.server_info.get("server", "?"), Proto.VERSION])
	if r["code"] == Proto.Code.OK:
		_login_ui.hide()
		_show_character_menu()

func _on_register() -> void:
	if not _begin("Создаётся учётная запись..."):
		return
	var r = await session.register(_account.text.strip_edges(), _password.text)
	_end(r, "Учётная запись %s создана. Теперь войдите." % _account.text.strip_edges())

func _on_logout() -> void:
	if not _begin("Выполняется выход..."):
		return
	var r = await session.logout()
	_end(r, "Вы вышли из учётной записи.")
	if r["code"] == Proto.Code.OK:
		if _characters_ui != null:
			_characters_ui.hide()
		_login_ui.show()

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
	if _online_active and _s == Session.State.OFFLINE:
		_close_online_world(false)
		_login_ui.show()
		if _characters_ui != null:
			_characters_ui.hide()

func _on_kicked(code: int) -> void:
	_show(Proto.text(code))
	if _characters_status != null:
		_characters_status.text = Proto.text(code)

func _on_disconnected(code: int) -> void:
	if _characters_status != null:
		_characters_status.text = Proto.text(code)

func _show_character_menu() -> void:
	if _characters_ui == null:
		var center = CenterContainer.new()
		center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var panel = PanelContainer.new()
		center.add_child(panel)
		var margin = MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 16)
		margin.add_theme_constant_override("margin_right", 16)
		margin.add_theme_constant_override("margin_top", 16)
		margin.add_theme_constant_override("margin_bottom", 16)
		panel.add_child(margin)
		var box = VBoxContainer.new()
		box.custom_minimum_size = Vector2(440, 0)
		margin.add_child(box)
		var title = Label.new()
		title.text = "ОНЛАЙН · выбор персонажа"
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(title)
		_characters_list = ItemList.new()
		_characters_list.custom_minimum_size.y = 220
		_characters_list.select_mode = ItemList.SELECT_SINGLE
		box.add_child(_characters_list)
		var actions = HBoxContainer.new()
		actions.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_child(actions)
		_button(actions, "Обновить", _refresh_characters)
		_button(actions, "Создать персонажа", _open_create_character)
		_button(actions, "Войти в мир", _enter_selected_character)
		_button(actions, "Выйти", _on_logout)
		_characters_status = Label.new()
		_characters_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(_characters_status)
		add_child(center)
		_characters_ui = center
	_characters_ui.show()
	await _refresh_characters()

func _refresh_characters() -> void:
	if session.state != Session.State.LOGGED_IN:
		return
	_characters_status.text = "Загружаю список персонажей..."
	var response = await session.list_chars()
	if response["code"] != Proto.Code.OK:
		_characters_status.text = Proto.text(response["code"])
		return
	_characters_list.clear()
	for character in response["data"].get("chars", []):
		var label = "%s · уровень %d · %s (%s)" % [character.get("name", "?"), int(character.get("level", 1)), _class_name(int(character.get("class", 0))), _race_name(int(character.get("race", 0)))]
		var index = _characters_list.add_item(label)
		_characters_list.set_item_metadata(index, character)
	_available_roles = response["data"].get("classes", [])
	if _create_character_dialog != null:
		_refresh_create_character_options()
	if _characters_list.item_count > 0:
		_characters_list.select(0)
	_characters_status.text = "Персонажей: %d. Доступные комбинации расы, класса и пола: %d." % [_characters_list.item_count, _available_roles.size()]

func _open_create_character() -> void:
	if _create_character_dialog != null:
		_create_character_dialog.popup_centered()
		return
	_create_character_dialog = ConfirmationDialog.new()
	_create_character_dialog.title = "Создать PW-персонажа"
	_create_character_dialog.ok_button_text = "Создать"
	_create_character_dialog.confirmed.connect(_create_character)
	var fields = GridContainer.new()
	fields.columns = 2
	fields.custom_minimum_size.x = 400
	_create_character_dialog.add_child(fields)
	_create_character_name = _local_field(fields, "Имя (2–12 символов):", LineEdit.new()) as LineEdit
	_create_character_name.max_length = 12
	_create_character_race = _local_field(fields, "Раса:", OptionButton.new()) as OptionButton
	_create_character_race.item_selected.connect(func(_index: int): _refresh_create_character_options(false))
	_create_character_class = _local_field(fields, "Класс:", OptionButton.new()) as OptionButton
	_create_character_class.item_selected.connect(func(_index: int): _refresh_create_character_options())
	_create_character_gender = _local_field(fields, "Пол:", OptionButton.new()) as OptionButton
	_create_character_gender.item_selected.connect(func(_index: int): _refresh_create_character_options(false))
	add_child(_create_character_dialog)
	_refresh_create_character_options()
	_create_character_dialog.popup_centered()

func _create_character() -> void:
	if _available_roles.is_empty() or _create_character_race.get_item_count() == 0 or _create_character_class.get_item_count() == 0:
		_characters_status.text = "Сервер не сообщил доступные стартовые комбинации. Создайте PW JSON и перезапустите сервер."
		return
	var race = _create_character_race.get_selected_id()
	var class_id = _create_character_class.get_selected_id()
	var gender = _create_character_gender.get_selected_id()
	var appearance = {"face": 0, "mask": 0, "hair": 0, "skin": 0, "hair_color": 0xEAF8FD}
	var response = await session.create_char(_create_character_name.text.strip_edges(), race, class_id, gender, appearance)
	if response["code"] != Proto.Code.OK:
		_characters_status.text = Proto.text(response["code"])
		return
	_characters_status.text = "Персонаж %s создан." % _create_character_name.text.strip_edges()
	await _refresh_characters()

func _refresh_create_character_options(preserve_class: bool = true) -> void:
	if _create_character_race == null or _create_character_class == null or _create_character_gender == null:
		return
	var previous_race = _create_character_race.get_selected_id()
	var previous_gender = _create_character_gender.get_selected_id()
	var previous_class = _create_character_class.get_selected_id()
	var races = {}
	for role in _available_roles:
		var parts = str(role).split("_")
		if parts.size() == 3:
			races[int(parts[0])] = true
	_create_character_race.clear()
	for race_id in races.keys():
		_create_character_race.add_item(_race_name(int(race_id)), int(race_id))
	if _create_character_race.get_item_count() == 0:
		_create_character_class.clear()
		_create_character_gender.clear()
		return
	_create_character_race.select(maxi(0, _create_character_race.get_item_index(previous_race)))
	var race = _create_character_race.get_selected_id()
	var genders = {}
	for role in _available_roles:
		var parts = str(role).split("_")
		if parts.size() == 3 and int(parts[0]) == race:
			genders[int(parts[2])] = true
	_create_character_gender.clear()
	if genders.is_empty():
		_create_character_class.clear()
		return
	for gender_id in genders.keys():
		_create_character_gender.add_item("Мужской" if int(gender_id) == 0 else "Женский", int(gender_id))
	var selected_gender = previous_gender if genders.has(previous_gender) else int(genders.keys()[0])
	_create_character_gender.select(_create_character_gender.get_item_index(selected_gender))
	var classes = {}
	for role in _available_roles:
		var parts = str(role).split("_")
		if parts.size() == 3 and int(parts[0]) == race and int(parts[2]) == selected_gender:
			classes[int(parts[1])] = true
	_create_character_class.clear()
	for class_id in classes.keys():
		_create_character_class.add_item(_class_name(int(class_id)), int(class_id))
	var selected_class = previous_class if preserve_class and classes.has(previous_class) else int(classes.keys()[0]) if not classes.is_empty() else -1
	if selected_class >= 0:
		_create_character_class.select(_create_character_class.get_item_index(selected_class))

func _race_name(race: int) -> String:
	var names = ["", "Люди", "Эльфы", "Зверолюди", "Моряки", "Земные", "Ночные"]
	return names[clampi(race, 0, 6)]

func _class_name(class_id: int) -> String:
	var names = ["", "Воин", "Маг", "Психик", "Веномант", "Оборотень", "Убийца", "Лучник", "Жрец", "Страж", "Мистик", "Ночной клинок", "Буревестник"]
	return names[class_id] if class_id > 0 and class_id < names.size() else "Класс %d" % class_id

func _enter_selected_character() -> void:
	var selected = _characters_list.get_selected_items()
	if selected.is_empty():
		_characters_status.text = "Сначала выберите персонажа или создайте его."
		return
	var character: Dictionary = _characters_list.get_item_metadata(selected[0])
	_characters_status.text = "Вхожу в мир..."
	var response = await session.enter_char(int(character["id"]))
	if response["code"] != Proto.Code.OK:
		_characters_status.text = Proto.text(response["code"])
		return
	await _start_online_world(response["data"])

func _start_online_world(info: Dictionary) -> void:
	var map_name = str(info.get("map", "world"))
	var maps_root = str(settings.value("maps_root"))
	var scene_path = maps_root.path_join(map_name).path_join(map_name + ".tscn")
	if not ResourceLoader.exists(scene_path):
		_characters_status.text = "Карта %s не импортирована. Выберите Карты в ECM-GFX-MAP и импортируйте её." % map_name
		await session.world_leave()
		return
	_characters_ui.hide()
	_online_view = SubViewportContainer.new()
	_online_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_online_view.stretch = true
	add_child(_online_view)
	var viewport = SubViewport.new()
	viewport.size = Vector2i(1152, 648)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_online_view.add_child(viewport)
	_online_world = LocalMap.new()
	viewport.add_child(_online_world)
	var position: Array = info.get("pos", [0.0, 4.0, 0.0])
	var character: Dictionary = info.get("char", {})
	var err = await _online_world.load_world(scene_path, str(settings.value("data_root")), int(character.get("race", 1)), int(character.get("gender", 0)), int(character.get("class", 1)), position, float(info.get("dir", 0.0)))
	if err != "":
		await session.world_leave()
		_close_online_world(false)
		_characters_ui.show()
		_characters_status.text = err
		return
	var ready = await session.world_ready()
	if ready["code"] != Proto.Code.OK:
		await session.world_leave()
		_close_online_world(false)
		_characters_ui.show()
		_characters_status.text = Proto.text(ready["code"])
		return
	_online_active = true
	_online_send_elapsed = 0.0
	_online_world.player.input_enabled = true
	_online_overlay = VBoxContainer.new()
	_online_overlay.position = Vector2(16, 16)
	add_child(_online_overlay)
	var hint = Label.new()
	hint.text = "%s · ОНЛАЙН · WASD — движение · Shift — бег · F — свободная камера/персонаж · правая кнопка мыши — осмотр · Esc — курсор" % character.get("name", "Персонаж")
	hint.add_theme_color_override("font_color", Color.WHITE)
	_online_overlay.add_child(hint)
	var leave_button = Button.new()
	leave_button.text = "Вернуться к персонажам"
	leave_button.pressed.connect(_leave_online_world)
	_online_overlay.add_child(leave_button)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _physics_process(delta: float) -> void:
	if not _online_active or _online_world == null or _online_world.player == null:
		return
	_online_send_elapsed += delta
	if _online_send_elapsed < 0.05:
		return
	_online_send_elapsed = 0.0
	session.send_move(_online_world.player.global_position, _online_world.player.direction(), _online_world.player.state)

func _leave_online_world() -> void:
	_online_active = false
	if session.state == Session.State.LOGGED_IN:
		await session.world_leave()
	_close_online_world(false)
	_characters_ui.show()
	await _refresh_characters()

func _close_online_world(notify_server: bool) -> void:
	_online_active = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if notify_server and session.state == Session.State.LOGGED_IN:
		session.world_leave()
	if _online_view != null:
		_online_view.queue_free()
	if _online_overlay != null:
		_online_overlay.queue_free()
	_online_view = null
	_online_overlay = null
	_online_world = null

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
	_login_ui = center
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
	title.text = "Godot-FW — вход в игру"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var grid = GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	_host = _field(grid, "Сервер:", LineEdit.new())
	_port = _field(grid, "Порт:", SpinBox.new())
	_port.min_value = 1
	_port.max_value = 65535
	_language = _field(grid, "Язык:", OptionButton.new())
	for l in LANGUAGES:
		_language.add_item(l[0])
	_account = _field(grid, "Учётная запись:", LineEdit.new())
	_account.max_length = Proto.ACCOUNT_MAX
	_password = _field(grid, "Пароль:", LineEdit.new())
	_password.secret = true
	_password.max_length = Proto.PASSWORD_MAX
	_password.text_submitted.connect(func(_t): _on_login())
	var bar = HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(bar)
	_login_btn = _button(bar, "Войти", _on_login)
	_register_btn = _button(bar, "Создать аккаунт", _on_register)
	_logout_btn = _button(bar, "Выйти", _on_logout)
	_button(box, "Локально загрузить карту", _open_local_map)
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

func _button(bar: Container, text: String, action: Callable) -> Button:
	var b = Button.new()
	b.text = text
	b.pressed.connect(action)
	bar.add_child(b)
	return b

func _open_local_map() -> void:
	if _local_dialog != null:
		_local_dialog.popup_centered()
		return
	_local_dialog = ConfirmationDialog.new()
	_local_dialog.title = "Локальная карта и персонаж"
	_local_dialog.ok_button_text = "Загрузить карту"
	_local_dialog.confirmed.connect(_start_local_map)
	var fields = GridContainer.new()
	fields.columns = 2
	fields.custom_minimum_size.x = 560
	_local_dialog.add_child(fields)
	_map_path = _local_field(fields, "Сцена карты:", LineEdit.new()) as LineEdit
	_data_root = _local_field(fields, "Данные клиента:", LineEdit.new()) as LineEdit
	_data_root.text = str(settings.value("data_root"))
	var import_profile = JSON.parse_string(FileAccess.get_file_as_string("res://addons/PWE-Manager/Server/pw_server_import.json")) if FileAccess.file_exists("res://addons/PWE-Manager/Server/pw_server_import.json") else {}
	if import_profile is Dictionary and DirAccess.dir_exists_absolute(str(import_profile.get("client_root", ""))):
		_data_root.text = str(import_profile["client_root"])
	_race = _local_field(fields, "Раса (1–6):", SpinBox.new()) as SpinBox
	_race.min_value = 1
	_race.max_value = 6
	_race.value = 1
	_gender = _local_field(fields, "Пол (0/1):", SpinBox.new()) as SpinBox
	_gender.max_value = 1
	_profession = _local_field(fields, "Класс (1–12):", SpinBox.new()) as SpinBox
	_profession.min_value = 1
	_profession.max_value = 12
	_profession.value = 1
	_map_path.text = _first_imported_map()
	add_child(_local_dialog)
	_local_dialog.popup_centered()

func _local_field(grid: GridContainer, caption: String, control: Control) -> Control:
	var label = Label.new()
	label.text = caption
	grid.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)
	return control

func _first_imported_map() -> String:
	var root_path = str(settings.value("maps_root"))
	var root_absolute = ProjectSettings.globalize_path(root_path) if root_path.begins_with("res://") else root_path
	for folder in DirAccess.get_directories_at(root_absolute):
		var path = root_path.path_join(folder).path_join(folder + ".tscn")
		if ResourceLoader.exists(path):
			return path
	return root_path.path_join("world/world.tscn")

func _start_local_map() -> void:
	var data_path = _data_root.text.strip_edges()
	var scene_path = _map_path.text.strip_edges()
	if data_path == "" or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(data_path) if data_path.begins_with("res://") else data_path):
		_show("Папка игровых данных клиента не найдена.")
		return
	if not ResourceLoader.exists(scene_path):
		_show("Сцена карты не найдена. Сначала импортируйте карту через ECM-GFX-MAP.")
		return
	_login_ui.hide()
	_local_dialog.hide()
	_local_view = SubViewportContainer.new()
	_local_view.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_local_view.stretch = true
	add_child(_local_view)
	var viewport = SubViewport.new()
	viewport.size = Vector2i(1152, 648)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_local_view.add_child(viewport)
	_local_world = LocalMap.new()
	viewport.add_child(_local_world)
	_local_overlay = VBoxContainer.new()
	_local_overlay.position = Vector2(16, 16)
	_local_overlay.add_theme_constant_override("separation", 8)
	add_child(_local_overlay)
	var loading = Label.new()
	loading.text = "Загрузка персонажа и начальных областей карты…"
	loading.add_theme_color_override("font_color", Color.WHITE)
	_hint_shadow(loading)
	_local_overlay.add_child(loading)
	_local_world.loading_progress.connect(func(message: String): loading.text = message)
	await get_tree().process_frame
	var err: String = await _local_world.load_world(scene_path, data_path, int(_race.value), int(_gender.value), int(_profession.value))
	if err != "":
		_close_local_map()
		_show(err)
		return
	loading.text = "ЛОКАЛЬНАЯ КАРТА · WASD — движение · Shift — ускорение · F — камера/персонаж · свободная камера: WASD, Space/Q, Shift · ПКМ — осмотр · Esc — курсор"
	var back = Button.new()
	back.text = "Вернуться ко входу"
	back.pressed.connect(_close_local_map)
	_local_overlay.add_child(back)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _hint_shadow(label: Label) -> void:
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)

func _close_local_map() -> void:
	if _local_view == null:
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_local_view.queue_free()
	if _local_overlay != null:
		_local_overlay.queue_free()
	_local_view = null
	_local_overlay = null
	_local_world = null
	_login_ui.show()
