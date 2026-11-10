@tool
extends EditorPlugin

# ====================================================
# PWE-Manager (früher gfx_importer). Ordner:
#   GFX/     .gfx lesen und als Nodes aufbauen (gfx_parser.gd, create_id_*.gd, gfx_*.gd, GFX-Player)
#   ECM/     Modelle (.ecm / .smd / .ski), Import-Leiste ECM-GFX-MAP, Spielfiguren (angelica_player.gd)
#   MAP/     Maps: Terrain, Gebäude, Wasser, Licht, Objekte (angelica_terrain.gd, angelica_world.gd)
#   UI-XML/  Oberfläche des Spiels (AUI-XML) lesen und bauen, Leiste XML
#   Server/  Server-Daten (Spawns, Höhen, Kollision, Vorlagen) und Leiste SERVER
#   Abgleich/ Leiste ABGLEICH: passen Server- und Client-Daten zusammen (Match in %)
#   Data/    gemeinsame Leser: Dateien / GBK, .pck-Pakete (angelica_pck.gd, angelica_vfs.gd: die
#            Spieldaten werden direkt aus den Original-Paketen gelesen), elements.data, tasks.data
#   Docs/    Fahrplan, Todo-Listen;  tools/  Erzeuger der Beschreibungen (Python / GDScript)
# "GFX Ausführen" (Projekt -> Werkzeuge): lädt alle .gfx aus res://GFX_Load (Unterordner =
# Ordner-Nodes) in die offene Szene; Texturen, Unter-GFX (Container, ID 200), Modelle und Klänge
# kommen aus den Spieldaten (GFX/gfx_sources.gd). Parser und Node-Aufbau: GFX/gfx_parser.gd.
# Leiste "ECM-GFX-MAP" unten im Editor: alle .ecm und .gfx der Spieldaten, Import als Szene (ecm_gfx_panel.gd).
# Leiste "GFX-Player" rechts: GFX der offenen Szene abspielen / anhalten (gfx_player_dock.gd).
# Leiste "XML" unten: Dialoge der Oberfläche je Sprache, Klick öffnet sie in 2D (aui_xml_panel.gd).
# Leiste "SERVER" unten: Godot-FW-Server starten / stoppen, Log, Test-Client, Spawns in die offene
# Map (Server/server_panel.gd; Spawn-Daten und Server in Server/).
# ====================================================

const Parser = preload("GFX/gfx_parser.gd")
const EcmPanel = preload("ECM/ecm_gfx_panel.gd")
const PlayerDock = preload("GFX/gfx_player_dock.gd")
const XmlPanel = preload("UI-XML/aui_xml_panel.gd")
const ServerPanel = preload("Server/server_panel.gd")
const CheckPanel = preload("Abgleich/check_panel.gd")
const Sources = preload("GFX/gfx_sources.gd")
const VFS = preload("Data/angelica_vfs.gd")

var _ecm_panel: EditorDock = null
var _player_dock: EditorDock = null
var _xml_panel: EditorDock = null
var _server_panel: EditorDock = null
var _check_panel: EditorDock = null

# --- EINSTELLUNGEN ---
const SPAWN_ABSTAND_X: float = 20.0
const SPAWN_ABSTAND_Z: float = 20.0 
const ITEMS_PER_ROW: int = 30      
# ---------------------

func _enter_tree():
	add_tool_menu_item("Запустить GFX", _on_ausfuehren_pressed)
	_ecm_panel = EcmPanel.new()
	add_dock(_ecm_panel)
	_player_dock = PlayerDock.new()
	add_dock(_player_dock)
	_xml_panel = XmlPanel.new()
	add_dock(_xml_panel)
	_server_panel = ServerPanel.new()
	add_dock(_server_panel)
	_check_panel = CheckPanel.new()
	add_dock(_check_panel)

func _exit_tree():
	remove_tool_menu_item("Запустить GFX")
	if _ecm_panel != null:
		remove_dock(_ecm_panel)
		_ecm_panel.queue_free()
		_ecm_panel = null
	if _player_dock != null:
		remove_dock(_player_dock)
		_player_dock.queue_free()
		_player_dock = null
	if _xml_panel != null:
		remove_dock(_xml_panel)
		_xml_panel.queue_free()
		_xml_panel = null
	if _check_panel != null:
		remove_dock(_check_panel)
		_check_panel.queue_free()
		_check_panel = null
	if _server_panel != null:
		remove_dock(_server_panel)
		_server_panel.queue_free()
		_server_panel = null
	Parser.release_decoder()
	Sources.release()
	VFS.reset() # offene .pck schließen

