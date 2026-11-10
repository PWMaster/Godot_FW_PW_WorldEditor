extends Node3D

const LOAD_RADIUS = 1
const KEEP_RADIUS = 2
const UPDATE_INTERVAL = 0.25

var terrain_root: Node3D
var buildings_root: Node3D
var objects_root: Node3D
var target: Node3D
var terrain_dir = ""
var area_count = 0
var area_columns = 0
var grid_size = 1.0
var mask_grid = 1
var map_width = 1.0
var map_length = 1.0
var _timer = 0.0
var _requested = {}
var _loaded = {}
var _failed_areas = {}
var _building_indices = {}
var _loaded_buildings = {}
var _loading_objects = {}
var _loaded_objects = {}
var _runtime_importer
var _building_importer
var _terrain_parser
var _building_parser
var _runtime_world
var _map_data = {}
var _layer_array: Texture2DArray
var _source_trn2 = ""
var _source_tasks = {}
var _runtime_ready = false
var _building_manifest_ready = false
var _building_paths_by_area = {}

func _ready() -> void:
	terrain_root = get_node_or_null("Terrain")
	buildings_root = get_node_or_null("Buildings")
	objects_root = get_node_or_null("Objects")
	terrain_dir = str(get_meta("terrain_dir", ""))
	area_count = int(get_meta("terrain_area_count", 0))
	area_columns = int(get_meta("terrain_area_columns", 0))
	grid_size = float(get_meta("terrain_grid_size", 1.0))
	mask_grid = int(get_meta("terrain_mask_grid", 1))
	map_width = float(get_meta("terrain_width", 1.0))
	map_length = float(get_meta("terrain_length", 1.0))
	for index in get_meta("building_chunk_indices", PackedInt32Array()):
		_building_indices[int(index)] = true
	_source_trn2 = str(get_meta("source_trn2", ""))
	_building_manifest_ready = _source_trn2 == ""

func configure_runtime(data_root: String) -> bool:
	if _source_trn2 == "":
		return false
	_runtime_importer = preload("../../addons/PWE-Manager/ECM/ecm_importer.gd").new(data_root)
	_runtime_importer.runtime = true
	_runtime_importer._enter(_source_trn2)
	_terrain_parser = preload("../../addons/PWE-Manager/MAP/angelica_terrain.gd").new(_runtime_importer)
	_map_data = _terrain_parser.read_trn2(_source_trn2)
	if _map_data.has("error"):
		_runtime_importer._leave()
		_runtime_importer = null
		return false
	var world_reader = preload("../../addons/PWE-Manager/MAP/angelica_world.gd").new(preload("../../addons/PWE-Manager/ECM/ecm_importer.gd").new(data_root))
	var world_thread = Thread.new()
	if world_thread.start(Callable(world_reader, "building_files").bind(_source_trn2)) != OK:
		_runtime_importer._leave()
		_runtime_importer = null
		return false
	_layer_array = await _terrain_parser.build_layer_texture_array_async(_map_data)
	_runtime_ready = _layer_array != null
	while world_thread.is_alive():
		await get_tree().process_frame
	var wanted_paths: Variant = world_thread.wait_to_finish()
	if _runtime_ready:
		var world_parser = preload("../../addons/PWE-Manager/MAP/angelica_world.gd").new(_runtime_importer)
		world_parser._world = world_reader._world
		_runtime_world = world_parser
		if not world_parser._world.is_empty() and not world_parser._world.has("error"):
			world_parser._build_light(world_parser._world, self)
			await world_parser.build_runtime_manifest(area_columns, ceili(float(area_count) / area_columns), float(mask_grid) * grid_size, map_width, map_length)
		if wanted_paths is Array and not wanted_paths.is_empty():
			_building_importer = preload("../../addons/PWE-Manager/ECM/ecm_importer.gd").new(data_root)
			_building_importer.runtime = true
			_building_parser = preload("../../addons/PWE-Manager/MAP/angelica_buildings.gd").new(_building_importer)
			var cell_size = float(mask_grid) * grid_size
			var rows = ceili(float(area_count) / area_columns)
			_start_source_task("building_manifest", Callable(_building_parser, "runtime_manifest_for_map").bind(_source_trn2.get_file().get_basename(), wanted_paths, area_columns, rows, cell_size, map_width, map_length), "building_manifest", -1)
		else:
			_building_manifest_ready = true
	return _runtime_ready

func set_stream_target(node: Node3D) -> void:
	target = node
	_update_streaming()

func wait_for_initial_areas() -> bool:
	var start = Time.get_ticks_msec()
	while _loaded.is_empty() and (not _requested.is_empty() or not _source_tasks.is_empty()) and Time.get_ticks_msec() - start < 10000:
		await get_tree().process_frame
	return not _loaded.is_empty()

func _process(delta: float) -> void:
	if not is_instance_valid(target):
		return
	_timer += delta
	if _timer < UPDATE_INTERVAL:
		return
	_timer = 0.0
	_update_streaming()
	_poll_source_tasks()

