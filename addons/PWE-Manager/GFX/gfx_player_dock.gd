@tool
extends EditorDock

# ====================================================
# Leiste "GFX-Player" rechts im Editor (neben Inspektor, Signale, Gruppen).
# Steuert die GFX (Datei-Nodes, gfx_data_node.gd) der offenen Szene: die in der Auswahl
# (gewählte GFX, GFX unter gewählten Nodes und die GFX über einem gewählten Element),
# sonst alle. GFX unter einem Container (ID 200) steuert der Container, sie zählen nicht mit.
#   Play-GFX     alle ab der Zeit am Regler gemeinsam laufen lassen
#   Stop-GFX     anhalten und auf 0 setzen
#   Zeit-Regler  alle auf dieselbe Zeit setzen (echte ms seit dem Start, PlaySpeed je GFX
#                wird eingerechnet); Länge = längster Durchlauf der gesteuerten GFX
# Anhalten gilt nur im Editor und wird nicht gespeichert (gfx_data_node.player_paused):
# nach dem Neuladen der Szene und im Spiel laufen die GFX wie immer.
# ====================================================

const HEADER = preload("gfx_data_node.gd")
const MIN_LENGTH_MS = 100.0
const REFRESH_DELAY = 0.3 # s nach Änderungen im Szenenbaum, bevor die GFX neu gesammelt werden

var _targets: Array = []
var _scene_id = 0
var _targets_dirty = true
var _refresh_wait = 0.0
var _length_ms = 3000.0
var _dragging = false
var _resume_after_drag = false

var _info: Label
var _play_btn: Button
var _stop_btn: Button
var _slider: HSlider
var _time_label: Label


func _init() -> void:
	title = "GFX-Player"
	layout_key = "GFX-Player"
	icon_name = &"Play"
	default_slot = DOCK_SLOT_RIGHT_UL

	var box = VBoxContainer.new()
	add_child(box)

	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_info)

	var bar = HBoxContainer.new()
	box.add_child(bar)
	_play_btn = Button.new()
	_play_btn.text = "Воспроизвести GFX"
	_play_btn.tooltip_text = "Запустить GFX с выбранного момента"
	_play_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_play_btn.pressed.connect(play)
	bar.add_child(_play_btn)
	_stop_btn = Button.new()
	_stop_btn.text = "Остановить GFX"
	_stop_btn.tooltip_text = "Остановить GFX и вернуть время в начало"
	_stop_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stop_btn.pressed.connect(stop)
	bar.add_child(_stop_btn)

	_slider = HSlider.new()
	_slider.min_value = 0.0
	_slider.step = 1.0
	_slider.tooltip_text = "Время GFX (мс)"
	_slider.value_changed.connect(seek)
	_slider.drag_started.connect(_on_drag_started)
	_slider.drag_ended.connect(_on_drag_ended)
	box.add_child(_slider)

	_time_label = Label.new()
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_time_label)
	_update_buttons()

func _ready() -> void:
	var editor_theme = EditorInterface.get_editor_theme()
	_play_btn.icon = editor_theme.get_icon(&"Play", &"EditorIcons")
	_stop_btn.icon = editor_theme.get_icon(&"Stop", &"EditorIcons")

func _enter_tree() -> void:
	EditorInterface.get_selection().selection_changed.connect(_mark_dirty)
	get_tree().node_added.connect(_on_tree_changed)
	get_tree().node_removed.connect(_on_tree_changed)

func _exit_tree() -> void:
	EditorInterface.get_selection().selection_changed.disconnect(_mark_dirty)
	get_tree().node_added.disconnect(_on_tree_changed)
	get_tree().node_removed.disconnect(_on_tree_changed)

func _process(delta: float) -> void:
	var root = EditorInterface.get_edited_scene_root()
	var id = root.get_instance_id() if root != null else 0
	if id != _scene_id:
		_scene_id = id
		_mark_dirty()
	if _targets_dirty:
		_refresh_wait -= delta
		if _refresh_wait <= 0.0:
			refresh_targets()
	if is_visible_in_tree():
		_update_time()


