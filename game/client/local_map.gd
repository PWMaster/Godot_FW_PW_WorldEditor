extends Node3D

const PlayerModel = preload("../../addons/PWE-Manager/ECM/angelica_player.gd")
const LocalPlayer = preload("local_player.gd")

signal loading_progress(message: String)

var map_root: Node3D
var player: LocalPlayer
var model_builder

func load_world(scene_path: String, data_root: String, race: int, gender: int, profession: int, spawn_position: Variant = null, spawn_direction: float = 0.0) -> String:
	loading_progress.emit("Подготовка данных карты…")
	if not ResourceLoader.exists(scene_path):
		return "Импортированная сцена карты не найдена: " + scene_path
	var packed = load(scene_path) as PackedScene
	if packed == null:
		return "Не удалось загрузить сцену карты: " + scene_path
	map_root = packed.instantiate()
	add_child(map_root)
	if map_root.has_method("configure_runtime") and map_root.has_meta("source_trn2"):
		loading_progress.emit("Чтение данных PW и текстур карты…")
		var configured = await map_root.configure_runtime(data_root)
		if not configured:
			return "Не удалось подготовить исходные данные карты для потоковой загрузки"
	_ensure_light()
	loading_progress.emit("Сборка модели персонажа…")
	model_builder = PlayerModel.new(data_root)
	var appearance = {"face": 0, "mask": 0, "hair": 0, "skin": 0, "hair_color": 0xEAF8FD}
	var err: String = model_builder.build(race, gender, profession, appearance)
	if err != "":
		return "Не удалось собрать персонажа из игровых данных: " + err
	var model_bounds: AABB = model_builder.bounds()
	player = LocalPlayer.new()
	player.name = "Персонаж"
	player.free_camera_enabled = true
	player.set_physics_process(false)
	add_child(player)
	player.camera_mode_changed.connect(func(is_free: bool): map_root.set_stream_target(player.free_camera if is_free else player))
	var height = maxf(1.0, model_bounds.size.y)
	player.setup(model_builder.detach(), height)
	player.model.position.y = -model_bounds.position.y
	var spawn = Vector3(0.0, 10.0, 0.0) if spawn_position == null else Vector3(float(spawn_position[0]), float(spawn_position[1]), float(spawn_position[2]))
	player.place(spawn, spawn_direction)
	if map_root.has_method("set_stream_target"):
		loading_progress.emit("Загрузка начальной области рельефа…")
		map_root.set_stream_target(player)
		var terrain_ready = await map_root.wait_for_initial_areas()
		if not terrain_ready:
			return "Не удалось загрузить начальные области рельефа карты"
		await get_tree().physics_frame
		var ground_ray = PhysicsRayQueryParameters3D.create(spawn + Vector3.UP * 10000.0, spawn - Vector3.UP * 10000.0, 1)
		ground_ray.exclude = [player.get_rid()]
		var ground_hit = get_world_3d().direct_space_state.intersect_ray(ground_ray)
		if not ground_hit.is_empty():
			spawn.y = float(ground_hit["position"].y) + 0.05
			player.place(spawn, spawn_direction)
	player.set_physics_process(true)
	return ""

func _add_terrain_collision() -> void:
	var terrain = map_root.get_node_or_null("Terrain")
	if terrain == null:
		return
	for mesh_instance in terrain.get_children():
		if mesh_instance is MeshInstance3D and mesh_instance.mesh != null:
			var shape = mesh_instance.mesh.create_trimesh_shape()
			if shape == null:
				continue
			var body = StaticBody3D.new()
			body.name = "Коллизия_" + String(mesh_instance.name)
			body.transform = mesh_instance.global_transform
			var collision = CollisionShape3D.new()
			collision.shape = shape
			body.add_child(collision)
			add_child(body)

func _ensure_light() -> void:
	if map_root.get_node_or_null("WorldEnvironment") != null or map_root.get_node_or_null("Environment") != null:
		return
	var environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.55, 0.65, 0.8)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.55, 0.55)
	var world_environment = WorldEnvironment.new()
	world_environment.name = "Environment"
	world_environment.environment = environment
	map_root.add_child(world_environment)

func close_world() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	queue_free()
