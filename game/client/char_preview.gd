extends Node

# ====================================================
# 3D-Vorschau einer Spielfigur für Figurenauswahl und -erstellung: eigener SubViewport (eigene
# Welt, durchsichtiger Hintergrund) mit Kamera, Licht und der Figur aus dem Plugin
# (angelica_player.gd: Körper, Kopf, Haare, Standardkleidung der Klasse, Haut- / Haarfarbe).
# Die Textur zeigt aui_manager.gd zwischen Hintergrund und Dialogen (set_scene).
#   show_char(Rasse, Geschlecht, Klasse, Aussehen) -> "" / Fehler (gleiche Figur: nur Aussehen)
#   screen_x: Anteil der Bildschirmbreite, auf dem die Figur steht; close_up: Kopf groß (Aussehen)
#   turn(Richtung -1 / 0 / 1) dreht, zoom(1 vor / -1 zurück / 0) fährt die Kamera, solange gesetzt
# Die Figur steht in Leerlauf-Haltung (站立_通用).
# Im Charakter-Fenster (hud.gd): setup(data_root, false) = feste Größe (resize), set_equipment(...) legt
# die Ausrüstung an (angelica_player.gd set_equipment), set_active schaltet das Rendern an / aus.
# ====================================================

const PLAYER = "res://addons/PWE-Manager/ECM/angelica_player.gd"
const FOV = 30.0
const TURN_SPEED = 120.0 # Grad je Sekunde
const ZOOM_SPEED = 0.8 # Anteil des Abstands je Sekunde
const ZOOM_MIN = 0.45
const ZOOM_MAX = 1.6
const IDLE = "站立_通用"

var viewport: SubViewport
var camera: Camera3D
var pivot: Node3D
var model # angelica_player.gd
var screen_x = 0.5
var close_up = false
var warnings: Array = []
var _data_root = ""
var _key = ""
var _turn = 0
var _zoom_dir = 0
var _zoom = 1.0


func setup(data_root: String, follow_screen: bool = true) -> void:
	_data_root = data_root
	viewport = SubViewport.new()
	viewport.name = "Vorschau"
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var env = WorldEnvironment.new()
	var e = Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.62, 0.66)
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = e
	viewport.add_child(env)
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30, 25, 0)
	sun.light_energy = 0.9
	viewport.add_child(sun)
	camera = Camera3D.new()
	camera.fov = FOV
	viewport.add_child(camera)
	pivot = Node3D.new()
	pivot.name = "Figur"
	viewport.add_child(pivot)
	if follow_screen:
		resize(get_viewport().get_visible_rect().size)
		get_viewport().size_changed.connect(func(): resize(get_viewport().get_visible_rect().size))

func texture() -> Texture2D:
	return viewport.get_texture()

func resize(size: Vector2) -> void:
	viewport.size = Vector2i(maxi(1, int(size.x)), maxi(1, int(size.y)))
	_frame()

func show_char(race: int, gender: int, cls: int, look: Dictionary) -> String:
	var key = "%d_%d_%d" % [race, gender, cls]
	if key == _key and model != null and model.root != null:
		model.set_appearance(look)
		_take_warnings()
		return ""
	clear()
	if model == null:
		model = load(PLAYER).new(_data_root)
	var err = model.build(race, gender, cls, look)
	_take_warnings()
	if err != "":
		return err
	_key = key
	pivot.add_child(model.root)
	model.play(IDLE)
	_frame()
	return ""

func set_equipment(equip: Dictionary) -> void:
	if model != null and model.root != null:
		model.set_equipment(equip)
		_take_warnings()

func set_active(on: bool) -> void:
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED

func clear() -> void:
	_key = ""
	if model != null:
		model.free_model()

func set_close_up(on: bool) -> void:
	close_up = on
	_frame()

func set_screen_x(x: float) -> void:
	screen_x = x
	_frame()

func turn(direction: int) -> void:
	_turn = direction

func reset_turn() -> void:
	_turn = 0
	pivot.rotation = Vector3.ZERO

func zoom(direction: int) -> void:
	_zoom_dir = direction

func reset_zoom() -> void:
	_zoom_dir = 0
	_zoom = 1.0
	_frame()

func _process(delta: float) -> void:
	if _turn != 0:
		pivot.rotate_y(deg_to_rad(TURN_SPEED * delta * _turn))
	if _zoom_dir != 0:
		_zoom = clampf(_zoom - ZOOM_SPEED * delta * _zoom_dir, ZOOM_MIN, ZOOM_MAX)
		_frame()

# Kamera auf die Figur: ganz (Höhe füllt ~80 %) oder Kopf groß; seitlich verschoben auf screen_x
func _frame() -> void:
	if camera == null:
		return
	var h = 1.8
	if model != null and model.root != null:
		h = maxf(0.5, model.bounds().size.y)
	var target_y = h * 0.52
	var span = h * 1.25
	if close_up:
		target_y = h * 0.9
		span = 0.55 * clampf(h / 1.8, 0.6, 1.3)
	var half = tan(deg_to_rad(FOV) / 2.0)
	var d = span / 2.0 / half * _zoom
	camera.position = Vector3(0, target_y, d)
	camera.look_at(Vector3(0, target_y, 0))
	var aspect = float(viewport.size.x) / maxf(1.0, viewport.size.y)
	camera.h_offset = -(screen_x - 0.5) * 2.0 * d * half * aspect

func _take_warnings() -> void:
	if model == null:
		return
	for w in model.warnings:
		if not w in warnings:
			warnings.append(w)
			push_warning("Персонаж: " + w)
	model.warnings.clear()
