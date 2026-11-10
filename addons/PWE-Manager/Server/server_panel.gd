@tool
extends EditorDock

# ====================================================
# Leiste "SERVER" unten im Editor (neben ECM-GFX-MAP und XML):
#  - Starten: Godot-FW-Server als eigener Prozess ohne Fenster auf dem Port
#    (Spiel res://game/main.tscn mit --server, siehe game/server/server.gd)
#  - Stoppen: legt user://server/stop an, der Server beendet sich sauber (sonst nach 3 s hart)
#  - Test-Client: öffnet ein Client-Fenster (Spiel ohne --server: Anmelde-Fenster)
#  - Bot-Test: Test-Bot ohne Fenster (game/tests/bot.gd) gegen den laufenden Server; seine
#    Zeilen erscheinen mit "Bot:" im Log (user://server/bot.log)
#  - Alle Tests: game/tests/run_all.gd ohne Fenster (eigene Server und Datenbanken unter
#    user://test_server, Ports 29100 - 29130, stört den Server hier nicht; gut 15 min); Fortschritt
#    mit "Test:" im Log (user://test_server/alle/lauf.log), Tabelle in bericht.txt daneben
#  - Spawns in offene Map: trägt die Spawns der Map (Server/maps.json) in die offene Map-Szene
#    ein (Knoten "Spawns", ersetzt einen vorhandenen, mit Rückgängig)
# Log: user://server/server.log, laufend nachgelesen; Spieler und Last (Takt-Dauer): user://server/status.json.
# Ein Server, der beim Öffnen des Editors noch läuft, wird übernommen; beim Schließen des
# Editors wird er beendet.
# ====================================================

const SpawnBuilder = preload("spawn_builder.gd")
const Files = preload("../Data/angelica_files.gd")
const LOG_FILE = "user://server/server.log"
const STATUS_FILE = "user://server/status.json"
const STOP_FILE = "user://server/stop"
const EDITOR_HEARTBEAT_FILE = "user://server/editor_heartbeat"
const GENERATOR_LOG = "user://server/pw_json_generator.log"
const BOT_LOG = "user://server/bot.log"
const RUN_ALL = "res://game/tests/run_all.gd"
const RUN_LOG = "user://test_server/alle/lauf.log"
const GAME_MAIN = "res://game/main.tscn"
const DEFAULT_PORT = 29000
const TICK = 0.25
const STOP_WAIT_MS = 3000
const MAX_LOG_CHARS = 200000

var _pid = -1
var _adopted = false # _pid stammt aus status.json (Server lief schon, kein Kindprozess dieses Editors)
var _adopted_probe_at = 0
var _adopted_probe_alive = false
var _stop_at = 0 # Zeitpunkt (ms) für hartes Beenden nach "Stoppen"
var _heartbeat_at = 0
var _log_pos = {LOG_FILE: 0, BOT_LOG: 0, RUN_LOG: 0}
var _bot_pid = -1
var _tests_pid = -1
var _generator_pid = -1
var _load_text = ""
var _status_text = ""
var _clients = 0

var _port: SpinBox
var _start_btn: Button
var _stop_btn: Button
var _client_btn: Button
var _bot_btn: Button
var _tests_btn: Button
var _spawn_btn: Button
var _pw_import_btn: Button
var _profile: OptionButton
var _state: Label
var _log: TextEdit
var _players: ItemList


