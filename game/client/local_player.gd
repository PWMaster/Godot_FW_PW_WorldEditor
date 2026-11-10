extends CharacterBody3D

# ====================================================
# Eigene Spielfigur in der Welt (vereinfacht nach EC_HostMove / EC_CameraCtrl):
#   W / S / A / D oder Pfeiltasten  laufen relativ zur Kamera (A / D seitlich)
#   Umschalt gedrückt  gehen statt rennen (elements.data: 1,35 / 4,0 m/s)
#   Leertaste  springen;  linke Maustaste auf den Boden  dorthin laufen, auf eine Figur (NPC,
#   Monster, anderer Spieler: Auswahl-Kapsel auf Ebene PICK_LAYER)  Signal picked(ID) statt laufen
#   rechte Maustaste ziehen  Kamera drehen (auch hoch / runter);  Mausrad  Abstand
# Autoroute: follow_path(Wegpunkte, Halteabstand) läuft einen Weg der Wegfindung ab (rennend);
# Bewegungstasten oder ein Klick brechen ab (route_finished(false)), am Ziel route_finished(true);
# kommt die Figur ROUTE_STUCK_TIME s lang kaum voran, route_stuck (world_screen.gd sucht neu).
# Kampf: play_attack (普通攻击<1-3>_<suffix>, Reihenfolge zufällig wie CECPlayer::PlayAttackEffect),
# play_hurt (受伤_通用, nur im Stehen), die (死亡_通用, dann liegen 死亡循环_通用), revive; manual_move
# meldet Bewegungstasten / Klick auf den Boden (beendet den Normalangriff, bricht das Zaubern ab);
# play_skill(Aktion) spielt die Aktion einer Fertigkeit einmal (z.B. 法师_火球术).
# Schwerkraft und Kollision (Terrain und Gebäude, world_screen.gd), die Kamera weicht Wänden aus
# (SpringArm3D). Position = Füße wie im Spiel; Richtung = Drehung der Figur um Y (0 = Blick +Z).
# Animationen: Stehen, Gehen, Rennen, Springen (Start, Schleife, Landen).
# Kampfzustand (wie CECPlayer::SetIsFighting(true, 6000)): mark_fight() bei Angriff und Treffer, bis
# FIGHT_TIME s nach dem letzten; dann hängen die Waffen in der Hand (angelica_player.gd place_weapons),
# Stehen / Rennen sind 战斗站立 / 战斗奔跑_<Waffenart>; danach wieder Rücken bzw. Gürtel.
# ====================================================

const Proto = preload("../common/protocol.gd")
const PICK_LAYER = 4 # Ebene 3: Auswahl-Kapseln (world_npc.gd, remote_player.gd)
const GRAVITY = 20.0
const JUMP_SPEED = 7.0
const TURN_RATE = 12.0
const CAM_MIN = 2.0
const CAM_MAX = 20.0
const CAM_START = 7.0
const MOUSE_TURN = 0.014
const LOCAL_WALK_SPEED = 12.0
const LOCAL_SPRINT_SPEED = 26.0
const LOCAL_ACCELERATION = 48.0
const FREE_CAMERA_SPEED = 35.0
const FREE_CAMERA_BOOST = 140.0
const FREE_CAMERA_ACCELERATION = 120.0
const PITCH_MIN = -1.35
const PITCH_MAX = 0.6
const ARRIVE = 0.3
const WAYPOINT_REACHED = 0.6 # m: nächster Wegpunkt
const ROUTE_STUCK_TIME = 1.2 # s
const ROUTE_STUCK_MOVE = 0.3 # m in dieser Zeit
const ANIM = {"stand": "站立_通用", "walk": "行走_通用", "run": "奔跑_通用", "jump_start": "跳跃起_通用",
	"jump_loop": "跳跃循环_通用", "land": "跳跃落地_通用"}
const FIGHT_ANIM = {"stand": "战斗站立_%s", "run": "战斗奔跑_%s"} # Waffenart
const FIGHT_TIME = 6.0 # s
const PLAYER_MODEL = "res://addons/PWE-Manager/ECM/angelica_player.gd"

