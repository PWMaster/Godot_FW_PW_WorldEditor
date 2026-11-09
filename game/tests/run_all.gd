extends SceneTree

# ====================================================
# Alle Tests nacheinander (Fahrplan 11.1), je Test ein eigener Godot-Prozess:
#   godot --headless --path <Projekt> -s res://game/tests/run_all.gd -- [--full] [--only=bot,welt]
#         [--port=29100]
# Standard (gut 15 min, alles ohne Fenster): NPC-Test, Fertigkeiten-Daten, Statuseffekte; eigener Server (user://test_server/alle,
# frische Datenbank) mit Bot, Login-, Figuren- und Welt-Test; Server neu starten, Bot
# --expect-existing (Konten und Figuren bleiben); Neustart-, Wiederverbinden- und Lasttest (je mit
# eigenem Server). --full: Login-, Figuren-, Welt- und Wiederverbinden-Test zusätzlich mit Vulkan
# und GL (Fenster) sowie auf Englisch und Französisch - die ganze Test-Routine, gut 1 h.
# --only: nur diese Tests (npc, fertigkeiten, statuseffekte, bot, login, figuren, welt, neustart, wiederverbinden, last).
# Jede Ausgabe (auch die der Server) wird nach "SCRIPT ERROR", "SHADER ERROR" und "ERROR:"
# durchsucht; ein Fund zählt als Fehler, auch wenn der Test selbst OK meldet. Welt- und
# Wiederverbinden-Test brauchen die importierte s9 (sonst übersprungen).
# Ausgaben: user://test_server/alle/<Test>.log, Fortschritt in lauf.log (liest die Leiste SERVER),
# Tabelle am Ende in bericht.txt. user://settings.cfg (Login-Test merkt sich Konten) wird danach
# wiederhergestellt.
# Ende: "ALLE TESTS OK" (Exit 0) oder "ALLE TESTS FEHLER" (Exit 1).
# ====================================================

const Settings = preload("../common/settings.gd")
const DIR = "user://test_server/alle"
const SERVER_DIR = "user://test_server/alle/server"
const DEFAULT_PORT = 29100
const GAME_MAIN = "res://game/main.tscn"
const MAP_S9 = "res://ECM_Import/maps/s9/s9.tscn"
const SETTINGS_FILE = "user://settings.cfg"
const VARIANTS = {"ohne Fenster": ["--headless"], "Vulkan": ["--rendering-driver", "vulkan"],
	"GL": ["--rendering-method", "gl_compatibility"]}
const ERROR_MARKS = ["SCRIPT ERROR", "SHADER ERROR", "ERROR:"]
# Test -> [Skript bzw. "bot", Erfolgszeile, Zeitlimit s, braucht den gemeinsamen Server, braucht s9]
const TESTS = {
	"npc": ["res://game/tests/npc_test.gd", "NPC-TEST OK", 300, false, false],
	"fertigkeiten": ["res://game/tests/skill_data_test.gd", "FERTIGKEITEN-TEST OK", 300, false, false],
	"statuseffekte": ["res://game/tests/buff_test.gd", "STATUSEFFEKTE-TEST OK", 300, false, false],
	"bot": ["bot", "BOT OK", 500, true, false],
	"login": ["res://game/tests/login_test.gd", "LOGIN-TEST OK", 300, true, false],
	"figuren": ["res://game/tests/char_test.gd", "FIGUREN-TEST OK", 300, true, false],
	"welt": ["res://game/tests/world_test.gd", "WELT-TEST OK", 1200, true, true],
	"neustart": ["res://game/tests/restart_test.gd", "NEUSTART-TEST OK", 400, false, false],
	"wiederverbinden": ["res://game/tests/reconnect_test.gd", "WIEDERVERBINDEN-TEST OK", 400, false, true],
	"last": ["res://game/tests/load_test.gd", "LAST-TEST OK", 500, false, false],
}

var port = DEFAULT_PORT
var full = false
var only: Array = []
var results: Array = [] # {name, variant, ok, checks, seconds, errors, note}
var _progress: FileAccess
var _server = {} # gemeinsamer Server: Prozess (_start)
var _settings_backup = null


class Proc:
	extends RefCounted
	var pid = -1
	var stdio: FileAccess
	var stderr: FileAccess
	var out = ""
	var log_file: FileAccess

	func _init(args: PackedStringArray, log_path: String) -> void:
		var info = OS.execute_with_pipe(OS.get_executable_path(), args, false)
		if info.is_empty():
			return
		pid = info["pid"]
		stdio = info["stdio"]
		stderr = info["stderr"]
		log_file = FileAccess.open(log_path, FileAccess.WRITE)

	# Neue Ausgabe lesen (blockiert nicht) -> läuft der Prozess noch?
	func pump() -> bool:
		var alive = pid > 0 and OS.is_process_running(pid)
		for pipe in [stdio, stderr]:
			if pipe == null:
				continue
			while true:
				var b = pipe.get_buffer(65536)
				if b.is_empty():
					break
				var t = b.get_string_from_utf8()
				out += t
				if log_file != null:
					log_file.store_string(t)
		if not alive and log_file != null:
			log_file.flush()
		return alive

	func exit_code() -> int:
		return OS.get_process_exit_code(pid) if pid > 0 else -1