func _init() -> void:
	title = "СЕРВЕР"
	layout_key = "FW-Server"
	icon_name = &"MultiplayerSpawner"
	default_slot = DOCK_SLOT_BOTTOM
	custom_minimum_size = Vector2(0, 200)

	var box = VBoxContainer.new()
	add_child(box)
	var bar = HBoxContainer.new()
	box.add_child(bar)
	var port_label = Label.new()
	port_label.text = "Порт:"
	bar.add_child(port_label)
	_port = SpinBox.new()
	_port.min_value = 1024
	_port.max_value = 65535
	_port.value = DEFAULT_PORT
	_port.tooltip_text = "UDP-порт игрового сервера (ENet)"
	bar.add_child(_port)
	_profile = OptionButton.new()
	_profile.add_item("FW")
	_profile.add_item("PW 155")
	_profile.tooltip_text = "Профиль данных сервера; шаблоны PW изолированы от FW"
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://addons/PWE-Manager/Server/PW155")):
		_profile.select(1)
	bar.add_child(_profile)
	_start_btn = _button(bar, "Запустить", "Запустить сервер отдельным процессом без окна", start_server)
	_stop_btn = _button(bar, "Остановить", "Корректно завершить сервер", stop_server)
	_client_btn = _button(bar, "Запустить клиент", "Открыть игровой клиент для подключения к серверу", start_client)
	_bot_btn = _button(bar, "Тест бота", "Проверить версию, регистрацию, вход и блокировку на работающем сервере", start_bot)
	_tests_btn = _button(bar, "Все тесты", "Последовательно запустить тесты без окон: NPC, бот, вход, персонажи, мир, перезапуск, повторное подключение и нагрузка; около 15 минут", start_all_tests)
	_spawn_btn = _button(bar, "Спавны на открытую карту", "Добавить спавны сервера в открытую сцену карты (узел «Spawns»)", add_spawns_to_open_map)
	_pw_import_btn = _button(bar, "Создать JSON PW", "Сформировать стартовые роли, класс и предметы из выбранного сервера PW", generate_pw_templates)
	_state = Label.new()
	_state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_state.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_state.clip_text = true
	_state.mouse_filter = Control.MOUSE_FILTER_PASS
	bar.add_child(_state)

	var split = HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(split)
	_log = TextEdit.new()
	_log.editable = false
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log.placeholder_text = "Журнал сервера"
	split.add_child(_log)
	var right = VBoxContainer.new()
	right.custom_minimum_size.x = 200
	split.add_child(right)
	var players_label = Label.new()
	players_label.text = "Игроки онлайн"
	right.add_child(players_label)
	_players = ItemList.new()
	_players.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_players)

	var timer = Timer.new()
	timer.wait_time = TICK
	timer.autostart = true
	timer.timeout.connect(_tick)
	add_child(timer)

func _ready() -> void:
	var editor_theme = EditorInterface.get_editor_theme()
	if not editor_theme.has_icon(icon_name, &"EditorIcons"):
		icon_name = &"Node"
	_log.add_theme_font_override("font", editor_theme.get_font(&"output_source", &"EditorFonts"))
	# Noch laufenden Server übernehmen
	var st = _read_status()
	_adopted = true
	if st.get("running", false) and _alive(int(st.get("pid", -1))):
		_pid = int(st["pid"])
		_port.value = int(st.get("port", DEFAULT_PORT))
	else:
		_adopted = false
	_update_buttons()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_running():
		stop_server()

func _button(bar: HBoxContainer, text: String, tip: String, action: Callable) -> Button:
	var b = Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(action)
	bar.add_child(b)
	return b


# ====================================================
# SERVER / CLIENT
# ====================================================
func is_running() -> bool:
	return _alive(_pid)

# Läuft der Server-Prozess? Übernommene Prozesse werden plattformgerecht geprüft, damit alte Statusdateien keinen Start dauerhaft blockieren.
func _alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if not _adopted:
		return OS.is_process_running(pid)
	if DirAccess.dir_exists_absolute("/proc"):
		return DirAccess.dir_exists_absolute("/proc/%d" % pid)
	if _adopted_probe_at > 0 and Time.get_ticks_msec() - _adopted_probe_at < 1000:
		return _adopted_probe_alive
	_adopted_probe_at = Time.get_ticks_msec()
	if OS.get_name() == "Windows":
		var output = []
		var result = OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"], output, true)
		_adopted_probe_alive = result == 0 and not output.is_empty() and str(output[0]).contains("\"%d\"" % pid)
		return _adopted_probe_alive
	var status = _read_status()
	return int(status.get("pid", -1)) == pid and status.get("running", false) and Time.get_unix_time_from_system() - float(status.get("heartbeat", 0.0)) <= 3.0

