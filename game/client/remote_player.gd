extends Node3D

# ====================================================
# Andere Spielfigur in der Welt: Modell (angelica_player.gd), Name darüber, Position / Richtung
# vom Server (STATE, 10 / s) weich nachgeführt, Animation nach dem Zustand (Stehen, Gehen, Rennen,
# Springen). Klick-Auswahl: Kapsel auf Ebene PICK_LAYER (Meta "pick_id" = ID, local_player.gd).
# Ausrüstung (player_enter equip, player_equip): world_screen.gd baut das Modell neu, replace_model().
# Kampf: play_attack(Endung), play_skill(Aktion einer Fertigkeit), face, die / revive, Kampfzustand
# (mark_fight, Waffen in der Hand, Kampf-Stehen / -Rennen) wie local_player.gd.
# ====================================================

const Proto = preload("../common/protocol.gd")
const FOLLOW = 12.0 # je größer, desto schneller holt die Figur die gemeldete Position ein
const SNAP = 15.0 # weiter weg: springen statt gleiten
const PICK_LAYER = 4 # Ebene 3: Klick-Auswahl
const PICK_RADIUS = 0.45
const ANIM = {Proto.MOVE_STAND: "站立_通用", Proto.MOVE_WALK: "行走_通用", Proto.MOVE_RUN: "奔跑_通用",
	Proto.MOVE_JUMP: "跳跃循环_通用"}
const FIGHT_ANIM = {Proto.MOVE_STAND: "战斗站立_%s", Proto.MOVE_RUN: "战斗奔跑_%s"} # Waffenart
const FIGHT_TIME = 6.0 # s
const PLAYER_MODEL = "res://addons/PWE-Manager/ECM/angelica_player.gd"

var id = 0
var char_name = ""
var level = 1
var cls = 0
var model: Node3D
var anim: AnimationPlayer
var label: Label3D
var target_pos = Vector3.ZERO
var target_dir = 0.0
var state = Proto.MOVE_STAND
var race = 0
var gender = 0
var appearance = {}
var equip: Array = [] # [[Platz, ID]] (Meldungen des Servers)
var dead = false
var suffix = "空手"
var height = 1.8
var fighting = false
var _fight_until = 0 # ms
var _once = ""


func setup(p_id: int, p_name: String, p_model: Node3D, p_height: float, pos: Vector3, dir: float) -> void:
	id = p_id
	char_name = p_name
	height = p_height
	name = "Spieler_%d" % id
	if p_model != null:
		model = p_model
		add_child(model)
		anim = model.get_node_or_null("AnimationPlayer")
	label = Label3D.new()
	label.text = p_name
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = height + 0.35
	label.pixel_size = 0.004
	label.font_size = 40
	label.outline_size = 10
	label.modulate = Color(1.0, 0.95, 0.75)
	label.no_depth_test = true
	add_child(label)
	var pick = Area3D.new()
	pick.name = "Auswahl"
	pick.collision_layer = PICK_LAYER
	pick.collision_mask = 0
	pick.monitoring = false
	pick.set_meta("pick_id", id)
	var shape = CapsuleShape3D.new()
	shape.radius = PICK_RADIUS
	shape.height = maxf(height, PICK_RADIUS * 2.0)
	var cs = CollisionShape3D.new()
	cs.shape = shape
	cs.position.y = shape.height / 2.0
	pick.add_child(cs)
	add_child(pick)
	position = pos
	target_pos = pos
	set_dir(dir)
	target_dir = dir
	_animate()

func replace_model(p_model: Node3D) -> void:
	var dir = model.rotation.y if model != null else target_dir
	if model != null:
		model.queue_free()
	model = p_model
	if model == null:
		anim = null
		return
	add_child(model)
	model.rotation.y = dir
	anim = model.get_node_or_null("AnimationPlayer")
	load(PLAYER_MODEL).place_weapons(model, fighting)
	_animate()

# Angriff / Treffer: FIGHT_TIME s im Kampf
func mark_fight() -> void:
	_fight_until = Time.get_ticks_msec() + int(FIGHT_TIME * 1000.0)
	if not fighting:
		set_fighting(true)

func set_fighting(on: bool) -> void:
	fighting = on
	load(PLAYER_MODEL).place_weapons(model, on)
	_animate()

# -> gespielte Aktion (für die Angriffs-Effekte)
func play_attack() -> String:
	var act = "普通攻击%d_%s" % [randi() % 3 + 1, suffix]
	if anim != null and not anim.has_animation(act):
		act = "普通攻击1_空手"
	if anim != null and anim.has_animation(act) and not dead:
		anim.play(act, 0.1)
		_once = act
	return act

# Aktion einer Fertigkeit einmal abspielen -> Länge s (0 = Figur hat sie nicht)
func play_skill(act: String) -> float:
	if anim == null or act == "" or not anim.has_animation(act) or dead:
		return 0.0
	anim.play(act, 0.1)
	_once = act
	return anim.get_animation(act).length

func die() -> void:
	dead = true
	if anim != null and anim.has_animation("死亡_通用"):
		anim.play("死亡_通用", 0.1)
		if anim.has_animation("死亡循环_通用"):
			anim.queue("死亡循环_通用")

func revive(pos: Vector3) -> void:
	dead = false
	position = pos
	target_pos = pos
	_once = ""
	set_fighting(false)

# Zu einem Punkt drehen (Fertigkeit auf ein Ziel)
func face(p: Vector3) -> void:
	var d = p - global_position
	if model != null and Vector2(d.x, d.z).length() > 0.05:
		model.rotation.y = atan2(d.x, d.z)

func set_dir(dir: float) -> void:
	if model != null:
		model.rotation.y = dir

func update_state(pos: Vector3, dir: float, p_state: int) -> void:
	target_pos = pos
	target_dir = dir
	if p_state != state:
		state = p_state
		_animate()

func _process(delta: float) -> void:
	if fighting and Time.get_ticks_msec() > _fight_until and not dead:
		set_fighting(false)
	if _once != "" and anim != null and not anim.is_playing():
		_animate()
	if position.distance_to(target_pos) > SNAP:
		position = target_pos
	else:
		position = position.lerp(target_pos, clampf(FOLLOW * delta, 0.0, 1.0))
	if model != null:
		model.rotation.y = lerp_angle(model.rotation.y, target_dir, clampf(FOLLOW * delta, 0.0, 1.0))

func _animate() -> void:
	if dead:
		return
	if _once != "" and anim != null and anim.current_animation == _once and anim.is_playing() and state == Proto.MOVE_STAND:
		return
	_once = ""
	var a = ANIM.get(state, ANIM[Proto.MOVE_STAND])
	if fighting and FIGHT_ANIM.has(state) and anim != null and anim.has_animation(FIGHT_ANIM[state] % suffix):
		a = FIGHT_ANIM[state] % suffix
	if anim != null and anim.has_animation(a) and anim.current_animation != a:
		anim.play(a, 0.15)
