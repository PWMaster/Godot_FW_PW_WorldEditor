extends RefCounted

# ====================================================
# Eigener Server für Tests (restart_test, reconnect_test, load_test, run_all): startet
# res://game/main.tscn --server als Prozess ohne Fenster mit eigenem Ordner (--dir) und Port, so
# stört er einen Server der Leiste SERVER nicht.
#   var srv = TestServer.new("user://test_server/neustart", 29110)
#   srv.fresh()             Ordner leeren (neue Datenbank)
#   await srv.start(tree)   -> true, sobald der Server "Bereit" meldet
#   await srv.stop(tree)    sauber über die Stopp-Datei (Spieler bekommen server_closing) -> true
#   await srv.kill(tree)    hart (Absturz nachstellen)
#   srv.status()            status.json als Dictionary, srv.log_text() das Log
# Die Ausgabe des Servers geht in die des Tests (run_all sucht darin nach Skriptfehlern).
# ====================================================

const GAME_MAIN = "res://game/main.tscn"
const READY_TEXT = "Bereit, warte auf Spieler"
const START_TIMEOUT = 90.0
const STOP_TIMEOUT = 20.0

var dir: String
var port: int
var extra: Array # weitere Server-Optionen, z.B. ["--maps=s9"]
var pid = -1


func _init(p_dir: String, p_port: int, p_extra: Array = []) -> void:
	dir = p_dir.trim_suffix("/")
	port = p_port
	extra = p_extra

func fresh() -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))

func start(tree: SceneTree) -> bool:
	if running():
		return true
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.remove_absolute(dir.path_join("server.log")) # "Bereit" des letzten Laufs nicht mitlesen
	var args = ["--headless", "--path", ProjectSettings.globalize_path("res://"), GAME_MAIN, "--", "--server",
		"--port=%d" % port, "--dir=" + dir] + extra
	pid = OS.create_process(OS.get_executable_path(), PackedStringArray(args))
	if pid <= 0:
		return false
	var end = Time.get_ticks_msec() + int(START_TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < end:
		if not running():
			return false
		if log_text().contains(READY_TEXT):
			return true
		await tree.create_timer(0.2).timeout
	return false

func stop(tree: SceneTree) -> bool:
	if not running():
		return true
	var f = FileAccess.open(dir.path_join("stop"), FileAccess.WRITE)
	if f != null:
		f.store_string("stop")
		f.close()
	var end = Time.get_ticks_msec() + int(STOP_TIMEOUT * 1000.0)
	while running():
		if Time.get_ticks_msec() > end:
			await kill(tree)
			return false
		await tree.create_timer(0.1).timeout
	return true

# OS.kill wartet selbst auf das Ende; danach nicht mehr nach dem Prozess fragen (Godot meldet sonst
# "does not exist or is not a child")
func kill(tree: SceneTree) -> void:
	if running():
		OS.kill(pid)
	pid = -1
	await tree.process_frame

func running() -> bool:
	return pid > 0 and OS.is_process_running(pid)

func status() -> Dictionary:
	var path = dir.path_join("status.json")
	var d = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	return d if d is Dictionary else {}

func log_text() -> String:
	var path = dir.path_join("server.log")
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