func start_server() -> int:
	if is_running():
		return _pid
	DirAccess.make_dir_recursive_absolute(LOG_FILE.get_base_dir())
	DirAccess.remove_absolute(STOP_FILE)
	if not _game_ready():
		return -1
	var f = FileAccess.open(LOG_FILE, FileAccess.WRITE) # Log leeren, die Leiste zeigt nur den neuen Lauf
	f = null
	_log_pos[LOG_FILE] = 0
	_log.text = ""
	_players.clear()
	_adopted = false
	_write_editor_heartbeat()
	var server_args = ["--server", "--port=%d" % int(_port.value), "--parent-pid=%d" % OS.get_process_id()]
	if _profile.selected == 1:
		server_args.append("--data-profile=PW155")
	_pid = _run_game(["--headless"], server_args)
	_stop_at = 0
	if _pid <= 0:
		_append("Не удалось запустить сервер.\n")
	else:
		_append("Запускается сервер (процесс %d). Журнал: %s\n" % [_pid, ProjectSettings.globalize_path(LOG_FILE)])
	_update_buttons()
	return _pid

func stop_server() -> void:
	if not is_running():
		return
	var f = FileAccess.open(STOP_FILE, FileAccess.WRITE)
	if f != null:
		f.store_string("stop")
	_stop_at = Time.get_ticks_msec() + STOP_WAIT_MS
	_state.text = "Сервер завершает работу..."

func start_client() -> int:
	if not _game_ready():
		return -1
	_clients += 1
	return _run_game([], ["--host=127.0.0.1", "--port=%d" % int(_port.value), "--account=Tester%d" % _clients])

func start_bot() -> int:
	if not _game_ready() or (_bot_pid > 0 and OS.is_process_running(_bot_pid)):
		return -1
	DirAccess.make_dir_recursive_absolute(BOT_LOG.get_base_dir())
	var f = FileAccess.open(BOT_LOG, FileAccess.WRITE)
	f = null
	_log_pos[BOT_LOG] = 0
	_bot_pid = _run_game(["--headless"], ["--bot", "--host=127.0.0.1", "--port=%d" % int(_port.value), "--log=" + BOT_LOG])
	return _bot_pid

func start_all_tests() -> int:
	if not ResourceLoader.exists(RUN_ALL) or (_tests_pid > 0 and OS.is_process_running(_tests_pid)):
		return -1
	DirAccess.make_dir_recursive_absolute(RUN_LOG.get_base_dir())
	var f = FileAccess.open(RUN_LOG, FileAccess.WRITE)
	f = null
	_log_pos[RUN_LOG] = 0
	_tests_pid = OS.create_process(OS.get_executable_path(), PackedStringArray(["--headless", "--path",
		ProjectSettings.globalize_path("res://"), "-s", RUN_ALL]))
	_update_buttons()
	return _tests_pid

func generate_pw_templates() -> void:
	if _generator_pid > 0 and OS.is_process_running(_generator_pid):
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GENERATOR_LOG.get_base_dir()))
	var log_file = FileAccess.open(GENERATOR_LOG, FileAccess.WRITE)
	if log_file == null:
		_append("Не удалось создать журнал генератора PW JSON.\n")
		return
	log_file.close()
	var args = PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--log-file", ProjectSettings.globalize_path(GENERATOR_LOG), "--script", "res://addons/PWE-Manager/tools/server_data/pw_playable_import.gd"])
	_generator_pid = OS.create_process(OS.get_executable_path(), args)
	if _generator_pid <= 0:
		_generator_pid = -1
		_append("Не удалось запустить генератор PW JSON. Проверьте путь к Godot.\n")
		return
	_pw_import_btn.disabled = true
	_append("Создание PW JSON запущено. Редактор останется доступен; результат появится здесь.\n")

