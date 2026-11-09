@tool
extends Node3D

@export_storage var parsed_data: Dictionary = {}

# Dictionary, das die Parameter mit ihren korrekten Datentypen verknüpft
const PARAMS = {
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"Dir": TYPE_VECTOR3,
	"Vel": TYPE_FLOAT,
	"Acc": TYPE_FLOAT
}

func _get_property_list() -> Array[Dictionary]:
	return _build_props("100")

func _get(prop: StringName):
	return _get_val(prop)

func _set(prop: StringName, val: Variant) -> bool:
	var prop_str = str(prop)
	for param in PARAMS.keys():
		# Wenn der im Inspektor geänderte Wert einer unserer Parameter ist
		if prop_str.ends_with(param):
			var was_missing = not parsed_data.has(param)
			var expected_type = PARAMS[param]
			
			# === ÜBERSETZER: Godot Objekt -> Text für Rohdaten ===
			if expected_type == TYPE_VECTOR3:
				parsed_data[param] = _vector3_to_string(val)
			elif expected_type == TYPE_FLOAT:
				parsed_data[param] = "%.6f" % val # Erhält die 6 Nullen nach dem Komma
			elif expected_type == TYPE_INT:
				parsed_data[param] = str(val)
			else:
				parsed_data[param] = val
			
			# Wenn der Wert vorher fehlte, updaten wir den Inspektor,
			# damit "🔵 [Fehlt]" zu "🟢" wird.
			if was_missing:
				notify_property_list_changed()
			return true
	return false

func _build_props(id: String) -> Array[Dictionary]:
	var p: Array[Dictionary] = [{"name": "CtrlType " + id, "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	for param in PARAMS.keys():
		var prefix = "🟢 " if parsed_data.has(param) else "🔵 [Fehlt] "
		p.append({
			"name": prefix + param,
			"type": PARAMS[param], # Hier wird der korrekte Datentyp (aus dem Dictionary) gesetzt
			"usage": PROPERTY_USAGE_EDITOR
		})
	return p

func _get_val(prop: StringName):
	var prop_str = str(prop)
	for param in PARAMS.keys():
		if prop_str.ends_with(param):
			if parsed_data.has(param):
				var read_val = parsed_data[param]
				var expected_type = PARAMS[param]
				
				# === ÜBERSETZER: Text aus Rohdaten -> Godot Objekt ===
				if typeof(read_val) == TYPE_STRING:
					if expected_type == TYPE_VECTOR3: return _string_to_vector3(read_val)
					if expected_type == TYPE_FLOAT: return read_val.to_float()
					if expected_type == TYPE_INT: return read_val.to_int()
				
				return read_val
			else:
				# Gibt einen Standardwert zurück, passend zum Datentyp, falls noch nichts in parsed_data steht
				return _get_default_for_type(PARAMS[param])
	return null


# --- HELPER FUNKTIONEN ---

# Wandelt Vector-Text aus der .gfx (z.B. "0.0, 1.0, 0.0") für Godot in ein echtes Vector3 um
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