func _initialize() -> void:
	var args = Settings.user_args()
	port = int(args.get("port", str(DEFAULT_PORT)))
	full = args.has("full")
	only = str(args.get("only", "")).split(",", false)
	DirAccess.make_dir_recursive_absolute(DIR)
	_progress = FileAccess.open(DIR.path_join("lauf.log"), FileAccess.WRITE)
	if FileAccess.file_exists(SETTINGS_FILE):
		_settings_backup = FileAccess.get_file_as_bytes(SETTINGS_FILE)
	_run.call_deferred()

func _run() -> void:
	var t0 = Time.get_ticks_msec()
	_say("Alle Tests (%s), Projekt %s" % ["voll" if full else "schnell", ProjectSettings.globalize_path("res://")])
	var langs = ["Deu", "Eng", "Franz"] if full else ["Deu"]
	var variants = VARIANTS.keys() if full else ["ohne Fenster"]
	var has_s9 = ResourceLoader.exists(MAP_S9)
	if not has_s9:
		_say("s9 ist nicht importiert (%s): Welt- und Wiederverbinden-Test werden übersprungen" % MAP_S9)
	await _test("npc", "ohne Fenster", [])
	await _test("fertigkeiten", "ohne Fenster", [])
	await _test("statuseffekte", "ohne Fenster", [])

	# gemeinsamer Server: Bot und die Client-Tests
	if _wanted_any(["bot", "login", "figuren", "welt"]):
		if await _start_server(true):
			await _test("bot", "ohne Fenster", [])
			for name in ["login", "figuren", "welt"]:
				if name == "welt" and not has_s9:
					_skip(name, "s9 nicht importiert")
					continue
				for v in variants:
					await _test(name, v, [])
				for lang in langs.slice(1):
					await _test(name, "ohne Fenster", ["--language=" + lang])
			await _stop_server("Server (Tests)")
			if _wanted("bot") and await _start_server(false):
				await _test("bot", "ohne Fenster", ["--expect-existing"], "nach Server-Neustart")
				await _stop_server("Server (Neustart)")

	await _test("neustart", "ohne Fenster", [])
	if has_s9:
		for v in variants:
			await _test("wiederverbinden", v, [])
		for lang in langs.slice(1):
			await _test("wiederverbinden", "ohne Fenster", ["--language=" + lang])
	else:
		_skip("wiederverbinden", "s9 nicht importiert")
	await _test("last", "ohne Fenster", [])

	if _settings_backup != null:
		var f = FileAccess.open(SETTINGS_FILE, FileAccess.WRITE)
		f.store_buffer(_settings_backup)
		f.close()
	var failed = results.filter(func(r): return not r["ok"] and r["note"] != "übersprungen")
	var report = _report((Time.get_ticks_msec() - t0) / 1000.0)
	var f2 = FileAccess.open(DIR.path_join("bericht.txt"), FileAccess.WRITE)
	f2.store_string(report)
	f2.close()
	_say(report)
	_say("ALLE TESTS OK" if failed.is_empty() else "ALLE TESTS FEHLER: %d von %d" % [failed.size(), results.size()])
	quit(0 if failed.is_empty() else 1)


# ====================================================
# TESTS
# ====================================================
func _test(name: String, variant: String, extra: Array, note: String = "") -> void:
	if not _wanted(name):
		return
	var t: Array = TESTS[name]
	var args: Array = VARIANTS[variant] + ["--path", ProjectSettings.globalize_path("res://")]
	var port_arg = []
	if t[3]:
		port_arg = ["--port=%d" % port]
	if t[0] == "bot":
		args += [GAME_MAIN, "--", "--bot"] + port_arg + extra
	else:
		args += ["-s", t[0], "--"] + port_arg + extra
	var lang = ""
	for a in extra:
		if str(a).begins_with("--language="):
			lang = str(a).get_slice("=", 1)
	var label = name + (" " + lang if lang != "" else "") + (" (%s)" % note if note != "" else "")
	var log_name = "%s_%s%s%s.log" % [name, variant.replace(" ", "_"), "_" + lang if lang != "" else "", "_neustart" if note != "" else ""]
	var t0 = Time.get_ticks_msec()
	var p = Proc.new(PackedStringArray(args), DIR.path_join(log_name))
	if p.pid <= 0:
		_result(name, variant, false, 0, 0.0, [], "nicht gestartet")
		return
	var limit = t0 + int(t[2]) * 1000
	while p.pump():
		if Time.get_ticks_msec() > limit:
			OS.kill(p.pid)
			p.pid = -1
			break
		if _server.has("proc"):
			_server["proc"].pump()
		await create_timer(0.1).timeout
	p.pump()
	var seconds = (Time.get_ticks_msec() - t0) / 1000.0
	var ok = p.out.contains(t[1]) and p.exit_code() == 0
	var checks = 0
	var m = RegEx.create_from_string("\\((\\d+) Prüfungen\\)").search(p.out)
	if m != null:
		checks = m.get_string(1).to_int()
	var timed_out = Time.get_ticks_msec() > limit
	_result(label, variant, ok, checks, seconds, _errors(p.out), "Zeitlimit" if timed_out else "")