func _finish_template_generation() -> void:
	_generator_pid = -1
	_pw_import_btn.disabled = false
	var output_dir = "res://addons/PWE-Manager/Server/PW155/"
	var roles = JSON.parse_string(FileAccess.get_file_as_string(output_dir + "start_roles.json"))
	var items = JSON.parse_string(FileAccess.get_file_as_string(output_dir + "item_templates.json"))
	var log_text = FileAccess.get_file_as_string(GENERATOR_LOG)
	var role_count = roles.get("roles", []).size() if roles is Dictionary else 0
	var item_count = items.get("items", {}).size() if items is Dictionary else 0
	if not log_text.contains("PW 155 готов") or role_count == 0 or item_count == 0:
		_append("PW JSON не созданы. Проверьте журнал %s и наличие elements.data и gamed/ptemplate.conf.\n" % ProjectSettings.globalize_path(GENERATOR_LOG))
		return
	_append("Готово: стартовых шаблонов — %d, предметов — %d. Файлы в Server/PW155/. Перезапустите сервер и импортируйте карту world.\n" % [role_count, item_count])

# Spiel (res://game/main.tscn) als eigenen Prozess: Godot-Optionen, dann Spiel-Optionen nach "--"
func _run_game(godot_args: Array, game_args: Array) -> int:
	var args = PackedStringArray(godot_args + ["--path", ProjectSettings.globalize_path("res://"), GAME_MAIN, "--"] + game_args)
	return OS.create_process(OS.get_executable_path(), args)

func _game_ready() -> bool:
	if ResourceLoader.exists(GAME_MAIN):
		return true
	_append("Не найдена игра: %s (скопируйте папку game/ в проект)\n" % GAME_MAIN)
	return false

func _tick() -> void:
	if Time.get_ticks_msec() - _heartbeat_at >= 1000:
		_write_editor_heartbeat()
	if _generator_pid > 0 and not OS.is_process_running(_generator_pid):
		_finish_template_generation()
	_read_log(LOG_FILE, "")
	_read_log(BOT_LOG, "Bot: ")
	_read_log(RUN_LOG, "Test: ")
	# Statusdatei jedes Mal lesen (klein; der Änderungszeitpunkt hat nur Sekunden-Auflösung)
	var text = FileAccess.get_file_as_string(STATUS_FILE) if FileAccess.file_exists(STATUS_FILE) else ""
	if text != _status_text:
		_status_text = text
		var d = JSON.parse_string(text) if text != "" else null
		_show_status(d if d is Dictionary else {})
	if _pid > 0 and not _alive(_pid):
		_read_log(LOG_FILE, "")
		_append("--- Процесс сервера завершён ---\n")
		_pid = -1
		_adopted = false
		_stop_at = 0
		_players.clear()
	elif _stop_at > 0 and Time.get_ticks_msec() > _stop_at and is_running():
		var kill_result = OS.kill(_pid)
		_append("--- Процесс сервера принудительно остановлен ---\n" if kill_result == OK else "Не удалось принудительно остановить сервер: %s\n" % error_string(kill_result))
		_stop_at = 0
	_update_buttons()

func _write_editor_heartbeat() -> void:
	var file = FileAccess.open(EDITOR_HEARTBEAT_FILE, FileAccess.WRITE)
	if file != null:
		file.store_string("%d|%.3f" % [OS.get_process_id(), Time.get_unix_time_from_system()])
		file.close()
		_heartbeat_at = Time.get_ticks_msec()

# Neue ganze Zeilen einer Log-Datei anhängen (prefix vor jede Zeile)
func _read_log(path: String, prefix: String) -> void:
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var n = f.get_length()
	if n < _log_pos[path]: # neu angelegt
		_log_pos[path] = 0
		if prefix == "":
			_log.text = ""
	if n == _log_pos[path]:
		return
	f.seek(_log_pos[path])
	var chunk = f.get_buffer(n - _log_pos[path])
	var last = chunk.rfind(10)
	if last < 0:
		return
	_log_pos[path] += last + 1
	var text = chunk.slice(0, last + 1).get_string_from_utf8()
	if prefix != "":
		var lines = text.split("\n", false)
		text = ""
		for line in lines:
			text += prefix + line + "\n"
	_append(text)