signal picked(id: int)
signal route_finished(arrived: bool)
signal route_stuck
signal manual_move
signal camera_mode_changed(is_free: bool)

var model: Node3D # Figur aus angelica_player.gd
var anim: AnimationPlayer
var camera: Camera3D
var free_camera_enabled = false
var free_camera_active = false
var free_camera_root: Node3D
var free_camera: Camera3D
var cam_yaw: Node3D
var cam_pitch: Node3D
var arm: SpringArm3D
var height = 1.8
var target = null # Klickziel (Vector3) oder null
var state = Proto.MOVE_STAND
var input_enabled = true
var dead = false
var suffix = "空手" # Endung der Kampf-Aktionen (Waffenart)
var fighting = false
var speed_add = 0.0 # m/s aus Tempo-Effekten (stats speed_add)
var _fight_until = 0 # ms
var _once = "" # laufende Einmal-Aktion (Angriff, Treffer)
var _attack_seq = 1
var _was_moving = false
var path = PackedVector3Array() # Autoroute: Wegpunkte (x, z zählen)
var path_index = 0
var path_stop = 0.0 # m vor dem letzten Punkt anhalten
var _stuck_t = 0.0
var _stuck_from = Vector3.ZERO
var _jump = false
var _airborne = false
var _turning = false
var _last_floor = Vector3.ZERO
var _move_velocity = Vector3.ZERO
var _free_camera_velocity = Vector3.ZERO


func setup(p_model: Node3D, p_height: float) -> void:
	model = p_model
	height = p_height
	add_child(model)
	anim = model.get_node_or_null("AnimationPlayer")
	var capsule = CapsuleShape3D.new()
	capsule.radius = clampf(height * 0.18, 0.25, 0.5)
	capsule.height = height
	var cs = CollisionShape3D.new()
	cs.shape = capsule
	cs.position.y = height / 2.0
	add_child(cs)
	collision_layer = 2 # Ebene 1 = Terrain und Gebäude (Bodenstrahlen der NPCs)
	floor_snap_length = 0.6
	floor_max_angle = deg_to_rad(55)
	cam_yaw = Node3D.new()
	cam_yaw.name = "KameraDrehung"
	cam_yaw.position.y = height * 0.85
	add_child(cam_yaw)
	cam_pitch = Node3D.new()
	cam_pitch.rotation.x = -0.3
	cam_yaw.add_child(cam_pitch)
	arm = SpringArm3D.new()
	arm.spring_length = CAM_START
	arm.margin = 0.2
	arm.add_excluded_object(get_rid())
	cam_pitch.add_child(arm)
	camera = Camera3D.new()
	camera.far = 2000.0
	camera.fov = 60.0
	arm.add_child(camera)
	camera.current = true
	free_camera_root = Node3D.new()
	free_camera_root.name = "Свободная камера"
	get_parent().add_child(free_camera_root)
	free_camera = Camera3D.new()
	free_camera.far = 2000.0
	free_camera.fov = camera.fov
	free_camera_root.add_child(free_camera)
	_play("stand")

func _process(delta: float) -> void:
	if not free_camera_active or free_camera == null or not is_instance_valid(free_camera_root):
		return
	var input = Vector3(_axis_signed(KEY_D, KEY_A), _axis_signed(KEY_SPACE, KEY_Q), _axis_signed(KEY_W, KEY_S))
	var basis = free_camera_root.global_basis
	var direction = basis.x * input.x + Vector3.UP * input.y - basis.z * input.z
	var boost = Input.is_physical_key_pressed(KEY_SHIFT)
	var speed = FREE_CAMERA_BOOST if boost else FREE_CAMERA_SPEED
	var desired = direction.normalized() * speed if direction.length_squared() > 0.0 else Vector3.ZERO
	_free_camera_velocity = _free_camera_velocity.move_toward(desired, FREE_CAMERA_ACCELERATION * delta)
	free_camera_root.global_position += _free_camera_velocity * delta

