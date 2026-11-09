@tool
extends EditorDock

# ====================================================
# Leiste "ECM-GFX-MAP" unten im Editor (neben Ausgabe, Debugger, Animation ...).
# Zeigt alle .ecm, .gfx und Maps (.trn2) der Spieldaten in ihren Ordnern. Die Spieldaten liegen im
# Projekt (Standard res://Stock-PWE-Client = Original-Client mit seinen .pck; eine .gdignore darin
# hält Godot vom Scannen ab), gelesen über angelica_files.gd / angelica_vfs.gd: die Pakete
# erscheinen als Ordner (resources/models.pck -> resources/models/ ...). Sie sind die einzige Quelle:
# auch Texturen, Unter-GFX und Modelle (.smd) der GFX kommen von dort (ecm_importer.gd).
# Das Einlesen (rund 200 000 Dateien) läuft im Hintergrund. Die Liste wird in
# res://.godot/editor/ecm_gfx_index3.txt zwischengespeichert, "Neu einlesen" erneuert sie.
# Suche: Teil von Name oder Ordnerpfad, Auswahl ECM / GFX / Maps. Ordner werden erst beim Aufklappen
# gefüllt. Doppelklick oder "Importieren" baut die Datei als Szene unter res://ECM_Import/ und
# öffnet sie; eine GFX läuft dann im Editor, steuerbar mit der Leiste GFX-Player. Eine Map wird
# vorerst als Terrain importiert (angelica_terrain.gd).
# ====================================================

const DEFAULT_ROOT = "res://Stock-PWE-Client"
const Files = preload("../Data/angelica_files.gd")
const CACHE_FILE = "ecm_gfx_index3.txt"
const META_SECTION = "ecm_gfx_panel"
const EXTENSIONS = ["ecm", "gfx", "trn2"]
const EXPAND_LIMIT = 300 # Suchtreffer bis zu dieser Anzahl werden ganz aufgeklappt
const PROGRESS_EVERY = 250 # Ordner zwischen zwei Fortschrittsmeldungen beim Einlesen
const TYPE_ALL = 0
const TYPE_ECM = 1
const TYPE_GFX = 2
const TYPE_MAP = 3

var _root = DEFAULT_ROOT
var _paths = PackedStringArray() # ECM-, GFX- und Map-Pfade relativ zu _root, sortiert
var _lower = PackedStringArray() # dieselben in Kleinbuchstaben für die Suche
var _scan_time = ""
var _thread: Thread = null
var _abort = false
var _folder_icon: Texture2D = null
var _ecm_icon: Texture2D = null
var _gfx_icon: Texture2D = null
var _map_icon: Texture2D = null
var _dim_color = Color(0.6, 0.6, 0.6)

var _root_edit: LineEdit
var _type: OptionButton
var _search: LineEdit
var _rescan_btn: Button
var _import_btn: Button
var _status: Label
var _tree: Tree
var _search_timer: Timer


func _init() -> void:
	title = "ECM-GFX-MAP"
	layout_key = "ECM-GFX" # alter Schlüssel: der Editor behält die Position der Leiste
	icon_name = &"Skeleton3D"
	default_slot = DOCK_SLOT_BOTTOM
	custom_minimum_size = Vector2(0, 200)

	var box = VBoxContainer.new()
	add_child(box)
	var bar = HBoxContainer.new()
	box.add_child(bar)

	var root_label = Label.new()
	root_label.text = "Spieldaten:"
	bar.add_child(root_label)
	_root_edit = LineEdit.new()
	_root_edit.custom_minimum_size.x = 220
	_root_edit.tooltip_text = "Ordner mit den entpackten Spieldaten (Enter liest ihn neu ein)"
	_root_edit.text_submitted.connect(_on_root_submitted)
	bar.add_child(_root_edit)

	_type = OptionButton.new()
	_type.add_item("Alle", TYPE_ALL)
	_type.add_item("ECM", TYPE_ECM)
	_type.add_item("GFX", TYPE_GFX)
	_type.add_item("Maps", TYPE_MAP)
	_type.tooltip_text = "Welche Dateien die Liste zeigt"
	_type.item_selected.connect(func(_i): _rebuild_tree())
	bar.add_child(_type)

	_search = LineEdit.new()
	_search.placeholder_text = "ECM / GFX / Map suchen (Name oder Ordner) ..."
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t): _search_timer.start())
	bar.add_child(_search)

	_rescan_btn = Button.new()
	_rescan_btn.text = "Neu einlesen"
	_rescan_btn.pressed.connect(start_scan)
	bar.add_child(_rescan_btn)

	_import_btn = Button.new()
	_import_btn.text = "Importieren"
	_import_btn.tooltip_text = "Gewählte ECM / GFX / Map als Szene unter res://ECM_Import/ bauen und öffnen"
	_import_btn.disabled = true
	_import_btn.pressed.connect(import_selected)
	bar.add_child(_import_btn)

	_status = Label.new()
	_status.custom_minimum_size.x = 260
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.clip_text = true
	_status.mouse_filter = Control.MOUSE_FILTER_PASS # Tooltip mit dem ganzen Text
	bar.add_child(_status)

	_tree = Tree.new()
	_tree.hide_root = true
	_tree.columns = 2
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 70)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(_on_item_activated)
	_tree.item_collapsed.connect(_on_item_collapsed)
	_tree.item_selected.connect(func(): _import_btn.disabled = selected_file() == "")
	box.add_child(_tree)

	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.2
	_search_timer.timeout.connect(_rebuild_tree)
	add_child(_search_timer)