func _append(text: String) -> void:
	var t = _log.text + text
	if t.length() > MAX_LOG_CHARS:
		t = t.substr(t.length() - MAX_LOG_CHARS)
	_log.text = t
	_log.scroll_vertical = _log.get_line_count()

func _read_status() -> Dictionary:
	if not FileAccess.file_exists(STATUS_FILE):
		return {}
	var text = FileAccess.get_file_as_string(STATUS_FILE)
	if text.strip_edges() == "":
		return {}
	var d = JSON.parse_string(text)
	return d if d is Dictionary else {}

func _show_status(st: Dictionary) -> void:
	_players.clear()
	var l: Dictionary = st.get("load", {})
	_load_text = (", средний тик %.1f мс" % float(l["tick_avg_ms"])) if st.get("running", false) and int(l.get("in_world", 0)) > 0 else ""
	if not st.get("running", false):
		return
	for p in st.get("players", []):
		var i = _players.add_item("%s" % p.get("name", "?"))
		_players.set_item_tooltip(i, "Подключение %d, %s, с %s" % [int(p.get("peer", 0)), p.get("address", "?"), p.get("since", "?")])

func _update_buttons() -> void:
	var running = is_running()
	_start_btn.disabled = running
	_stop_btn.disabled = not running
	_bot_btn.disabled = not running or (_bot_pid > 0 and OS.is_process_running(_bot_pid))
	_tests_btn.disabled = _tests_pid > 0 and OS.is_process_running(_tests_pid)
	_port.editable = not running
	_profile.disabled = running
	if _stop_at == 0:
		_state.text = ("Работает на порту %d (процесс %d), игроков: %d%s" % [int(_port.value), _pid, _players.item_count, _load_text]) if running else "Остановлен"


# ====================================================
# SPAWNS
# ====================================================
# Spawns in die offene Map-Szene (Wurzel = Map-Name, z.B. s1); vorhandene "Spawns" ersetzt
func add_spawns_to_open_map() -> int:
	var root = EditorInterface.get_edited_scene_root()
	if not root is Node3D:
		_state.text = "Не открыта сцена карты"
		return 0
	var map_name = String(root.name)
	if SpawnBuilder.sources(map_name).is_empty():
		_state.text = "Нет данных о точках появления для " + map_name
		return 0
	var data_root = str(EditorInterface.get_editor_settings().get_project_metadata("ecm_gfx_panel", "root", "res://Stock-PWE-Client"))
	var builder = SpawnBuilder.new()
	var node = builder.build_node(map_name, Files.new(data_root))
	for w in builder.warnings:
		print("SERVER: ", w)
	if node == null:
		_state.text = "Не удалось прочитать спавны карты %s" % map_name
		return 0
	var old = root.get_node_or_null(SpawnBuilder.NODE_NAME)
	var ur = EditorInterface.get_editor_undo_redo()
	ur.create_action("Добавить спавны (%s)" % map_name, UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(self, "_swap_spawns", root, old, node)
	ur.add_undo_method(self, "_swap_spawns", root, node, old)
	ur.add_do_reference(node)
	if old != null:
		ur.add_undo_reference(old)
	ur.commit_action()
	var n = SpawnBuilder.count_markers(node)
	var src = node.get_meta("source", {})
	_state.text = "Маркеров спавна: %d; карта %s (папка сервера %s)" % [n, map_name, src.get("folder", "?")]
	return n

func _swap_spawns(root: Node, remove: Node, add: Node) -> void:
	if remove != null and remove.get_parent() == root:
		root.remove_child(remove)
	if add != null and add.get_parent() == null:
		root.add_child(add)
		SpawnBuilder.set_owner_recursive(add, root)