func _set_free_camera(enabled: bool) -> void:
	if not free_camera_enabled or enabled == free_camera_active or free_camera == null:
		return
	free_camera_active = enabled
	if enabled:
		free_camera_root.global_position = camera.global_position
		free_camera_root.global_rotation.y = cam_yaw.global_rotation.y
		free_camera.rotation.x = cam_pitch.global_rotation.x
		camera.current = false
		free_camera.current = true
		visible = false
		set_physics_process(false)
	else:
		free_camera.current = false
		camera.current = true
		visible = true
		set_physics_process(true)
		_free_camera_velocity = Vector3.ZERO
	camera_mode_changed.emit(free_camera_active)

# -> gespielte Aktion (für die Angriffs-Effekte)
func play_attack() -> String:
	var act = "普通攻击%d_%s" % [_attack_seq, suffix]
	_attack_seq = randi() % 3 + 1
	if anim == null or not anim.has_animation(act):
		act = "普通攻击1_空手"
	_play_once(act)
	return act

# Aktion einer Fertigkeit einmal abspielen -> Länge s (0 = Figur hat sie nicht)
func play_skill(act: String) -> float:
	if anim == null or act == "" or not anim.has_animation(act) or dead:
		return 0.0
	anim.play(act, 0.1)
	_once = act
	return anim.get_animation(act).length

# Laufende Einmal-Aktion beenden (Zaubern abgebrochen)
func stop_once() -> void:
	_once = ""
	_animate()

func play_hurt() -> void:
	if state == Proto.MOVE_STAND and _once == "" and not dead:
		_play_once("受伤_通用")

func die() -> void:
	dead = true
	stop_route(false)
	target = null
	_once = ""
	if anim != null and anim.has_animation("死亡_通用"):
		anim.play("死亡_通用", 0.1)
		if anim.has_animation("死亡循环_通用"):
			anim.queue("死亡循环_通用")

func revive() -> void:
	dead = false
	_once = ""
	set_fighting(false)
	_play("stand")

# Angriff / Treffer: FIGHT_TIME s im Kampf
func mark_fight() -> void:
	_fight_until = Time.get_ticks_msec() + int(FIGHT_TIME * 1000.0)
	if not fighting:
		set_fighting(true)

func set_fighting(on: bool) -> void:
	fighting = on
	load(PLAYER_MODEL).place_weapons(model, on)
	if not dead and _once == "":
		_animate()

func _play_once(act: String) -> void:
	if anim != null and anim.has_animation(act) and not dead:
		anim.play(act, 0.1)
		_once = act

# Zu einem Punkt drehen (Sammeln)
func face(p: Vector3) -> void:
	var d = p - global_position
	if model != null and Vector2(d.x, d.z).length() > 0.05:
		model.rotation.y = atan2(d.x, d.z)

# Neues Modell (andere Ausrüstung): Richtung und laufende Animation bleiben
func replace_model(p_model: Node3D) -> void:
	var dir = direction()
	var act = anim.current_animation if anim != null else ""
	if model != null:
		model.queue_free()
	model = p_model
	add_child(model)
	model.rotation.y = dir
	anim = model.get_node_or_null("AnimationPlayer")
	load(PLAYER_MODEL).place_weapons(model, fighting)
	if anim != null and act != "" and anim.has_animation(act):
		anim.play(act)

# Weg der Wegfindung ablaufen (stop_dist m vor dem Ende anhalten)
func follow_path(points: PackedVector3Array, stop_dist: float = 0.0) -> void:
	path = points
	path_stop = stop_dist
	path_index = 0
	# Punkte überspringen, die schon erreicht sind
	while path_index < path.size() - 1 and _flat(path[path_index]) < WAYPOINT_REACHED:
		path_index += 1
	target = path[path_index] if not path.is_empty() else null
	_stuck_t = 0.0
	_stuck_from = global_position

func following() -> bool:
	return not path.is_empty()

func stop_route(arrived: bool) -> void:
	if path.is_empty():
		return
	path = PackedVector3Array()
	target = null
	route_finished.emit(arrived)