func _ready() -> void:
	var editor_theme = EditorInterface.get_editor_theme()
	_folder_icon = editor_theme.get_icon(&"Folder", &"EditorIcons")
	_ecm_icon = editor_theme.get_icon(&"Skeleton3D", &"EditorIcons")
	_gfx_icon = editor_theme.get_icon(&"GPUParticles3D", &"EditorIcons")
	var map_icon = &"HeightMapShape3D" if editor_theme.has_icon(&"HeightMapShape3D", &"EditorIcons") else &"Mesh"
	_map_icon = editor_theme.get_icon(map_icon, &"EditorIcons")
	_dim_color = editor_theme.get_color(&"font_disabled_color", &"Button")
	_root = str(EditorInterface.get_editor_settings().get_project_metadata(META_SECTION, "root", DEFAULT_ROOT))
	_root_edit.text = _root
	if not _load_cache():
		start_scan()

# Plugin aus / Editor zu: laufendes Einlesen abbrechen. Nicht in _exit_tree: der Editor
# hängt die Leiste beim Verschieben in einen anderen Bereich nur um.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _thread != null:
		_abort = true
		_thread.wait_to_finish()
		_thread = null

func is_scanning() -> bool:
	return _thread != null


# ====================================================
# EINLESEN (Hintergrund-Thread)
# ====================================================
func start_scan() -> void:
	if _thread != null:
		return
	if not DirAccess.dir_exists_absolute(_root):
		_set_paths(PackedStringArray())
		_scan_time = ""
		_rebuild_tree()
		return
	_abort = false
	_rescan_btn.disabled = true
	_set_status("Lese ein ...")
	_thread = Thread.new()
	_thread.start(_scan_worker.bind(_root, Files.new(_root)))

func _scan_worker(root: String, files) -> void:
	var found = PackedStringArray()
	var stack = [""]
	var dirs = 0
	while not stack.is_empty() and not _abort:
		var rel: String = stack.pop_back()
		var l: Dictionary = files.list_dir(root if rel == "" else root.path_join(rel))
		dirs += 1
		for f in l["files"]:
			if f.get_extension().to_lower() in EXTENSIONS:
				found.append(f if rel == "" else rel + "/" + f)
		for sub in l["dirs"]:
			stack.append(sub if rel == "" else rel + "/" + sub)
		if dirs % PROGRESS_EVERY == 0:
			_on_scan_progress.call_deferred(dirs, found.size())
	_on_scan_finished.call_deferred(found, _abort)

func _on_scan_progress(dirs: int, count: int) -> void:
	if _thread != null:
		_set_status("Lese ein ... %s Ordner, %s ECM / GFX / Maps" % [_fmt(dirs), _fmt(count)])

func _on_scan_finished(found: PackedStringArray, aborted: bool) -> void:
	if _thread == null:
		return
	_thread.wait_to_finish()
	_thread = null
	_rescan_btn.disabled = false
	if aborted:
		return
	_scan_time = Time.get_datetime_string_from_system(false, true)
	_set_paths(found)
	_save_cache()
	_rebuild_tree()

func _set_paths(paths: PackedStringArray) -> void:
	paths.sort()
	_paths = paths
	_lower = PackedStringArray()
	_lower.resize(paths.size())
	for i in paths.size():
		_lower[i] = paths[i].to_lower()

