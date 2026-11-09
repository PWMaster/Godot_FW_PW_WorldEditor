@tool
extends Node3D

@export_storage var parsed_data: Dictionary = {}

# Das Dictionary ordnet die passenden Datentypen für den Inspektor zu
const KNOWN_PARAMS = {
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"BufLen": TYPE_INT,
	"Amplitude": TYPE_FLOAT,
	"WaveLen": TYPE_FLOAT,
	"Persistence": TYPE_FLOAT,
	"OctaveNum": TYPE_INT
}

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = [{"name": "CtrlType 109", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
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
				
				# === ÜBERSETZER: Text aus Rohdaten -> Godot Objekt ===
				if typeof(val) == TYPE_STRING:
					if expected_type == TYPE_FLOAT: return val.to_float()
					if expected_type == TYPE_INT: return val.to_int()
				
				return val
			else:
				# Gibt den typenspezifischen Standardwert zurück
				return _get_default_for_type(KNOWN_PARAMS[param])
	return null

func _set(property: StringName, value: Variant) -> bool: 
	var prop_str = str(property)
	for param in KNOWN_PARAMS.keys():
		if prop_str.ends_with(param):
			var was_missing = not parsed_data.has(param)
			var expected_type = KNOWN_PARAMS[param]
			
			# === ÜBERSETZER: Godot Objekt -> Text für Rohdaten ===
			if expected_type == TYPE_FLOAT:
				parsed_data[param] = "%.6f" % value # Erhält deine 6 Nullen nach dem Komma
			elif expected_type == TYPE_INT:
				parsed_data[param] = str(value)
			else:
				parsed_data[param] = value
			
			# Editor updaten (🔵 -> 🟢)
			if was_missing:
				notify_property_list_changed()
				
			return true
	return false

# Hilfsfunktion für Standardwerte der jeweiligen Datentypen
func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
	return null
