@tool
extends Node3D

@export_storage var parsed_data: Dictionary = {}

const KNOWN_PARAMS = {
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"ScaleChage": TYPE_VECTOR3
}

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = [{"name": "CtrlType 106", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
	for param in KNOWN_PARAMS.keys():
		var has_param = parsed_data.has(param)
		var prefix = "🟢 " if has_param else "🔵 [Fehlt] "
		
		props.append({
			"name": prefix + param, 
			"type": KNOWN_PARAMS[param], 
			"usage": PROPERTY_USAGE_EDITOR
		})
	return props

func _get(property: StringName):
	var prop_str = str(property)
	for param in KNOWN_PARAMS.keys():
		if prop_str.ends_with(param): 
			if parsed_data.has(param):
				var val = parsed_data[param]
				var expected_type = KNOWN_PARAMS[param]
				
				# === STRING ZU GODOT OBJEKT ÜBERSETZER ===
				if typeof(val) == TYPE_STRING:
					if expected_type == TYPE_VECTOR3: return _string_to_vector3(val)
					if expected_type == TYPE_FLOAT: return val.to_float()
					if expected_type == TYPE_INT: return val.to_int()
				
				return val
			else:
				return _get_default_for_type(KNOWN_PARAMS[param])
	return null

func _set(property: StringName, value: Variant) -> bool: 
	var prop_str = str(property)
	for param in KNOWN_PARAMS.keys():
		if prop_str.ends_with(param):
			var was_missing = not parsed_data.has(param)
			var expected_type = KNOWN_PARAMS[param]
			
			# === GODOT OBJEKT ZU STRING ÜBERSETZER ===
			# Macht aus Godot-Werten wieder Text, passend für deine .gfx Dateien
			if expected_type == TYPE_VECTOR3:
				parsed_data[param] = _vector3_to_string(value)
			elif expected_type == TYPE_FLOAT:
				parsed_data[param] = "%.6f" % value # Erhält deine 6 Nullen nach dem Komma
			elif expected_type == TYPE_INT:
				parsed_data[param] = str(value)
			else:
				parsed_data[param] = value
			
			if was_missing:
				notify_property_list_changed()
				
			return true
	return false


# --- HELPER (Wandeln String <-> Vector3) ---

# Wandelt "x.xx, y.yx, z.zz" in einen Vector3 um
func _string_to_vector3(val_str: String) -> Vector3:
	var parts = val_str.replace(" ", "").split(",")
	if parts.size() >= 3:
		return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
	return Vector3.ZERO

# Wandelt Vector3 zurück in String "x.xxxxxx, y.yyyyyy, z.zzzzzz" (für deine Originaldaten)
func _vector3_to_string(v: Vector3) -> String:
	return "%.6f, %.6f, %.6f" % [v.x, v.y, v.z]

# Gibt bei fehlenden Einträgen leere Nullen zurück, statt abzustürzen
func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
		TYPE_VECTOR3: return Vector3.ZERO
	return null
