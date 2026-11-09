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
var _stop_at = 0 # Zeitpunkt (ms) für hartes Beenden nach "Stoppen"
var _log_pos = {LOG_FILE: 0, BOT_LOG: 0, RUN_LOG: 0}
var _bot_pid = -1
var _tests_pid = -1
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
var _state: Label
var _log: TextEdit
var _players: ItemList


func _init() -> void:
	title = "SERVER"
	layout_key = "FW-Server"
	icon_name = &"MultiplayerSpawner"
	default_slot = DOCK_SLOT_BOTTOM
	custom_minimum_size = Vector2(0, 200)

	var box = VBoxContainer.new()
	add_child(box)
	var bar = HBoxContainer.new()
	box.add_child(bar)
	var port_label = Label.new()
	port_label.text = "Port:"
	bar.add_child(port_label)
	_port = SpinBox.new()
	_port.min_value = 1024
	_port.max_value = 65535
	_port.value = DEFAULT_PORT
	_port.tooltip_text = "UDP-Port des Servers (ENet)"
	bar.add_child(_port)
	_start_btn = _button(bar, "Starten", "Server als eigenen Prozess ohne Fenster starten", start_server)
	_stop_btn = _button(bar, "Stoppen", "Server sauber beenden", stop_server)
	_client_btn = _button(bar, "Test-Client", "Ein Client-Fenster öffnen, das sich mit dem Server verbindet", start_client)
	_bot_btn = _button(bar, "Bot-Test", "Test-Bot gegen den laufenden Server: Version, Konten anlegen, Anmelden, Sperre", start_bot)
	_tests_btn = _button(bar, "Alle Tests", "Alle Tests nacheinander ohne Fenster (game/tests/run_all.gd): NPC, Bot, Login, Figuren, Welt, Neustart, Wiederverbinden, Last - mit eigenen Servern auf Port 29100 - 29130, gut 15 min", start_all_tests)
	_spawn_btn = _button(bar, "Spawns in offene Map", "Spawns des Spielservers in die offene Map-Szene eintragen (Knoten \"Spawns\")", add_spawns_to_open_map)
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
	_log.placeholder_text = "Server-Log"
	split.add_child(_log)
	var right = VBoxContainer.new()
	right.custom_minimum_size.x = 200
	split.add_child(right)
	var players_label = Label.new()
	players_label.text = "Spieler online"
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
		OS.kill(_pid)

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

# Läuft der Server-Prozess? OS.is_process_running geht nur für eigene Kindprozesse (sonst meldet Godot
# "does not exist or is not a child"); einen übernommenen fragt /proc/<pid> (Linux), ohne /proc gilt status.json
func _alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if not _adopted:
		return OS.is_process_running(pid)
	return DirAccess.dir_exists_absolute("/proc/%d" % pid) if DirAccess.dir_exists_absolute("/proc") else true

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
	_pid = _run_game(["--headless"], ["--server", "--port=%d" % int(_port.value)])
	_stop_at = 0
	if _pid <= 0:
		_append("Server konnte nicht gestartet werden.\n")
	_update_buttons()
	return _pid

func stop_server() -> void:
	if not is_running():
		return
	var f = FileAccess.open(STOP_FILE, FileAccess.WRITE)
	if f != null:
		f.store_string("stop")
	_stop_at = Time.get_ticks_msec() + STOP_WAIT_MS
	_state.text = "Server wird beendet ..."

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

# Spiel (res://game/main.tscn) als eigenen Prozess: Godot-Optionen, dann Spiel-Optionen nach "--"
func _run_game(godot_args: Array, game_args: Array) -> int:
	var args = PackedStringArray(godot_args + ["--path", ProjectSettings.globalize_path("res://"), GAME_MAIN, "--"] + game_args)
	return OS.create_process(OS.get_executable_path(), args)

func _game_ready() -> bool:
	if ResourceLoader.exists(GAME_MAIN):
		return true
	_append("Spiel fehlt: %s (Ordner game/ ins Projekt kopieren)\n" % GAME_MAIN)
	return false

func _tick() -> void:
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
		_append("--- Server-Prozess beendet ---\n")
		_pid = -1
		_adopted = false
		_stop_at = 0
		_players.clear()
	elif _stop_at > 0 and Time.get_ticks_msec() > _stop_at and is_running():
		OS.kill(_pid)
		_append("--- Server hart beendet ---\n")
		_stop_at = 0
	_update_buttons()

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
	var d = JSON.parse_string(FileAccess.get_file_as_string(STATUS_FILE))
	return d if d is Dictionary else {}

func _show_status(st: Dictionary) -> void:
	_players.clear()
	var l: Dictionary = st.get("load", {})
	_load_text = (", Takt Ø %.1f ms" % float(l["tick_avg_ms"])) if st.get("running", false) and int(l.get("in_world", 0)) > 0 else ""
	if not st.get("running", false):
		return
	for p in st.get("players", []):
		var i = _players.add_item("%s" % p.get("name", "?"))
		_players.set_item_tooltip(i, "Peer %d, %s, seit %s" % [int(p.get("peer", 0)), p.get("address", "?"), p.get("since", "?")])

func _update_buttons() -> void:
	var running = is_running()
	_start_btn.disabled = running
	_stop_btn.disabled = not running
	_bot_btn.disabled = not running or (_bot_pid > 0 and OS.is_process_running(_bot_pid))
	_tests_btn.disabled = _tests_pid > 0 and OS.is_process_running(_tests_pid)
	_port.editable = not running
	if _stop_at == 0:
		_state.text = ("Läuft auf Port %d (Prozess %d), %d Spieler%s" % [int(_port.value), _pid, _players.item_count, _load_text]) if running else "Gestoppt"


# ====================================================
# SPAWNS
# ====================================================
# Spawns in die offene Map-Szene (Wurzel = Map-Name, z.B. s1); vorhandene "Spawns" ersetzt
func add_spawns_to_open_map() -> int:
	var root = EditorInterface.get_edited_scene_root()
	if not root is Node3D:
		_state.text = "Keine Map-Szene offen"
		return 0
	var map_name = String(root.name)
	if SpawnBuilder.sources(map_name).is_empty():
		_state.text = "Keine Spawn-Daten für " + map_name
		return 0
	var data_root = str(EditorInterface.get_editor_settings().get_project_metadata("ecm_gfx_panel", "root", "res://Stock-PWE-Client"))
	var builder = SpawnBuilder.new()
	var node = builder.build_node(map_name, Files.new(data_root))
	for w in builder.warnings:
		print("SERVER: ", w)
	if node == null:
		_state.text = "Spawns für %s nicht lesbar" % map_name
		return 0
	var old = root.get_node_or_null(SpawnBuilder.NODE_NAME)
	var ur = EditorInterface.get_editor_undo_redo()
	ur.create_action("Spawns eintragen (%s)" % map_name, UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(self, "_swap_spawns", root, old, node)
	ur.add_undo_method(self, "_swap_spawns", root, node, old)
	ur.add_do_reference(node)
	if old != null:
		ur.add_undo_reference(old)
	ur.commit_action()
	var n = SpawnBuilder.count_markers(node)
	var src = node.get_meta("source", {})
	_state.text = "%d Spawn-Marker in %s eingetragen (Server-Ordner %s)" % [n, map_name, src.get("folder", "?")]
	return n

func _swap_spawns(root: Node, remove: Node, add: Node) -> void:
	if remove != null and remove.get_parent() == root:
		root.remove_child(remove)
	if add != null and add.get_parent() == null:
		root.add_child(add)
		SpawnBuilder.set_owner_recursive(add, root)
