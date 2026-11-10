extends RefCounted

const CFG_FILE = "PW_1.5.5_v156.cfg"
const SUPPORTED_VERSION = 0x3000009C

var path := ""
var version := 0
var lists: Array = []
var _file: FileAccess
var _blocks: Array = []
var _ids: Dictionary = {}

func open(file_path: String) -> String:
	close()
	path = file_path
	_file = FileAccess.open(file_path, FileAccess.READ)
	if _file == null:
		return "Не удалось открыть elements.data: " + file_path
	version = _file.get_32()
	if version != SUPPORTED_VERSION:
		close()
		return "Импортёр PW поддерживает только elements.data 0x%08X (получено 0x%08X)" % [SUPPORTED_VERSION, version]
	var cfg_path = (get_script() as Script).resource_path.get_base_dir().path_join(CFG_FILE)
	if not FileAccess.file_exists(cfg_path):
		close()
		return "Не найден профиль схемы PW: " + cfg_path
	var err = _load_cfg(cfg_path)
	if err != "":
		close()
		return err
	var start_error = _scan()
	if start_error != "":
		close()
	return start_error

func close() -> void:
	_file = null
	_blocks.clear()
	lists.clear()
	_ids.clear()

func _load_cfg(cfg_path: String) -> String:
	var lines = FileAccess.get_file_as_string(cfg_path).replace("\r", "").split("\n")
	var clean: Array[String] = []
	for line in lines:
		var s = line.strip_edges()
		if not s.is_empty() and not s.begins_with("#") and not s.begins_with("//"):
			clean.append(s)
	if clean.size() < 2 or int(clean[0]) != 231:
		return "Некорректный профиль схемы PW 1.5.5 v156"
	var block_count = int(clean[0])
	var cursor = 2
	for block_index in block_count:
		if cursor + 3 >= clean.size():
			return "Профиль PW обрывается на блоке %d" % block_index
		var header = clean[cursor].split(" - ", false, 1)
		if header.size() != 2:
			return "Некорректное имя блока PW: " + clean[cursor]
		var offset_text = clean[cursor + 1].to_upper()
		var raw = clean[cursor + 2].to_upper() == "RAW"
		var names = [] if raw else clean[cursor + 2].trim_suffix(";").split(";")
		var types = [] if raw else clean[cursor + 3].trim_suffix(";").split(";")
		var fields: Array = []
		var record_size = 0
		if not raw:
			for field_index in types.size():
				var field_type: String = types[field_index].strip_edges().to_lower()
				var field_size = _field_size(field_type)
				if field_size <= 0:
					return "%s: неизвестный тип поля %s" % [header[1], field_type]
				var field_name = str(names[field_index]).strip_edges() if field_index < names.size() else "field_%d" % (field_index + 1)
				fields.append({"name": field_name.to_lower(), "source": field_name, "type": field_type, "size": field_size, "offset": record_size})
				record_size += field_size
		_blocks.append({"name": header[1].strip_edges(), "offset": offset_text, "raw": raw, "fields": fields, "size": record_size})
		cursor += 4
	if _blocks.size() != block_count:
		return "Число блоков схемы PW не совпадает с объявленным"
	return ""

func _field_size(field_type: String) -> int:
	var colon = field_type.find(":")
	if colon > 0 and field_type.substr(0, colon) in ["wstring", "string", "byte", "bytes"]:
		var size = field_type.substr(colon + 1).to_int()
		return size if size > 0 and size <= 16777216 and (not field_type.begins_with("wstring:") or size % 2 == 0) else -1
	if field_type in ["int32", "uint32", "int", "uint", "float"]:
		return 4
	if field_type in ["int16", "uint16", "short", "ushort", "word"]:
		return 2
	if field_type in ["int8", "uint8", "sbyte", "byte", "char", "bool"]:
		return 1
	if field_type in ["int64", "uint64", "long", "ulong", "double"]:
		return 8
	return -1

func _scan() -> String:
	var position: int = 4
	var file_size = _file.get_length()
	for block_index in _blocks.size():
		var block: Dictionary = _blocks[block_index]
		if block.offset == "AUTO":
			if position + 8 > file_size:
				return "Обрезанный служебный заголовок перед блоком " + block.name
			_file.seek(position)
			_file.get_32()
			var segment_size = _file.get_32()
			position += 8 + segment_size
			if block_index > 0 and block.name == "SKILLTOME_SUB_TYPE":
				position += 4
		else:
			position += int(block.offset)
		if position < 0 or position + 4 > file_size:
			return "Смещение блока %s выходит за границы elements.data" % block.name
		_file.seek(position)
		if block.raw:
			var talk_end = _skip_talk_proc()
			if talk_end < 0:
				return "Повреждён блок диалогов TALK_PROC"
			position = talk_end
			continue
		var count = _file.get_32()
		position += 4
		if count < 0 or count > 2000000 or position + int(block.size) * count > file_size:
			return "Число или размер записей блока %s некорректен (количество %d)" % [block.name, count]
		var kind = str(block.name)
		var space = "essence"
		if kind.ends_with("_ADDON") or kind.ends_with("_RAND") or kind.ends_with("_UNIQUE"):
			space = "addon"
		elif kind.ends_with("_RECIPE"):
			space = "recipe"
		elif kind.ends_with("_CONFIG"):
			space = "config"
		var list_index = lists.size()
		lists.append({"index": list_index, "type": kind, "space": space, "size": block.size, "count": count, "offset": position, "layout": "voll"})
		position += int(block.size) * count
	if position != file_size:
		return "Профиль PW обработал данные до смещения %d из %d байт" % [position, file_size]
	_file.seek(position)
	return ""