func _skip(name: String, why: String) -> void:
	if _wanted(name):
		results.append({"name": name, "variant": "-", "ok": false, "checks": 0, "seconds": 0.0, "errors": [], "note": "übersprungen"})
		_say("%-28s übersprungen (%s)" % [name, why])

func _result(label: String, variant: String, ok: bool, checks: int, seconds: float, errors: Array, note: String) -> void:
	var r = {"name": label, "variant": variant, "ok": ok and errors.is_empty(), "checks": checks, "seconds": seconds,
		"errors": errors, "note": note}
	results.append(r)
	_say("%-28s %-13s %-7s %4d Prüfungen %6.0f s%s%s" % [label, variant, "OK" if r["ok"] else "FEHLER", checks, seconds,
		("  " + note) if note != "" else "", ("  Fehlerzeilen: " + str(errors.slice(0, 3))) if not errors.is_empty() else ""])

func _errors(text: String) -> Array:
	var out = []
	for line in text.split("\n"):
		for mark in ERROR_MARKS:
			if line.contains(mark):
				out.append(line.strip_edges().left(160))
				break
	return out

func _wanted(name: String) -> bool:
	return only.is_empty() or name in only

func _wanted_any(names: Array) -> bool:
	return names.any(func(n): return _wanted(n))


# ====================================================
# GEMEINSAMER SERVER
# ====================================================
func _start_server(fresh: bool) -> bool:
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)
	if fresh:
		for f in DirAccess.get_files_at(SERVER_DIR):
			DirAccess.remove_absolute(SERVER_DIR.path_join(f))
	DirAccess.remove_absolute(SERVER_DIR.path_join("server.log"))
	var p = Proc.new(PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), GAME_MAIN, "--",
		"--server", "--port=%d" % port, "--dir=" + SERVER_DIR]), DIR.path_join("server_%s.log" % ("frisch" if fresh else "neustart")))
	var end = Time.get_ticks_msec() + 90000
	while p.pump() and not p.out.contains("Bereit, warte auf Spieler") and Time.get_ticks_msec() < end:
		await create_timer(0.2).timeout
	if not p.out.contains("Bereit, warte auf Spieler"):
		_say("Server startet nicht (Port %d): %s" % [port, p.out.right(300)])
		if p.pid > 0 and OS.is_process_running(p.pid):
			OS.kill(p.pid)
		_result("Server", "ohne Fenster", false, 0, 0.0, _errors(p.out), "startet nicht")
		return false
	_server = {"proc": p, "t0": Time.get_ticks_msec()}
	return true

func _stop_server(label: String) -> void:
	if not _server.has("proc"):
		return
	var p: Proc = _server["proc"]
	var f = FileAccess.open(SERVER_DIR.path_join("stop"), FileAccess.WRITE)
	f.store_string("stop")
	f.close()
	var end = Time.get_ticks_msec() + 20000
	while p.pump() and Time.get_ticks_msec() < end:
		await create_timer(0.1).timeout
	var stopped = not p.pump()
	if not stopped:
		OS.kill(p.pid)
	_result(label, "ohne Fenster", stopped and p.out.contains("Server beendet"), 0, (Time.get_ticks_msec() - _server["t0"]) / 1000.0,
		_errors(p.out), "" if stopped else "musste hart beendet werden")
	_server = {}


# ====================================================
# AUSGABE
# ====================================================
func _report(seconds: float) -> String:
	var lines = ["", "ERGEBNIS (%s, %.0f min)" % [Time.get_datetime_string_from_system(false, true), seconds / 60.0],
		"%-28s %-13s %-7s %10s %8s" % ["Test", "Variante", "Ergebnis", "Prüfungen", "Dauer"]]
	for r in results:
		lines.append("%-28s %-13s %-7s %10d %7.0f s%s" % [r["name"], r["variant"], "übersp." if r["note"] == "übersprungen" else
			("OK" if r["ok"] else "FEHLER"), r["checks"], r["seconds"], ("  " + r["note"]) if not r["note"] in ["", "übersprungen"] else ""])
		for e in r["errors"].slice(0, 5):
			lines.append("    " + e)
	return "\n".join(lines)

func _say(text: String) -> void:
	print(text)
	if _progress != null:
		_progress.store_line(text)
		_progress.flush()
