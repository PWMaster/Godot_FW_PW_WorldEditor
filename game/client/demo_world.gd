extends Node3D

const WALK_SPEED = 7.0
const JUMP_SPEED = 6.0
const GRAVITY = 18.0

var _player: CharacterBody3D
var _camera_yaw = 0.0
var _camera_pitch = -0.28
var _camera: Camera3D


func _ready() -> void:
	_build_scene()
	set_process_unhandled_input(true)

func _build_scene() -> void:
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.38, 0.58, 0.78)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.74, 0.78)
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -28, 0)
	sun.shadow_enabled = true
	add_child(sun)
	_make_box("Земля", Vector3(0, -0.5, 0), Vector3(120, 1, 120), Color(0.22, 0.42, 0.24), true)
	_make_box("Площадка", Vector3(0, 0.08, 0), Vector3(14, 0.16, 14), Color(0.47, 0.43, 0.35), false)
	for i in 12:
		var angle = TAU * float(i) / 12.0
		var pos = Vector3(cos(angle) * 12.0, 1.0, sin(angle) * 12.0)
		_make_box("Столб_%02d" % i, pos, Vector3(1.2, 2.0 + float(i % 3), 1.2), Color(0.38, 0.44, 0.52), true)
	_player = CharacterBody3D.new()
	_player.name = "Персонаж"
	_player.position = Vector3(0, 1.0, 0)
	var capsule = CapsuleMesh.new()
	capsule.radius = 0.42
	capsule.height = 1.8
	var body_mesh = MeshInstance3D.new()
	body_mesh.mesh = capsule
	body_mesh.position.y = 0.9
	body_mesh.material_override = _material(Color(0.18, 0.55, 0.9))
	_player.add_child(body_mesh)
	var collision = CollisionShape3D.new()
	var shape = CapsuleShape3D.new()
	shape.radius = 0.42
	shape.height = 1.8
	collision.shape = shape
	collision.position.y = 0.9
	_player.add_child(collision)
	add_child(_player)
	var pivot = Node3D.new()
	pivot.name = "Поворот камеры"
	pivot.position.y = 1.45
	_player.add_child(pivot)
	var camera_pivot = Node3D.new()
	camera_pivot.rotation.x = _camera_pitch
	pivot.add_child(camera_pivot)
	_camera = Camera3D.new()
	_camera.position.z = 8.0
	_camera.current = true
	camera_pivot.add_child(_camera)

func _make_box(box_name: String, pos: Vector3, dimensions: Vector3, color: Color, solid: bool) -> void:
	var root: Node3D = StaticBody3D.new() if solid else Node3D.new()
	root.name = box_name
	root.position = pos
	var mesh = BoxMesh.new()
	mesh.size = dimensions
	var visual = MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = _material(color)
	root.add_child(visual)
	if solid:
		var collision = CollisionShape3D.new()
		var shape = BoxShape3D.new()
		shape.size = dimensions
		collision.shape = shape
		root.add_child(collision)
	add_child(root)

func _material(color: Color) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	return mat

func grab_camera() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func prepare_for_networked_map() -> void:
	set_physics_process(false)
	set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _player != null:
		remove_child(_player)
		_player.queue_free()
		_player = null

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		grab_camera()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_camera_yaw -= event.relative.x * 0.003
		_camera_pitch = clampf(_camera_pitch - event.relative.y * 0.002, -0.8, 0.15)
		_camera.get_parent().rotation = Vector3(_camera_pitch, _camera_yaw, 0)

func _physics_process(delta: float) -> void:
	if _player == null:
		return
	var input_dir = Vector2.ZERO
	input_dir.x = float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
	input_dir.y = float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	input_dir = input_dir.normalized()
	var forward = Vector3(-sin(_camera_yaw), 0, -cos(_camera_yaw))
	var right = Vector3(cos(_camera_yaw), 0, -sin(_camera_yaw))
	var direction = right * input_dir.x + forward * input_dir.y
	_player.velocity.x = direction.x * WALK_SPEED
	_player.velocity.z = direction.z * WALK_SPEED
	if not _player.is_on_floor():
		_player.velocity.y -= GRAVITY * delta
	elif Input.is_key_pressed(KEY_SPACE):
		_player.velocity.y = JUMP_SPEED
	else:
		_player.velocity.y = 0.0
	_player.move_and_slide()
	if direction.length_squared() > 0.01:
		_player.rotation.y = atan2(direction.x, direction.z)