func _on_root_submitted(text: String) -> void:
	_root = text.strip_edges().trim_suffix("/")
	_root_edit.text = _root
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, "root", _root)
	start_scan()


# ====================================================
# ZWISCHENSPEICHER
# ====================================================
func _cache_path() -> String:
	return EditorInterface.get_editor_paths().get_project_settings_dir().path_join(CACHE_FILE)

func _load_cache() -> bool:
	var f = FileAccess.open(_cache_path(), FileAccess.READ)
	if f == null or f.get_line() != "#root=" + _root:
		return false
	_scan_time = f.get_line().trim_prefix("#time=")
	var paths = PackedStringArray()
	while not f.eof_reached():
		var line = f.get_line()
		if line != "":
			paths.append(line)
	_set_paths(paths)
	_rebuild_tree()
	return true

func _save_cache() -> void:
	var f = FileAccess.open(_cache_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_line("#root=" + _root)
	f.store_line("#time=" + _scan_time)
	for p in _paths:
		f.store_line(p)


# ====================================================
# BAUM
# ====================================================
func _rebuild_tree() -> void:
	_tree.clear()
	_import_btn.disabled = true
	var root_item = _tree.create_item()
	if not DirAccess.dir_exists_absolute(_root):
		_set_status(_root + " fehlt")
		var hint = _tree.create_item(root_item)
		hint.set_text(0, "Den Spiel-Client (mit seinen .pck) als " + _root.get_file() + " ins Projekt kopieren, dann \"Neu einlesen\".")
		return
	var query = _search.text.strip_edges().to_lower()
	var type = _type.get_selected_id()
	var top = _new_folder()
	var counts = {"ecm": 0, "gfx": 0, "trn2": 0}
	var wanted = {TYPE_ECM: "ecm", TYPE_GFX: "gfx", TYPE_MAP: "trn2"}
	for i in _paths.size():
		var ext = _lower[i].get_extension()
		if type != TYPE_ALL and ext != wanted[type]:
			continue
		if query != "" and not _lower[i].contains(query):
			continue
		counts[ext] = counts.get(ext, 0) + 1
		var parts = _paths[i].split("/")
		var node = top
		for k in parts.size() - 1:
			var dirs: Dictionary = node["dirs"]
			if not dirs.has(parts[k]):
				dirs[parts[k]] = _new_folder()
			node = dirs[parts[k]]
			node["count"] += 1
		node["files"].append(parts[parts.size() - 1])
	var shown = counts["ecm"] + counts["gfx"] + counts["trn2"]
	_fill_folder(root_item, top, "", 0, query != "" and shown <= EXPAND_LIMIT)
	var what = "%s ECM, %s GFX, %s Maps" % [_fmt(counts["ecm"]), _fmt(counts["gfx"]), _fmt(counts["trn2"])]
	if query != "":
		_set_status("Treffer: " + what)
	else:
		_set_status(what + (("  ·  eingelesen " + _scan_time) if _scan_time != "" else ""))

func _new_folder() -> Dictionary:
	return {"dirs": {}, "files": [], "count": 0}

# Unterordner zuerst, dann die Dateien (ohne Endung, Symbol nach Typ). Zugeklappte Ordner bekommen
# nur einen leeren Platzhalter und werden beim Aufklappen gefüllt (_on_item_collapsed).
func _fill_folder(parent: TreeItem, node: Dictionary, rel: String, depth: int, expand_all: bool) -> void:
	var names = node["dirs"].keys()
	names.sort()
	for n in names:
		var child: Dictionary = node["dirs"][n]
		var sub_rel = n if rel == "" else rel + "/" + n
		var item = _tree.create_item(parent)
		item.set_text(0, n)
		item.set_icon(0, _folder_icon)
		item.set_text(1, _fmt(child["count"]))
		item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_custom_color(1, _dim_color)
		item.set_tooltip_text(0, _root.path_join(sub_rel))
		var open = expand_all or depth == 0
		item.set_metadata(0, {"node": child, "rel": sub_rel, "depth": depth + 1, "expand_all": expand_all, "filled": open})
		if open:
			_fill_folder(item, child, sub_rel, depth + 1, expand_all)
			item.collapsed = false
		else:
			_tree.create_item(item) # Platzhalter für den Pfeil
			item.collapsed = true
	var files: Array = node["files"]
	files.sort()
	for f in files:
		var path = _root.path_join(f if rel == "" else rel + "/" + f)
		var item = _tree.create_item(parent)
		item.set_text(0, f.get_basename())
		var ext = f.get_extension().to_lower()
		item.set_icon(0, _gfx_icon if ext == "gfx" else (_map_icon if ext == "trn2" else _ecm_icon))
		item.set_metadata(0, path)
		item.set_tooltip_text(0, path)

func _on_item_collapsed(item: TreeItem) -> void:
	var meta = item.get_metadata(0)
	if item.collapsed or not meta is Dictionary or meta.get("filled", false):
		return
	meta["filled"] = true
	# Aufgeklappt per Maus: während des Mausereignisses legt der Tree keine Einträge an
	_fill_later.call_deferred(item)

func _fill_later(item: TreeItem) -> void:
	if not is_instance_valid(item): # Baum inzwischen neu aufgebaut
		return
	var meta: Dictionary = item.get_metadata(0)
	for child in item.get_children():
		child.free()
	_fill_folder(item, meta["node"], meta["rel"], meta["depth"], meta["expand_all"])

func _on_item_activated() -> void:
	var item = _tree.get_selected()
	if item == null:
		return
	if item.get_metadata(0) is Dictionary:
		item.collapsed = not item.collapsed
		return
	import_selected()

# Pfad der gewählten Datei, "" bei Ordnern
func selected_file() -> String:
	var item = _tree.get_selected()
	if item == null:
		return ""
	var path = item.get_metadata(0)
	return path if path is String else ""


# ====================================================
# IMPORT
# ====================================================
func import_selected() -> void:
	var path = selected_file()
	if path != "":
		import_file(path)

# Baut die ECM / GFX als Szene, öffnet sie (bzw. lädt sie neu) und meldet Hinweise in der Ausgabe.
# Nicht während eines Datei-Scans des Editors: der liest dieselben Dateien, die der Import schreibt.
func import_file(path: String) -> Dictionary:
	var fs = EditorInterface.get_resource_filesystem()
	if fs.is_scanning():
		_set_status("Warte auf den Datei-Scan des Editors ...")
		while fs.is_scanning():
			await get_tree().process_frame
	var importer = preload("ecm_importer.gd").new(_root)
	var ext = path.get_extension().to_lower()
	var kind = {"gfx": "GFX", "trn2": "Map"}.get(ext, "ECM")
	_set_status(kind + " wird importiert ...")
	var res: Dictionary
	match ext:
		"gfx": res = importer.import_gfx(path)
		"trn2": res = importer.import_map(path)
		_: res = importer.import_ecm(path)
	if res.has("error"):
		_set_status("Import fehlgeschlagen: " + res["error"])
		printerr(kind, "-Import ", path, ": ", res["error"])
		return res
	for w in res["warnings"]:
		print(kind, "-Import ", path.get_file(), ": ", w)
	_refresh_filesystem(res.get("written", [res["scene"]]))
	# Offene Szene neu laden; reload_scene_from_path bleibt beim aktiven Tab, also danach wechseln
	if res["scene"] in EditorInterface.get_open_scenes():
		EditorInterface.reload_scene_from_path(res["scene"])
		await get_tree().process_frame
		await get_tree().process_frame
	EditorInterface.open_scene_from_path(res["scene"])
	var n = res["warnings"].size()
	_set_status("Importiert: " + res["scene"] + ((" (%d Hinweise in der Ausgabe)" % n) if n > 0 else ""))
	return res

# Alter Name (Tests, Aufrufer von früher)
func import_ecm(path: String) -> Dictionary:
	return await import_file(path)

# Neue Dateien im Dateisystem-Dock zeigen: nur die geschriebenen Dateien melden (update_file).
# Ein ganzer Scan (EditorFileSystem.scan) direkt nach dem Überschreiben ließ den Editor in einem
# Hintergrund-Thread abstürzen (Vulkan / OpenGL, frischer Editor-Cache, Import schon vorhanden).
func _refresh_filesystem(files: Array) -> void:
	await get_tree().process_frame
	var fs = EditorInterface.get_resource_filesystem()
	for f in files:
		fs.update_file(f)

func _set_status(text: String) -> void:
	_status.text = text
	_status.tooltip_text = text

# 12345 -> "12.345"
func _fmt(n: int) -> String:
	var s = str(n)
	var out = ""
	while s.length() > 3:
		out = "." + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out
