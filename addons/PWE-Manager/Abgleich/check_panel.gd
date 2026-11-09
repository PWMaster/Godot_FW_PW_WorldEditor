@tool
extends EditorDock

# ====================================================
# Leiste "ABGLEICH" unten im Editor: passen Server- und Client-Daten zusammen?
# Client- und Server-Ordner (Standard res://Stock-PWE-Client / res://Stock-PWE-Server, in den
# Projekt-Metadaten "abgleich" gemerkt), "Prüfen" startet data_check.gd in einem Thread.
# Oben der Match in % (grün ab 90 %, gelb ab 60 %, sonst rot) und das Urteil, darunter je
# Bereich der Anteil (Quests, Maps, Vorlagen, NPC-Höhen) und der ganze Bericht.
# "Bericht speichern" schreibt ihn nach res://Abgleich-Bericht.txt.
# ====================================================

const Check = preload("data_check.gd")
const META_SECTION = "abgleich"
const DEFAULT_CLIENT = "res://Stock-PWE-Client"
const DEFAULT_SERVER = "res://Stock-PWE-Server"
const REPORT_FILE = "res://Abgleich-Bericht.txt"
const GOOD = 0.9
const FAIR = 0.6

var _client: LineEdit
var _server: LineEdit
var _run_btn: Button
var _save_btn: Button
var _progress: ProgressBar
var _status: Label
var _match: Label
var _verdict: Label
var _parts: Label
var _report: TextEdit
var _thread: Thread
var _result = {}


func _init() -> void:
	title = "ABGLEICH"
	layout_key = "PWE-Abgleich"
	icon_name = &"Search"
	default_slot = DOCK_SLOT_BOTTOM
	custom_minimum_size = Vector2(0, 200)

	var box = VBoxContainer.new()
	add_child(box)
	var bar = HBoxContainer.new()
	box.add_child(bar)
	_client = _field(bar, "Client:", "Ordner des Spiel-Clients (mit seinen .pck)")
	_server = _field(bar, "Server:", "Ordner der Server-Daten (darin gamed/gs.conf)")
	_run_btn = Button.new()
	_run_btn.text = "Prüfen"
	_run_btn.tooltip_text = "Versionen, Quests, Maps, Vorlagen und NPC-Höhen vergleichen"
	_run_btn.pressed.connect(start_check)
	bar.add_child(_run_btn)
	_save_btn = Button.new()
	_save_btn.text = "Bericht speichern"
	_save_btn.tooltip_text = "Bericht nach " + REPORT_FILE + " schreiben"
	_save_btn.disabled = true
	_save_btn.pressed.connect(save_report)
	bar.add_child(_save_btn)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size.x = 120
	_progress.max_value = 1.0
	_progress.step = 0.01
	_progress.show_percentage = false
	bar.add_child(_progress)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	bar.add_child(_status)

	var head = HBoxContainer.new()
	box.add_child(head)
	_match = Label.new()
	_match.text = "-"
	_match.custom_minimum_size.x = 140
	head.add_child(_match)
	var texts = VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(texts)
	_verdict = Label.new()
	_verdict.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	texts.add_child(_verdict)
	_parts = Label.new()
	texts.add_child(_parts)

	_report = TextEdit.new()
	_report.editable = false
	_report.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_report.placeholder_text = "Bericht des Abgleichs (\"Prüfen\")"
	box.add_child(_report)

func _ready() -> void:
	var editor_theme = EditorInterface.get_editor_theme()
	if not editor_theme.has_icon(icon_name, &"EditorIcons"):
		icon_name = &"Node"
	_report.add_theme_font_override("font", editor_theme.get_font(&"output_source", &"EditorFonts"))
	_match.add_theme_font_size_override("font_size", 28)
	var settings = EditorInterface.get_editor_settings()
	_client.text = str(settings.get_project_metadata(META_SECTION, "client", DEFAULT_CLIENT))
	_server.text = str(settings.get_project_metadata(META_SECTION, "server", DEFAULT_SERVER))

func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null

func _field(bar: HBoxContainer, label: String, tip: String) -> LineEdit:
	var l = Label.new()
	l.text = label
	bar.add_child(l)
	var e = LineEdit.new()
	e.custom_minimum_size.x = 220
	e.tooltip_text = tip
	bar.add_child(e)
	return e

func is_running() -> bool:
	return _thread != null


# ====================================================
# PRÜFEN (Thread)
# ====================================================
func start_check() -> void:
	if _thread != null:
		return
	var settings = EditorInterface.get_editor_settings()
	settings.set_project_metadata(META_SECTION, "client", _client.text.strip_edges())
	settings.set_project_metadata(META_SECTION, "server", _server.text.strip_edges())
	_run_btn.disabled = true
	_save_btn.disabled = true
	_progress.value = 0.0
	_status.text = "Prüfe ..."
	_thread = Thread.new()
	_thread.start(_worker.bind(_client.text.strip_edges(), _server.text.strip_edges()))

func _worker(client: String, server: String) -> void:
	var r = Check.new().run(client, server, func(text, f): _on_progress.call_deferred(text, f))
	_on_done.call_deferred(r)

func _on_progress(text: String, f: float) -> void:
	_progress.value = f
	_status.text = text

func _on_done(r: Dictionary) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_result = r
	_run_btn.disabled = false
	_save_btn.disabled = false
	show_result(r)

func show_result(r: Dictionary) -> void:
	var score = float(r.get("score", -1.0))
	_match.text = ("%.1f %%" % (score * 100.0)).replace(".", ",") if score >= 0.0 else "-"
	_match.add_theme_color_override("font_color", Color(0.35, 0.85, 0.4) if score >= GOOD else (Color(0.95, 0.8, 0.3) if score >= FAIR else Color(0.95, 0.35, 0.3)))
	_verdict.text = str(r.get("verdict", ""))
	var parts = []
	for k in [["quests", "Quests"], ["maps", "Maps"], ["templates", "Vorlagen"], ["heights", "NPC-Höhen"]]:
		var s = float(r.get(k[0], {}).get("score", -1.0))
		parts.append("%s %s" % [k[1], ("%.1f %%" % (s * 100.0)).replace(".", ",") if s >= 0.0 else "-"])
	_parts.text = "   ".join(parts)
	_report.text = Check.report_text(r)
	_status.text = "Fertig in %.1f s" % float(r.get("seconds", 0.0)) if score >= 0.0 else "Abgleich nicht möglich"
	_progress.value = 1.0

func save_report() -> void:
	if _result.is_empty():
		return
	var f = FileAccess.open(REPORT_FILE, FileAccess.WRITE)
	if f == null:
		_status.text = REPORT_FILE + " nicht schreibbar"
		return
	f.store_string(Check.report_text(_result) + "\n")
	f.close()
	EditorInterface.get_resource_filesystem().update_file(REPORT_FILE)
	_status.text = "Gespeichert: " + REPORT_FILE