func _skip_talk_proc() -> int:
	var size = _file.get_length()
	if _file.get_position() + 4 > size:
		return -1
	var talks = _file.get_32()
	if talks < 0 or talks > 1000000:
		return -1
	for _talk in talks:
		if _file.get_position() + 132 > size:
			return -1
		_file.seek(_file.get_position() + 132)
		var windows = _file.get_32()
		if windows < 0 or windows > 100000:
			return -1
		for _window in windows:
			if _file.get_position() + 12 > size:
				return -1
			_file.seek(_file.get_position() + 8)
			var chars = _file.get_32()
			if chars < 0 or chars > 1000000 or _file.get_position() + chars * 2 + 4 > size:
				return -1
			_file.seek(_file.get_position() + chars * 2)
			var choices = _file.get_32()
			if choices < 0 or choices > 100000 or _file.get_position() + choices * 136 > size:
				return -1
			_file.seek(_file.get_position() + choices * 136)
	return _file.get_position()

func list_of(type: String) -> int:
	for list in lists:
		if list.type == type:
			return list.index
	return -1

func find(id: int, space: String = "essence") -> Array:
	if not _ids.has(space):
		_index(space)
	return _ids[space].get(id, [])

func _index(space: String) -> void:
	var ids = {}
	for list in lists:
		if list.space != space:
			continue
		var fields = _fields(list.type)
		if fields.is_empty() or fields[0][0] != "id":
			continue
		for row in list.count:
			_file.seek(list.offset + row * list.size)
			var id = _file.get_32()
			if not ids.has(id):
				ids[id] = [list.index, row]
	_ids[space] = ids

func type_of(id: int, space: String = "essence") -> String:
	var at = find(id, space)
	return lists[at[0]].type if not at.is_empty() else ""

func name_of(id: int, space: String = "essence") -> String:
	var at = find(id, space)
	return record_name(at[0], at[1]) if not at.is_empty() else ""

func get_record(id: int, space: String = "essence") -> Dictionary:
	var at = find(id, space)
	return record(at[0], at[1]) if not at.is_empty() else {}

func _fields(type: String) -> Array:
	for index in _blocks.size():
		if _blocks[index].name == type:
			var result: Array = []
			for field in _blocks[index].fields:
				result.append([field.name, _schema_type(field.type), field.offset, []])
			return result
	return []

func _schema_type(field_type: String) -> String:
	if field_type.begins_with("wstring:"):
		return "wchar"
	if field_type.begins_with("string:"):
		return "string"
	if field_type in ["float", "double"]:
		return "f32" if field_type == "float" else "f64"
	if field_type.begins_with("uint") or field_type in ["uint", "word", "ushort", "byte", "char"]:
		return "u%d" % (_field_size(field_type) * 8)
	return "i%d" % (_field_size(field_type) * 8)

func record(list_index: int, row: int) -> Dictionary:
	if list_index < 0 or list_index >= lists.size():
		return {}
	var list: Dictionary = lists[list_index]
	if row < 0 or row >= list.count:
		return {}
	var block: Dictionary = _block_by_name(list.type)
	_file.seek(list.offset + row * list.size)
	var raw = _file.get_buffer(list.size)
	var out = {}
	for field in block.fields:
		out[field.name] = _decode_field(raw, field)
	out["_type"] = list.type
	out["_layout"] = "voll"
	return out

func record_name(list_index: int, row: int) -> String:
	var record_data = record(list_index, row)
	return str(record_data.get("name", ""))

func _block_by_name(type: String) -> Dictionary:
	for block in _blocks:
		if block.name == type:
			return block
	return {}

func _decode_field(raw: PackedByteArray, field: Dictionary):
	var offset: int = field.offset
	var field_type: String = field.type
	if field_type.begins_with("wstring:"):
		var value = ""
		for i in range(offset, offset + field.size, 2):
			var code = raw.decode_u16(i)
			if code == 0:
				break
			value += String.chr(code)
		return value
	if field_type.begins_with("string:"):
		var value = ""
		for i in range(offset, offset + field.size):
			if raw[i] == 0:
				break
			value += String.chr(raw[i])
		return value
	if field_type in ["float", "double"]:
		return raw.decode_float(offset) if field_type == "float" else raw.decode_double(offset)
	if field.size == 8:
		return raw.decode_u64(offset) if field_type.begins_with("uint") or field_type in ["ulong"] else raw.decode_s64(offset)
	if field.size == 4:
		return raw.decode_u32(offset) if field_type.begins_with("uint") or field_type in ["uint", "dword"] else raw.decode_s32(offset)
	if field.size == 2:
		return raw.decode_u16(offset) if field_type.begins_with("uint") or field_type in ["ushort", "word"] else raw.decode_s16(offset)
	return raw[offset] if field_type in ["byte", "uint8", "char", "bool"] else raw.decode_s8(offset)