func _flat(p: Vector3) -> float:
	return Vector2(p.x - global_position.x, p.z - global_position.z).length()

# Wegpunkt erreicht? Ende? Steckt die Figur fest?
func _follow(delta: float) -> void:
	var last = path_index == path.size() - 1
	var d = _flat(path[path_index])
	if last and d <= maxf(ARRIVE, path_stop):
		stop_route(true)
		return
	if not last and d < WAYPOINT_REACHED:
		path_index += 1
		target = path[path_index]
	_stuck_t += delta
	if _stuck_t >= ROUTE_STUCK_TIME:
		var moved = Vector2(global_position.x - _stuck_from.x, global_position.z - _stuck_from.z).length()
		_stuck_t = 0.0
		_stuck_from = global_position
		if moved < ROUTE_STUCK_MOVE:
			route_stuck.emit()

# Server setzt die Figur zurück (pos_correct) oder an den Start
func place(pos: Vector3, dir: float) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	stop_route(false)
	target = null
	if model != null:
		model.rotation.y = dir
	if cam_yaw != null:
		cam_yaw.rotation.y = dir + PI # Kamera hinter der Figur
	_last_floor = pos

func direction() -> float:
	return model.rotation.y if model != null else 0.0

func _physics_process(delta: float) -> void:
	if free_camera_active:
		return
	var wish = Vector2.ZERO
	if input_enabled:
		wish.x = _axis(KEY_D, KEY_RIGHT) - _axis(KEY_A, KEY_LEFT)
		wish.y = _axis(KEY_S, KEY_DOWN) - _axis(KEY_W, KEY_UP)
	var yaw = cam_yaw.global_rotation.y
	var forward = Vector3(-sin(yaw), 0, -cos(yaw))
	var right = Vector3(cos(yaw), 0, -sin(yaw))
	var move = Vector3.ZERO
	if wish != Vector2.ZERO:
		stop_route(false)
		target = null
		move = forward * -wish.y + right * wish.x
		if not _was_moving:
			manual_move.emit()
	elif not path.is_empty():
		_follow(delta)
	_was_moving = wish != Vector2.ZERO
	if wish == Vector2.ZERO and target != null:
		var to: Vector3 = target - global_position
		to.y = 0
		if to.length() < ARRIVE and path.is_empty():
			target = null
		elif to.length() >= 0.05:
			move = to
	var sprinting = input_enabled and (Input.is_physical_key_pressed(KEY_SHIFT) or not path.is_empty() or target != null)
	var walking = not sprinting
	var speed = maxf(0.5, (LOCAL_SPRINT_SPEED if sprinting else LOCAL_WALK_SPEED) + speed_add)
	var desired_move = move.normalized() * speed if move != Vector3.ZERO else Vector3.ZERO
	_move_velocity = _move_velocity.move_toward(desired_move, LOCAL_ACCELERATION * delta)
	if _move_velocity.length_squared() > 0.01:
		model.rotation.y = lerp_angle(model.rotation.y, atan2(_move_velocity.x, _move_velocity.z), clampf(TURN_RATE * delta, 0.0, 1.0))
	velocity.x = _move_velocity.x
	velocity.z = _move_velocity.z
	if is_on_floor():
		_last_floor = global_position
		if _jump:
			velocity.y = JUMP_SPEED
			_airborne = true
			_play("jump_start")
	else:
		velocity.y -= GRAVITY * delta
	_jump = false
	var was_air = _airborne
	move_and_slide()
	if global_position.y < -500.0: # durch die Welt gefallen
		place(_last_floor + Vector3(0, 1, 0), direction())
	var flat = Vector2(velocity.x, velocity.z).length()
	if is_on_floor():
		if was_air and velocity.y <= 0.0:
			_airborne = false
			_play("land")
		state = Proto.MOVE_STAND if flat < 0.1 else (Proto.MOVE_WALK if walking else Proto.MOVE_RUN)
	else:
		_airborne = true
		state = Proto.MOVE_JUMP
	if fighting and Time.get_ticks_msec() > _fight_until and not dead:
		set_fighting(false)
	_animate()

