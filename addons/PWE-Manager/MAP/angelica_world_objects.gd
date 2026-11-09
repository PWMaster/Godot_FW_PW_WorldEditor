@tool
extends Node3D

# ====================================================
# Objekte einer Map (angelica_world.gd): Effekte, ECModelle und Sounds tragen ihre Tageszeit
# als Meta "valid_time" (0 Tag, 1 Nacht, 2 immer, wie iValidTime / nShowType der .ecwld).
# Aktiv ist ein Objekt, wenn es zur Tageszeit passt (Night) und nah genug an der Kamera ist
# (Load_Radius, Sounds bis zu ihrem max_distance) - wie das Spiel, das nur die Blöcke um den
# Spieler lädt. Inaktive Objekte sind unsichtbar, laufen nicht und sind stumm.
# Night schaltet auch das Licht der Map um ("Sun" / "Environment" daneben, Tag- und Nachtwerte
# als Meta von angelica_world.gd).
# Animate_In_Editor aus: im Editor bleiben alle Objekte stehen (sichtbar, aber ohne Ablauf), der
# Editor zeichnet dann nur bei Änderungen neu statt jedes Frame.
# Kamera: im Spiel die aktive, im Editor die des 3D-Viewports.
# ====================================================

const UPDATE_INTERVAL = 0.25 # Sekunden zwischen zwei Prüfungen

## Nacht statt Tag
@export var Night: bool = false:
	set(value):
		Night = value
		_next = 0.0
## Effekte und Modelle nur bis zu diesem Abstand von der Kamera (Meter), 0 = alle
@export var Load_Radius: float = 250.0:
	set(value):
		Load_Radius = value
		_next = 0.0
## Effekte, Modelle und Dummies im Editor abspielen (aus: sie stehen still, der Editor zeichnet
## nicht mehr jedes Frame neu und die CPU-Last fällt)
@export var Animate_In_Editor: bool = true:
	set(value):
		Animate_In_Editor = value
		_next = 0.0

var _next = 0.0
var _light_night = null # zuletzt gesetztes Licht (Tag / Nacht)


func _ready() -> void:
	apply_time()

func _process(delta: float) -> void:
	_next -= delta
	if _next <= 0.0:
		_next = UPDATE_INTERVAL
		apply_time()

func apply_time() -> void:
	var cam = _camera()
	_apply(self, cam.global_position if cam != null else null)
	if _light_night != Night:
		_light_night = Night
		_apply_light()

func _apply_light() -> void:
	var map = get_parent()
	if map == null:
		return
	var key = "night" if Night else "day"
	var sun = map.get_node_or_null("Sun")
	if sun is DirectionalLight3D and sun.has_meta(key + "_color"):
		sun.light_color = sun.get_meta(key + "_color")
	var we = map.get_node_or_null("Environment")
	if we is WorldEnvironment and we.environment != null and we.has_meta(key + "_ambient"):
		we.environment.ambient_light_color = we.get_meta(key + "_ambient")
		we.environment.background_color = we.get_meta(key + "_background")

func _apply(node: Node, cam_pos) -> void:
	for child in node.get_children():
		if not child.has_meta("valid_time"):
			_apply(child, cam_pos)
			continue
		var vt = int(child.get_meta("valid_time"))
		var on = vt == 2 or vt == (1 if Night else 0)
		var radius = child.max_distance if child is AudioStreamPlayer3D else Load_Radius
		if on and cam_pos != null and radius > 0.0 and child is Node3D:
			on = (child as Node3D).global_position.distance_to(cam_pos) <= radius
		if child is Node3D and child.visible != on:
			child.visible = on
		var run = on and (Animate_In_Editor or not Engine.is_editor_hint())
		var mode = Node.PROCESS_MODE_INHERIT if run else Node.PROCESS_MODE_DISABLED
		if child.process_mode != mode:
			child.process_mode = mode
		if child is AudioStreamPlayer3D and child.stream_paused == on:
			child.stream_paused = not on

func _camera() -> Camera3D:
	if not is_inside_tree():
		return null
	var vp: Viewport = get_viewport()
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		vp = Engine.get_singleton(&"EditorInterface").get_editor_viewport_3d(0)
	return vp.get_camera_3d() if vp != null else null