# ====================================================
# STEUERN
# ====================================================
func play() -> void:
	var t = _slider.value
	for h in _valid_targets():
		h.player_seek(t)
		h.player_paused = false
	_update_buttons()

func stop() -> void:
	for h in _valid_targets():
		h.player_paused = true
		h.player_seek(0.0)
	_slider.set_value_no_signal(0.0)
	_update_time()
	_update_buttons()

func seek(ms: float) -> void:
	for h in _valid_targets():
		h.player_seek(ms)
	_update_time()

func is_playing() -> bool:
	for h in _valid_targets():
		if not h.player_paused:
			return true
	return false

# Während des Ziehens angehalten, danach läuft es weiter, wenn es lief
func _on_drag_started() -> void:
	_dragging = true
	_resume_after_drag = is_playing()
	for h in _valid_targets():
		h.player_paused = true

func _on_drag_ended(_changed: bool) -> void:
	_dragging = false
	if _resume_after_drag:
		play()


# ====================================================
# GESTEUERTE GFX
# ====================================================
func _mark_dirty() -> void:
	_targets_dirty = true
	_refresh_wait = 0.0

func _on_tree_changed(node: Node) -> void:
	var root = EditorInterface.get_edited_scene_root()
	if root != null and (node == root or root.is_ancestor_of(node)):
		_targets_dirty = true
		_refresh_wait = REFRESH_DELAY

func refresh_targets() -> void:
	_targets_dirty = false
	_targets.clear()
	var root = EditorInterface.get_edited_scene_root()
	var from_selection = false
	if root != null:
		for n in EditorInterface.get_selection().get_selected_nodes():
			if n == root or not root.is_ancestor_of(n):
				continue
			var above = n.get_parent()
			while above != null and above != root:
				if _is_target(above):
					_add(above)
					break
				above = above.get_parent()
			_collect(n)
		from_selection = not _targets.is_empty()
		if not from_selection:
			_collect(root)
	_length_ms = MIN_LENGTH_MS
	for h in _targets:
		_length_ms = maxf(_length_ms, h.player_length_ms())
	_slider.max_value = _length_ms
	if root == null:
		_info.text = "Сцена не открыта"
	elif _targets.is_empty():
		_info.text = "В сцене нет GFX"
	else:
		_info.text = "%s: объектов GFX — %d" % ["Выделение" if from_selection else "Сцена", _targets.size()]
	var names = PackedStringArray()
	for h in _targets.slice(0, 30):
		names.append(str(root.get_path_to(h)))
	if _targets.size() > 30:
		names.append("...")
	_info.tooltip_text = "\n".join(names)
	_update_time()
	_update_buttons()

func _is_target(n: Node) -> bool:
	return n.get_script() == HEADER and n.Header_Control and not n.is_passive()

func _add(h: Node) -> void:
	if not h in _targets:
		_targets.append(h)

func _collect(n: Node) -> void:
	if _is_target(n):
		_add(n)
	for child in n.get_children():
		_collect(child)

func _valid_targets() -> Array:
	return _targets.filter(func(h): return is_instance_valid(h) and h.is_inside_tree())


# ====================================================
# ANZEIGE
# ====================================================
func _update_time() -> void:
	var targets = _valid_targets()
	if targets.is_empty():
		_time_label.text = "-"
		return
	if not _dragging:
		_slider.set_value_no_signal(fposmod(targets[0].player_time_ms(), _length_ms))
	_time_label.text = "%.2f s / %.2f s" % [_slider.value / 1000.0, _length_ms / 1000.0]

func _update_buttons() -> void:
	var none = _valid_targets().is_empty()
	_play_btn.disabled = none
	_stop_btn.disabled = none
	_slider.editable = not none