func _on_ausfuehren_pressed():
	var root_node = get_editor_interface().get_edited_scene_root()
	if not root_node: return
	
	# --- NEU: Zuweisung des Scripte für die Buttons ---
	var button_script = preload("res://addons/PWE-Manager/GFX/gfx_buttons.gd")
	if root_node.get_script() != button_script:
		root_node.set_script(button_script)
		print("Кнопки добавлены к корневому узлу.")
	# --------------------------------------------------
	
	
	if not DirAccess.dir_exists_absolute(Parser.LOAD_DIR):
		print("PWE-Manager: ", Parser.LOAD_DIR, " fehlt. Zu ladende .gfx dort ablegen.")
		return
		
	var parser = Parser.new()
	var relative_gfx_files = parser.get_all_gfx_files_recursively(Parser.LOAD_DIR, "")
	if relative_gfx_files.is_empty():
		print("PWE-Manager: keine .gfx in ", Parser.LOAD_DIR)
		return
		
	var undo_redo = get_undo_redo()
	undo_redo.create_action("GFX System importieren")
	var path_to_node = {"": root_node}
	var file_counter = 0 
	
	for file_path in relative_gfx_files:
		var parts = file_path.split("/")
		var current_path = ""
		var parent_path = ""
		
		for i in range(parts.size()):
			var part_name = parts[i]
			var is_file = (i == parts.size() - 1)
			
			if is_file: part_name = part_name.get_basename()
				
			if current_path == "": current_path = part_name
			else:
				parent_path = current_path
				current_path = current_path + "/" + part_name
				
			if path_to_node.has(current_path): continue
				
			var parent_node = path_to_node[parent_path]
			var existing_child = parent_node.get_node_or_null(NodePath(part_name))
			
			if existing_child:
				path_to_node[current_path] = existing_child
			else:
				var file_node: Node3D
				if is_file:
					var skipped_ids = []
					file_node = parser.build_file_node(Parser.LOAD_DIR + file_path, part_name, skipped_ids)
					file_node.position.x = (file_counter % ITEMS_PER_ROW) * SPAWN_ABSTAND_X
					file_node.position.z = (file_counter / ITEMS_PER_ROW) * SPAWN_ABSTAND_Z 
					for raw_id in skipped_ids:
						print("PWE-Manager: пропущен неизвестный идентификатор ", raw_id, " в файле: ", part_name)
					_debug_file_node(file_node, file_path)
					file_counter += 1
				else:
					file_node = Node3D.new()
					file_node.name = part_name

				# Datei-Node samt Elementen und CtrlMethods in einem Schritt
				undo_redo.call("add_do_method", self, "_add_node_to_scene", file_node, parent_node, root_node)
				undo_redo.call("add_undo_method", self, "_remove_node_from_scene", file_node, parent_node)
				undo_redo.call("add_do_reference", file_node)
				path_to_node[current_path] = file_node
				
	undo_redo.commit_action()
	print("---------------------------------------------")
	print("PWE-Manager: Import abgeschlossen (", file_counter, " Dateien aus ", Parser.LOAD_DIR, ").")
	print("---------------------------------------------")


func _debug_file_node(file_node: Node, file_path: String):
	_debug_unhandled_params(file_node, file_node.parsed_data, file_path, "Kopfzeile")
	for element_node in file_node.get_children():
		_debug_unhandled_params(element_node, element_node.parsed_data, file_path, element_node.name)
		for group in element_node.get_children():
			for ctrl in group.get_children():
				if ctrl.get_script() != null:
					_debug_unhandled_params(ctrl, ctrl.parsed_data, file_path, ctrl.name)


# --- DYNAMISCHER DEBUGGER FÜR FEHLENDE PARAMETER ---
func _debug_unhandled_params(node: Node, data: Dictionary, file_path: String, node_name: String):
	var script = node.get_script()
	if not script: return
	
	var known = []
	
	# Wir prüfen, ob es ein Dictionary (neu) oder Array (alt) ist
	if "KNOWN_PARAMS" in script: 
		known.append_array(script.KNOWN_PARAMS.keys() if script.KNOWN_PARAMS is Dictionary else script.KNOWN_PARAMS)
	if "KNOWN_PARAMS_TOP" in script: 
		known.append_array(script.KNOWN_PARAMS_TOP.keys() if script.KNOWN_PARAMS_TOP is Dictionary else script.KNOWN_PARAMS_TOP)
	if "KNOWN_PARAMS_BOTTOM" in script: 
		known.append_array(script.KNOWN_PARAMS_BOTTOM.keys() if script.KNOWN_PARAMS_BOTTOM is Dictionary else script.KNOWN_PARAMS_BOTTOM)
	if "PARAMS" in script: 
		known.append_array(script.PARAMS.keys() if script.PARAMS is Dictionary else script.PARAMS)
		
	var unhandled = []
	for key in data.keys():
		# Wir ignorieren unsere eigenen versteckten System-Variablen
		if key.begins_with("_"): continue
		
		# Geplante dynamische Arrays einfach durchwinken
		if key.begins_with("GridVector"): continue
		if key.begins_with("dwColor"): continue
		if key.begins_with("Pos") and "_Type_110" in node_name: continue
		if key.begins_with("Path_") and "_ID_170" in node_name: continue
		
		# Wenn der gefundene Parameter nicht in deiner Liste stand:
		if not key in known:
			unhandled.append(key)
			
	if not unhandled.is_empty():
		print("[DEBUG] Nicht hinterlegte Parameter: ", unhandled, "  -->  ", file_path, " (in ", node_name, ")")

func _add_node_to_scene(node: Node, parent: Node, scene_root: Node):
	parent.add_child(node)
	_set_owner_recursive(node, scene_root)

func _set_owner_recursive(node: Node, scene_root: Node):
	node.owner = scene_root
	for child in node.get_children():
		_set_owner_recursive(child, scene_root)

func _remove_node_from_scene(node: Node, parent: Node):
	parent.remove_child(node)
