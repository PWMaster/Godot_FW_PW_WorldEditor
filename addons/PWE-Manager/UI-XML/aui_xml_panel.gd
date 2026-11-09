@tool
extends EditorDock

# ====================================================
# Leiste "XML" unten im Editor: Dialoge der Oberfläche (interfaces\*.xml) einer Sprache.
# Sprache: Deutsch (Ordner Deu), Englisch (Eng), Französisch (Franz) unter den Spieldaten
# (angelica_ui.gd). Liste: alle Dialog-Dateien des Ordners, Spalte daneben die Dialog-Liste
# (.dcf), die sie lädt; Auswahl nach Liste und Suche im Dateinamen.
# Ein Klick auf eine Datei baut den Dialog als Szene unter res://ECM_Import/<Sprache>/interfaces/
# (angelica_ui_builder.gd) und öffnet sie als eigenen Tab in der 2D-Ansicht.
# ====================================================

const UI = preload("angelica_ui.gd")
const UIBuilder = preload("angelica_ui_builder.gd")
const DEFAULT_ROOT = "res://Stock-PWE-Client"
const META_SECTION = "aui_xml_panel"
const ROOT_SECTION = "ecm_gfx_panel" # Spieldaten-Ordner wie in der Leiste ECM-GFX-MAP
const LANGUAGES = [["Deutsch", "Deu"], ["Englisch", "Eng"], ["Französisch", "Franz"]]
const LIST_ALL = "Alle"
const LIST_NONE = "Ohne Liste"

var _root = DEFAULT_ROOT
var _ui = null # angelica_ui.gd der gewählten Sprache
var _files = PackedStringArray() # Dialog-Dateien der Sprache, sortiert
var _busy = false

var _language: OptionButton
var _list_filter: OptionButton
var _search: LineEdit
var _status: Label
var _tree: Tree
var _search_timer: Timer
var _file_icon: Texture2D = null
var _dim_color = Color(0.6, 0.6, 0.6)


func _init() -> void:
	title = "XML"
	layout_key = "AUI-XML"
	icon_name = &"Control"
	default_slot = DOCK_SLOT_BOTTOM
	custom_minimum_size = Vector2(0, 200)

	var box = VBoxContainer.new()
	add_child(box)
	var bar = HBoxContainer.new()
	box.add_child(bar)

	var lang_label = Label.new()
	lang_label.text = "Sprache:"
	bar.add_child(lang_label)
	_language = OptionButton.new()
	for i in LANGUAGES.size():
		_language.add_item(LANGUAGES[i][0], i)
	_language.tooltip_text = "Sprachordner der Spieldaten (Deu, Eng, Franz): Oberfläche und Namen der Spawns"
	_language.item_selected.connect(_on_language_selected)
	bar.add_child(_language)

	_list_filter = OptionButton.new()
	_list_filter.add_item(LIST_ALL)
	for lay in UI.LAYOUTS:
		_list_filter.add_item(lay)
	_list_filter.add_item(LIST_NONE)
	_list_filter.tooltip_text = "Nur Dialoge einer Dialog-Liste (.dcf): 1gameui / 2gameui = Oberflächen-Stile 1 / 2"
	_list_filter.item_selected.connect(func(_i): _rebuild_tree())
	bar.add_child(_list_filter)

	_search = LineEdit.new()
	_search.placeholder_text = "XML suchen (Dateiname) ..."
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t): _search_timer.start())
	bar.add_child(_search)

	_status = Label.new()
	_status.custom_minimum_size.x = 260
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.clip_text = true
	_status.mouse_filter = Control.MOUSE_FILTER_PASS
	bar.add_child(_status)

	_tree = Tree.new()
	_tree.hide_root = true
	_tree.columns = 2
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 90)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_mouse_selected.connect(func(_pos, button): if button == MOUSE_BUTTON_LEFT: open_selected())
	_tree.item_activated.connect(open_selected)
	box.add_child(_tree)

	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.2
	_search_timer.timeout.connect(_rebuild_tree)
	add_child(_search_timer)

func _ready() -> void:
	var editor_theme = EditorInterface.get_editor_theme()
	_file_icon = editor_theme.get_icon(&"Control", &"EditorIcons")
	_dim_color = editor_theme.get_color(&"font_disabled_color", &"Button")
	var settings = EditorInterface.get_editor_settings()
	_root = str(settings.get_project_metadata(ROOT_SECTION, "root", DEFAULT_ROOT))
	var lang = str(settings.get_project_metadata(META_SECTION, "language", "Deu"))
	var index = 0
	for i in LANGUAGES.size():
		if LANGUAGES[i][1] == lang:
			index = i
	_language.select(index)
	set_language(LANGUAGES[index][1])