func _animate() -> void:
	if anim == null or dead:
		return
	if _once != "":
		if anim.current_animation == _once and anim.is_playing() and state == Proto.MOVE_STAND:
			return
		_once = ""
	var current = anim.current_animation
	if state == Proto.MOVE_JUMP:
		if current != ANIM["jump_start"] or not anim.is_playing():
			_play("jump_loop")
	elif current == ANIM["land"] and anim.is_playing() and state == Proto.MOVE_STAND:
		return
	else:
		_play({Proto.MOVE_STAND: "stand", Proto.MOVE_WALK: "walk", Proto.MOVE_RUN: "run"}[state])

func _play(key: String) -> void:
	var a = _anim_name(key)
	if anim == null or not anim.has_animation(a):
		return
	if anim.current_animation != a:
		anim.play(a, 0.15)

# Aktion zu einem Zustand, im Kampf die der Waffenart (falls die Figur sie hat)
func _anim_name(key: String) -> String:
	if fighting and FIGHT_ANIM.has(key) and anim != null and anim.has_animation(FIGHT_ANIM[key] % suffix):
		return FIGHT_ANIM[key] % suffix
	return ANIM[key]

func _axis(a: Key, b: Key) -> float:
	return 1.0 if Input.is_physical_key_pressed(a) or Input.is_physical_key_pressed(b) else 0.0

func _axis_signed(positive: Key, negative: Key) -> float:
	return float(Input.is_physical_key_pressed(positive)) - float(Input.is_physical_key_pressed(negative))

func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	var k = event as InputEventKey
	if k != null and k.pressed and not k.echo:
		if k.physical_keycode == KEY_F and free_camera_enabled:
			_set_free_camera(not free_camera_active)
			get_viewport().set_input_as_handled()
			return
		if k.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			_turning = false
			get_viewport().set_input_as_handled()
			return
	var mb = event as InputEventMouseButton
	if mb != null:
		if free_camera_active:
			if mb.button_index == MOUSE_BUTTON_RIGHT:
				_turning = mb.pressed
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_turning = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			arm.spring_length = maxf(CAM_MIN, arm.spring_length * 0.9)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			arm.spring_length = minf(CAM_MAX, arm.spring_length * 1.1)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_click_move(mb.position)
		return
	var mm = event as InputEventMouseMotion
	if mm != null and free_camera_active and _turning:
		free_camera_root.rotation.y -= mm.relative.x * MOUSE_TURN
		free_camera.rotation.x = clampf(free_camera.rotation.x - mm.relative.y * MOUSE_TURN, PITCH_MIN, PITCH_MAX)
		return
	if mm != null and _turning:
		cam_yaw.rotation.y -= mm.relative.x * MOUSE_TURN
		cam_pitch.rotation.x = clampf(cam_pitch.rotation.x - mm.relative.y * MOUSE_TURN, PITCH_MIN, PITCH_MAX)
		return
	if k != null and k.pressed and not k.echo and k.physical_keycode == KEY_SPACE and not free_camera_active:
		_jump = true

# Linksklick: Figur unter dem Mauszeiger auswählen, sonst den Boden als Ziel
func _click_move(screen: Vector2) -> void:
	var from = camera.project_ray_origin(screen)
	var to = from + camera.project_ray_normal(screen) * 500.0
	var pq = PhysicsRayQueryParameters3D.create(from, to, PICK_LAYER)
	pq.collide_with_areas = true
	pq.collide_with_bodies = false
	var pick = get_world_3d().direct_space_state.intersect_ray(pq)
	if not pick.is_empty() and pick["collider"].has_meta("pick_id"):
		# nur wenn kein Gebäude / Boden davor liegt
		var wq = PhysicsRayQueryParameters3D.create(from, pick["position"], 1)
		if get_world_3d().direct_space_state.intersect_ray(wq).is_empty():
			picked.emit(int(pick["collider"].get_meta("pick_id")))
			return
	var q = PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit = get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		stop_route(false)
		target = hit["position"]
		manual_move.emit()
