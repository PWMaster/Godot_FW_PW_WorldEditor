@tool
extends Node3D

# ====================================================
# ECModel einer Map (ECWDFILEECMODEL, angelica_world.gd): die Szene der .ecm läuft mit der
# Aktion aus der Map endlos, im Spiel wie im Editor. Die Aktion ist meist eine kombinierte der
# .ecm; fehlt sie im AnimationPlayer, gelten ihre Basis-Aktionen, und ein Modell mit nur einer
# Animation spielt diese (wie gfx_ecmodel_230.gd).
# Das Modell hängt als interner Knoten darunter und wird nicht mit der Map gespeichert.
# ====================================================

## Importierte Szene der .ecm
@export var Model_Scene: PackedScene:
	set(value):
		Model_Scene = value
		_queue()
## Aktion aus der Map (kombinierte Aktion der .ecm)
@export var Action_Name: String = "":
	set(value):
		Action_Name = value
		_queue()
## Basis-Aktionen der kombinierten Aktion (aus der .ecm)
@export var Base_Actions: PackedStringArray = []:
	set(value):
		Base_Actions = value
		_queue()

var _model: Node = null
var _player: AnimationPlayer = null
var _anim: StringName = &""
var _queued = false


func _ready() -> void:
	_queue()

# Einmal je Frame neu aufbauen, auch wenn mehrere Eigenschaften zugleich gesetzt werden
func _queue() -> void:
	if not _queued:
		_queued = true
		_rebuild.call_deferred()

func _rebuild() -> void:
	_queued = false
	if not is_inside_tree():
		return
	if _model != null:
		remove_child(_model)
		_model.queue_free()
	_model = null
	_player = null
	_anim = &""
	if Model_Scene == null:
		return
	_model = Model_Scene.instantiate()
	add_child(_model, false, Node.INTERNAL_MODE_BACK)
	_player = _find_player(_model)
	if _player == null:
		return
	_anim = _match(Action_Name)
	for base in Base_Actions:
		if _anim == &"":
			_anim = _match(base)
	if _anim == &"":
		var names = Array(_player.get_animation_list()).filter(func(n): return n.get_slice("/", n.get_slice_count("/") - 1) != "RESET")
		if names.size() == 1:
			_anim = StringName(names[0])
	if _anim == &"":
		return
	_player.animation_finished.connect(func(_name): _player.play(_anim))
	_player.play(_anim)

func _find_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children(true):
		var p = _find_player(child)
		if p != null:
			return p
	return null

# Angelica-Aktionsname -> Animation (auch in benannten Bibliotheken, ohne Groß/Klein)
func _match(act_name: String) -> StringName:
	if act_name == "":
		return &""
	for n in _player.get_animation_list():
		if n == act_name or n.get_slice("/", n.get_slice_count("/") - 1).to_lower() == act_name.to_lower():
			return StringName(n)
	return &""