func _update_streaming() -> void:
	if terrain_root == null or not is_instance_valid(target) or area_columns <= 0 or grid_size <= 0.0:
		return
	if _source_trn2 != "" and not _runtime_ready:
		return
	var cell_size = float(mask_grid) * grid_size
	var center_col = clampi(int(floor((target.global_position.x + map_width * 0.5) / cell_size)), 0, area_columns - 1)
	var center_row = clampi(int(floor((map_length * 0.5 - target.global_position.z) / cell_size)), 0, ceili(float(area_count) / area_columns) - 1)
	var center_index = center_row * area_columns + center_col
	if not _loaded.has(center_index) and not _requested.has("terrain:%d" % center_index):
		_request_area(center_index)
	_request_nearby_buildings(center_index)
	_request_runtime_objects(center_index)
	for row in range(maxi(0, center_row - KEEP_RADIUS), mini(ceili(float(area_count) / area_columns), center_row + KEEP_RADIUS + 1)):
		for col in range(maxi(0, center_col - KEEP_RADIUS), mini(area_columns, center_col + KEEP_RADIUS + 1)):
			var index = row * area_columns + col
			if index >= area_count:
				continue
			if abs(row - center_row) <= LOAD_RADIUS and abs(col - center_col) <= LOAD_RADIUS:
				if not _loaded.has(index) and not _requested.has("terrain:%d" % index):
					_request_area(index)
				_request_nearby_buildings(index)
				_request_runtime_objects(index)
	for index in _loaded.keys():
		var row = int(index) / area_columns
		var col = int(index) % area_columns
		if abs(row - center_row) > KEEP_RADIUS or abs(col - center_col) > KEEP_RADIUS:
			_unload_area(int(index))
	for index in _loaded_buildings.keys():
		var row = int(index) / area_columns
		var col = int(index) % area_columns
		if abs(row - center_row) > KEEP_RADIUS or abs(col - center_col) > KEEP_RADIUS:
			_unload_building_chunk(int(index))
	for index in _loaded_objects.keys():
		var row = int(index) / area_columns
		var col = int(index) % area_columns
		if abs(row - center_row) > KEEP_RADIUS or abs(col - center_col) > KEEP_RADIUS:
			_unload_runtime_objects(int(index))
	_poll_requests()

func _request_area(index: int) -> void:
	if _failed_areas.has(index):
		return
	if _source_trn2 != "":
		if _source_tasks.size() >= 2:
			return
		if _start_source_task("terrain:%d" % index, Callable(_terrain_parser, "read_area_data").bind(_source_trn2, _map_data, index), "terrain", index):
			_requested["terrain:%d" % index] = {"kind": "task", "index": index}
		return
	var path = terrain_dir.path_join("terrain/area_%03d.res" % index)
	if not ResourceLoader.exists(path):
		return
	var err = ResourceLoader.load_threaded_request(path, "Mesh")
	if err == OK or err == ERR_BUSY:
		_requested["terrain:%d" % index] = {"path": path, "kind": "terrain", "index": index}

func _poll_source_tasks() -> void:
	for task_key in _source_tasks.keys():
		var task_info: Dictionary = _source_tasks[task_key]
		var thread: Thread = task_info["thread"]
		if thread.is_alive():
			continue
		var index = int(task_info["index"])
		var data = thread.wait_to_finish()
		_source_tasks.erase(task_key)
		if task_info["kind"] == "building_manifest":
			_building_paths_by_area = data if data is Dictionary else {}
			for building_index in _building_paths_by_area:
				_building_indices[int(building_index)] = true
			_building_manifest_ready = true
			if _building_paths_by_area.is_empty():
				push_warning("PW: манифест зданий карты пуст; проверьте .ecwld/.ecbsd и litmodels/<имя карты>")
		elif task_info["kind"] == "terrain":
			_requested.erase("terrain:%d" % index)
			if not data is Dictionary or data.has("error"):
				_failed_areas[index] = true
				continue
			var mesh = _terrain_parser.build_area_from_data(_map_data, data if data is Dictionary else {}, _layer_array)
			if mesh != null:
				_attach_terrain_area(index, mesh)
			else:
				_failed_areas[index] = true
		elif data is Array:
			_requested.erase("building:%d" % index)
			if data.is_empty():
				push_warning("PW: для области %d не удалось загрузить модели зданий" % index)
			_attach_runtime_buildings(index, data)

func _request_nearby_buildings(index: int) -> void:
	if _building_manifest_ready and _building_indices.has(index) and not _loaded_buildings.has(index) and not _requested.has("building:%d" % index):
		if _source_trn2 != "":
			if _source_tasks.size() >= 3:
				return
			if _start_source_task("building:%d" % index, Callable(_building_parser, "read_runtime_chunk").bind(_building_paths_by_area[index]), "buildings", index):
				_requested["building:%d" % index] = {"kind": "task", "index": index}
		else:
			_request_building_chunk(index)

