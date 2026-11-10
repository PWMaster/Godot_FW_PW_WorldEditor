extends SceneTree

const PLUGIN = "res://addons/PWE-Manager/"
const OUTPUT = PLUGIN + "Server/PW155/"
const Elements = preload("../../Data/angelica_elements.gd")
const IMPORT_FILE = PLUGIN + "Server/pw_server_import.json"
const ROLE_CLASSES = [{"class": 1, "race": 1, "section": "SWORDSMAN", "genders": [0, 1]}, {"class": 2, "race": 1, "section": "MAGE", "genders": [0, 1]},
	{"class": 3, "race": 4, "section": "NEC", "genders": [0, 1]}, {"class": 4, "race": 3, "section": "HAG", "genders": [1]},
	{"class": 5, "race": 3, "section": "ORGE", "genders": [0]}, {"class": 6, "race": 4, "section": "ASN", "genders": [0, 1]},
	{"class": 7, "race": 2, "section": "ARCHER", "genders": [0, 1]}, {"class": 8, "race": 2, "section": "ANGEL", "genders": [0, 1]},
	{"class": 9, "race": 5, "section": "BLADE", "genders": [0, 1]}, {"class": 10, "race": 5, "section": "GENIE", "genders": [0, 1]},
	{"class": 11, "race": 6, "section": "SHADOW", "genders": [0, 1]}, {"class": 12, "race": 6, "section": "FAIRY", "genders": [0, 1]}]

func _initialize() -> void:
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(IMPORT_FILE)) if FileAccess.file_exists(IMPORT_FILE) else {}
	if not manifest is Dictionary:
		print("Ошибка: сначала выберите сервер PW и сохраните профиль импорта")
		quit(1)
		return
	var config_root = str(manifest.get("config_root", ""))
	var server_root = str(manifest.get("server_root", ""))
	var elements_path = config_root.path_join("elements.data")
	var ptemplate_path = server_root.path_join("gamed/ptemplate.conf")
	var source = Elements.new()
	var err: String = source.open(elements_path)
	if err != "":
		print("Ошибка чтения PW elements.data: ", err)
		quit(1)
		return
	var player_configs = _read_player_templates(ptemplate_path)
	if player_configs.get("SWORDSMAN", {}).is_empty():
		print("Ошибка чтения секции SWORDSMAN в серверном ptemplate.conf: ", ptemplate_path)
		quit(1)
		return
	var roles = []
	var class_templates = {}
	for role_class in ROLE_CLASSES:
		var section = str(role_class["section"])
		if not player_configs.has(section) or player_configs[section].is_empty():
			continue
		var stats = _player_stats(player_configs[section])
		stats["name"] = "PW " + section
		class_templates[str(role_class["class"])] = stats
		for gender in role_class["genders"]:
			roles.append({"race": role_class["race"], "class": role_class["class"], "gender": gender, "level": 1, "hp": int(stats.hp), "mp": int(stats.mp), "money": 0,
				"world": 0, "map": "world", "pos": [0.0, 4.0, 0.0], "town_world": 0, "town_pos": [0.0, 4.0, 0.0], "items": [], "equipment": [], "skills_raw": ""})
	if roles.is_empty():
		print("Ошибка: в ptemplate.conf не найдено ни одной поддерживаемой стартовой роли")
		quit(1)
		return
	var item_templates = _item_templates(source)
	var class_data = {"source": "%s: ptemplate.conf + elements.data 0x%08X" % [ptemplate_path.get_file(), source.version],
		"classes": class_templates, "level_exp": [], "hp_mp_modify": []}
	var role_templates = {"source": "%s: ptemplate.conf + elements.data 0x%08X" % [ptemplate_path.get_file(), source.version], "roles": roles}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var ok = _write_json(OUTPUT + "start_roles.json", role_templates) and _write_json(OUTPUT + "class_templates.json", class_data)
	ok = ok and _write_json(OUTPUT + "item_templates.json", item_templates)
	source.close()
	if not ok:
		print("Ошибка записи JSON-шаблонов в addons/PWE-Manager/Server")
		quit(1)
		return
	print("PW 155 готов: %d стартовых ролей, %d классовых шаблонов, %d шаблонов предметов; профиль Server/PW155, карта входа — world" % [roles.size(), class_templates.size(), item_templates.items.size()])
	quit(0)

func _read_player_templates(path: String) -> Dictionary:
	var bytes = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()
	var text = bytes.get_string_from_ascii()
	var section = ""
	var sections = {}
	for line in text.replace("\r", "").split("\n"):
		var value = line.strip_edges()
		if value.begins_with("[") and value.ends_with("]"):
			section = value.substr(1, value.length() - 2).strip_edges().to_upper()
			sections[section] = {}
		elif sections.has(section) and not value.is_empty() and not value.begins_with("#") and not value.begins_with(";"):
			var equals = value.find("=")
			if equals > 0:
				sections[section][value.substr(0, equals).strip_edges().to_lower()] = value.substr(equals + 1).strip_edges().to_float()
	return sections

func _player_stats(config: Dictionary) -> Dictionary:
	return {"name": "PW Swordman", "require_level": 1, "hp": int(config.get("hp", 60)), "mp": int(config.get("mp", 20)),
		"lvlup_hp": int(config.get("lvlup_hp", 5)), "lvlup_mp": int(config.get("lvlup_mp", 3)), "walk": float(config.get("walk_speed", 1.5)),
		"run": float(config.get("run_speed", 3.0)), "attack_range": float(config.get("attack_range", 1.4)),
		"dmg": int(config.get("strength", 15)), "defense": int(config.get("vitality", 20)), "attack": int(config.get("agility", 10)),
		"armor": int(config.get("agility", 10)), "crit_rate": float(config.get("crit_rate", 6.0)), "crit_damage": 150.0,
		"anti_crit_rate": 0.0, "anti_crit_damage": 0.0}

func _item_templates(elements) -> Dictionary:
	var items = {}
	for list in elements.lists:
		if list.space != "essence":
			continue
		var fields: Array = elements._fields(list.type)
		var has_pile = fields.any(func(field): return field[0] == "pile_num_max")
		if not has_pile:
			continue
		for row in list.count:
			var item: Dictionary = elements.record(list.index, row)
			var id = int(item.get("id", 0))
			if id <= 0:
				continue
			var pile = int(item.get("pile_num_max", 1))
			items[str(id)] = {"pile": maxi(1, pile), "type": list.type}
	return {"source": "server elements.data 0x%08X" % elements.version, "note": "Импорт PW: стаки предметов из серверных таблиц", "items": items, "mines": {}}

func _write_json(path: String, data: Dictionary) -> bool:
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t") + "\n")
	file.close()
	return true