func _on_language_selected(index: int) -> void:
	var lang = LANGUAGES[index][1]
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, "language", lang)
	set_language(lang)

# Sprache wählen: Ordner lesen, Liste neu aufbauen
func set_language(lang: String) -> void:
	for i in LANGUAGES.size():
		if LANGUAGES[i][1] == lang and _language.selected != i:
			_language.select(i)
	_ui = UI.new(_root, lang)
	_files = PackedStringArray()
	var dir = _ui.interfaces_dir()
	if dir != "" and _language_present(lang):
		for f in _ui.files.list_dir(dir)["files"]:
			if f.get_extension().to_lower() == "xml":
				_files.append(f)
	_files.sort()
	_rebuild_tree()

# Der Sprachordner selbst (ohne Rückfall auf resources/interfaces)
func _language_present(lang: String) -> bool:
	return _ui.files.resolve(lang + "/interfaces") != "" or _ui.files.resolve("resources/" + lang + "/interfaces") != ""

func current_language() -> String:
	return LANGUAGES[_language.selected][1]


# ====================================================
# LISTE
# ====================================================
func _rebuild_tree() -> void:
	_tree.clear()
	var root_item = _tree.create_item()
	var lang = current_language()
	if _files.is_empty():
		_set_status("Ordner " + lang + "/interfaces fehlt")
		var hint = _tree.create_item(root_item)
		hint.set_text(0, "Den Sprachordner \"%s\" (mit interfaces, surfaces) unter %s ablegen." % [lang, _root])
		return
	var query = _search.text.strip_edges().to_lower()
	var wanted = _list_filter.get_item_text(_list_filter.selected)
	var shown = 0
	for f in _files:
		if query != "" and not f.to_lower().contains(query):
			continue
		var lay = _ui.layout_of(f)
		if wanted == LIST_NONE and lay != "" or wanted != LIST_ALL and wanted != LIST_NONE and lay != wanted:
			continue
		var item = _tree.create_item(root_item)
		item.set_text(0, f.get_basename())
		item.set_icon(0, _file_icon)
		item.set_text(1, lay)
		item.set_custom_color(1, _dim_color)
		var path = _ui.interfaces_dir().path_join(f)
		item.set_metadata(0, path)
		item.set_tooltip_text(0, path)
		shown += 1
	_set_status("%d von %d Dialogen (%s)" % [shown, _files.size(), _language.get_item_text(_language.selected)])

func selected_file() -> String:
	var item = _tree.get_selected()
	if item == null:
		return ""
	var path = item.get_metadata(0)
	return path if path is String else ""

func open_selected() -> void:
	var path = selected_file()
	if path != "":
		open_dialog(path)


# ====================================================
# ÖFFNEN
# ====================================================
# Dialog bauen, speichern und als Tab in der 2D-Ansicht öffnen (offen: neu laden)
func open_dialog(path: String) -> Dictionary:
	if _busy:
		return {"error": "beschäftigt"}
	_busy = true
	var fs = EditorInterface.get_resource_filesystem()
	if fs.is_scanning():
		_set_status("Warte auf den Datei-Scan des Editors ...")
		while fs.is_scanning():
			await get_tree().process_frame
	_set_status(path.get_file() + " wird gebaut ...")
	await get_tree().process_frame
	var builder = UIBuilder.new(_ui)
	var res = builder.import_dialog(path)
	if res.has("error"):
		_set_status("Fehler: " + res["error"])
		printerr("XML ", path, ": ", res["error"])
		_busy = false
		return res
	for w in res["warnings"]:
		print("XML ", path.get_file(), ": ", w)
	await get_tree().process_frame
	for f in res["written"]:
		fs.update_file(f)
	if res["scene"] in EditorInterface.get_open_scenes():
		EditorInterface.reload_scene_from_path(res["scene"])
		await get_tree().process_frame
		await get_tree().process_frame
	EditorInterface.open_scene_from_path(res["scene"])
	EditorInterface.set_main_screen_editor("2D")
	var n = res["warnings"].size()
	_set_status("Geöffnet: " + res["scene"] + ((" (%d Hinweise in der Ausgabe)" % n) if n > 0 else ""))
	_busy = false
	return res

func _set_status(text: String) -> void:
	_status.text = text
	_status.tooltip_text = text