func _request_runtime_objects(index: int) -> void:
	if _source_trn2 == "" or _runtime_world == null or _loaded_objects.has(index) or _loading_objects.has(index):
		return
	if not _runtime_world._runtime_chunks.has(index):
		_loaded_objects[index] = null
		return
	_loading_objects[index] = true
	call_deferred("_load_runtime_objects", index)

func _load_runtime_objects(index: int) -> void:
	var row = int(index) / area_columns
	var col = int(index) % area_columns
	var cell_size = float(mask_grid) * grid_size
	var root = Node3D.new()
	root.name = "Мир_%05d" % index
	objects_root.add_child(root)
	await _runtime_world.build_runtime_chunk(index, root)
	_loading_objects.erase(index)
	if not is_instance_valid(target):
		root.queue_free()
		return
	var center_col = clampi(int(floor((target.global_position.x + map_width * 0.5) / cell_size)), 0, area_columns - 1)
	var center_row = clampi(int(floor((map_length * 0.5 - target.global_position.z) / cell_size)), 0, ceili(float(area_count) / area_columns) - 1)
	if abs(row - center_row) > KEEP_RADIUS or abs(col - center_col) > KEEP_RADIUS:
		root.queue_free()
		return
	_loaded_objects[index] = root

func _unload_runtime_objects(index: int) -> void:
	var node = _loaded_objects.get(index)
	if is_instance_valid(node):
		node.queue_free()
	_loaded_objects.erase(index)

func _request_building_chunk(index: int) -> void:
	var path = terrain_dir.path_join("buildings/chunk_%05d.scn" % index)
	if not ResourceLoader.exists(path):
		return
	var err = ResourceLoader.load_threaded_request(path, "PackedScene")
	if err == OK or err == ERR_BUSY:
		_requested["building:%d" % index] = {"path": path, "kind": "building", "index": index}

func _attach_runtime_buildings(index: int, models: Array) -> void:
	var group_root = Node3D.new()
	group_root.name = "Здания_%05d" % index
	buildings_root.add_child(group_root)
	_loaded_buildings[index] = group_root
	for i in models.size():
		var data: Dictionary = models[i]
		var model: Dictionary = data["model"]
		var mesh = _building_parser._mesh(model)
		if mesh == null:
			continue
		var instance = MeshInstance3D.new()
		instance.name = data["path"].get_file().get_basename()
		instance.mesh = mesh
		instance.transform = _building_parser._transform(model)
		group_root.add_child(instance)
		if i % 2 == 1:
			await get_tree().process_frame

func _poll_requests() -> void:
	for key in _requested.keys():
		var request: Dictionary = _requested[key]
		if request.get("kind", "") == "task":
			continue
		var path: String = request["path"]
		var status = ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_requested.erase(key)
		if status != ResourceLoader.THREAD_LOAD_LOADED:
			continue
		if not is_instance_valid(target):
			continue
		var index = int(request["index"])
		if request["kind"] == "terrain":
			var mesh = ResourceLoader.load_threaded_get(path) as Mesh
			if mesh == null:
				continue
			_attach_terrain_area(index, mesh)
		else:
			var packed = ResourceLoader.load_threaded_get(path) as PackedScene
			if packed == null:
				continue
			var instance = packed.instantiate()
			buildings_root.add_child(instance)
			_loaded_buildings[index] = instance

func _attach_terrain_area(index: int, mesh: Mesh) -> void:
	var instance = MeshInstance3D.new()
	instance.name = "Area_%03d" % index
	instance.mesh = mesh
	terrain_root.add_child(instance)
	var body = StaticBody3D.new()
	body.name = "Коллизия_%03d" % index
	var collision = CollisionShape3D.new()
	collision.shape = mesh.create_trimesh_shape()
	if collision.shape != null:
		body.add_child(collision)
		add_child(body)
	_loaded[index] = {"mesh": instance, "body": body}

func _exit_tree() -> void:
	for task_info in _source_tasks.values():
		var thread: Thread = task_info["thread"]
		thread.wait_to_finish()
	_source_tasks.clear()
	if _runtime_importer != null:
		_runtime_importer._leave()

func _start_source_task(key: String, action: Callable, kind: String, index: int) -> bool:
	if _source_tasks.has(key):
		return false
	var thread = Thread.new()
	var err = thread.start(action)
	if err != OK:
		return false
	_source_tasks[key] = {"thread": thread, "kind": kind, "index": index}
	return true

func _unload_area(index: int) -> void:
	var entry: Dictionary = _loaded.get(index, {})
	for key in ["mesh", "body"]:
		var node = entry.get(key)
		if is_instance_valid(node):
			node.queue_free()
	_loaded.erase(index)

func _unload_building_chunk(index: int) -> void:
	var node = _loaded_buildings.get(index)
	if is_instance_valid(node):
		node.queue_free()
	_loaded_buildings.erase(index)
