@tool 
extends Node3D

@export_storage var parsed_data: Dictionary = {}

# Das Dictionary ordnet die Typen zu. CalcDir wird als BOOL ausgewertet.
const PARAMS = {
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"CalcDir": TYPE_BOOL,
	"Count": TYPE_INT
}

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = [{"name": "CtrlType 110", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
	for param in PARAMS.keys():
		var has_param = parsed_data.has(param)
		var prefix = "🟢 " if has_param else "🔵 [Fehlt] "
		
		props.append({
			"name": prefix + param,
			"type": PARAMS[param],
			"usage": PROPERTY_USAGE_EDITOR
		})
		
	# Array Property hinzufügen
	var c = _get_internal_value("Count", TYPE_INT)
	var arr_prefix = "🟢 " if c > 0 else "🔵 [Fehlt] "
	
	props.append({
		"name": arr_prefix + "Pos_Array", 
		"type": TYPE_ARRAY, 
		"usage": PROPERTY_USAGE_EDITOR
	})
	
	return props

func _get(property: StringName):
	var prop_str = str(property)
	
	# 1. Normale Variablen auslesen
	for param in PARAMS.keys():
		if prop_str.ends_with(param):
			return _get_internal_value(param, PARAMS[param])
			
	# 2. Den Array laden (Die Einträge Pos, Pos_2, Pos_3 etc. zusammensetzen)
	if prop_str.ends_with("Pos_Array"):
		# Durch Type-Hinting in Godot 4 (Array[Vector3]) weiß der Inspektor genau, was wir wollen
		var arr: Array[Vector3] = [] 
		var c = _get_internal_value("Count", TYPE_INT)
		for i in range(1, c + 1):
			var key = "Pos" if i == 1 else "Pos_" + str(i)
			if parsed_data.has(key):
				arr.append(_string_to_vector3(parsed_data[key]))
			else:
				arr.append(Vector3.ZERO)
		return arr
		
	return null

func _set(property: StringName, value: Variant) -> bool:
	var prop_str = str(property)
	
	# 1. Normale Variablen speichern
	for param in PARAMS.keys():
		if prop_str.ends_with(param):
			var was_missing = not parsed_data.has(param)
			var expected_type = PARAMS[param]
			
			# === ÜBERSETZER: Godot Objekt -> Text ===
			if expected_type == TYPE_FLOAT:
				parsed_data[param] = "%.6f" % value
			elif expected_type == TYPE_INT:
				parsed_data[param] = str(value)
			elif expected_type == TYPE_BOOL:
				parsed_data[param] = "1" if value else "0"
			else:
				parsed_data[param] = value
			
			# Wenn Count oder CalcDir sich ändern, den Inspektor aktualisieren
			if was_missing or param == "Count":
				notify_property_list_changed()
				
			return true
			
	# 2. Den bearbeiteten Array abspeichern (zwingend als neue Pos_X Schlüssel)
	if prop_str.ends_with("Pos_Array"):
		var arr = value as Array
		
		# Den internen Count anpassen, falls im Inspektor Items gelöscht/hinzugefügt wurden!
		parsed_data["Count"] = str(arr.size())
		
		# Aufräumen: Alle alten Pos-Schlüssel löschen, damit es keine "Überhänge" gibt
		var to_delete = []
		for k in parsed_data.keys():
			if k == "Pos" or k.begins_with("Pos_"):
				to_delete.append(k)
		for k in to_delete:
			parsed_data.erase(k)
			
		# Neu aufbauen: Alle Punkte aus dem Inspektor frisch in dein Format speichern
		for i in range(arr.size()):
			var key = "Pos" if i == 0 else "Pos_" + str(i + 1)
			# Fallback, falls der Editor ein "Nil" in den Array packt
			var vec = arr[i] if typeof(arr[i]) == TYPE_VECTOR3 else Vector3.ZERO
			parsed_data[key] = _vector3_to_string(vec)
			
		notify_property_list_changed()
		return true
		
	return false

# --- INTERNE ABFRAGE LOGIK ---
func _get_internal_value(param: String, expected_type: int):
	if parsed_data.has(param):
		var val = parsed_data[param]
		
		# === ÜBERSETZER: Text -> Godot Objekt ===
		if typeof(val) == TYPE_STRING:
			if expected_type == TYPE_FLOAT: return val.to_float()
			if expected_type == TYPE_INT: return val.to_int()
			# Versteht, dass "1" (aus dem Text) eigentlich True ist!
			if expected_type == TYPE_BOOL: return (val == "1" or val.to_lower() == "true") 
		return val
	return _get_default_for_type(expected_type)


# --- STRINGS <-> VEKTOREN KONVERTER ---
func _string_to_vector3(val_str: String) -> Vector3:
	var parts = val_str.replace(" ", "").split(",")
	if parts.size() >= 3:
		return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
	return Vector3.ZERO

func _vector3_to_string(v: Vector3) -> String:
	return "%.6f, %.6f, %.6f" % [v.x, v.y, v.z]

func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
		TYPE_BOOL: return false
	return null
