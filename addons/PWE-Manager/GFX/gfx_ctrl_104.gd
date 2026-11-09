@tool
extends Node3D

@export_storage var parsed_data: Dictionary = {}

# Dictionary für Parameter und ihre korrekten Datentypen
const KNOWN_PARAMS = {
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"Pos": TYPE_VECTOR3,
	"Vel": TYPE_FLOAT,
	"Acc": TYPE_FLOAT
}

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = [{"name": "CtrlType 104", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
	for param in KNOWN_PARAMS.keys():
		var has_param = parsed_data.has(param)
		var prefix = "🟢 " if has_param else "🔵 [Fehlt] "
		
		props.append({
			"name": prefix + param, 
			"type": KNOWN_PARAMS[param], # Der richtige Datentyp wird hier gesetzt
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
					if expected_type == TYPE_VECTOR3: return _string_to_vector3(val)
					if expected_type == TYPE_FLOAT: return val.to_float()
					if expected_type == TYPE_INT: return val.to_int()
				
				return val
			else:
				# Gibt den typenspezifischen Standardwert zurück statt "---"
				return _get_default_for_type(KNOWN_PARAMS[param])
	return null

func _set(property: StringName, value: Variant) -> bool: 
	var prop_str = str(property)
	for param in KNOWN_PARAMS.keys():
		if prop_str.ends_with(param):
			var was_missing = not parsed_data.has(param)
			var expected_type = KNOWN_PARAMS[param]
			
			# === ÜBERSETZER: Godot Objekt -> Text für Rohdaten ===
			if expected_type == TYPE_VECTOR3:
				parsed_data[param] = _vector3_to_string(value)
			elif expected_type == TYPE_FLOAT:
				parsed_data[param] = "%.6f" % value # Erhält die 6 Nullen nach dem Komma
			elif expected_type == TYPE_INT:
				parsed_data[param] = str(value)
			else:
				parsed_data[param] = value
			
			# Wenn der Wert zuvor gefehlt hat, updaten wir den Inspektor (🔵 -> 🟢)
			if was_missing:
				notify_property_list_changed()
				
			return true
	return false

# --- HELPER FUNKTIONEN ---

# Wandelt Vector-Text aus der .gfx (z.B. "0.5, 1.0, 0.0") für Godot in ein echtes Vector3 um
func _string_to_vector3(val_str: String) -> Vector3:
	var parts = val_str.replace(" ", "").split(",")
	if parts.size() >= 3:
		return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
	return Vector3.ZERO

# Wandelt Vector3 aus dem Godot-Inspektor zurück in den Text-Standard für die Speicherung um
func _vector3_to_string(v: Vector3) -> String:
	return "%.6f, %.6f, %.6f" % [v.x, v.y, v.z]

# Hilfsfunktion für Standardwerte der jeweiligen Datentypen
func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
		TYPE_VECTOR3: return Vector3.ZERO
	return null
