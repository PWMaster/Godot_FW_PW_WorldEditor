@tool
extends Node3D

@export_storage var parsed_data: Dictionary = {}

# Das Dictionary bestimmt die korrekten Typen für den Inspektor
const KNOWN_PARAMS = {
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"Scale": TYPE_FLOAT,
	"Count": TYPE_INT,
	"Scale_2": TYPE_FLOAT,
	"TimeSpan": TYPE_FLOAT,
	"Scale_3": TYPE_FLOAT,
	"TimeSpan_2": TYPE_FLOAT,
	"Scale_4": TYPE_FLOAT,
	"TimeSpan_3": TYPE_FLOAT,
	"Scale_5": TYPE_FLOAT,
	"TimeSpan_4": TYPE_FLOAT,
	"Scale_6": TYPE_FLOAT,      # NEU
	"TimeSpan_5": TYPE_FLOAT    # NEU
}

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = [{"name": "CtrlType 111", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
	# Wir lesen den Count aus, um zu wissen, wie viele Parameter wir anzeigen müssen
	var current_count = _get_internal_value("Count", TYPE_INT)
	
	for param in KNOWN_PARAMS.keys():
		# DYNAMISCHER INSPEKTOR: Ausblenden der "Array"-Zusatzfelder, wenn Count zu niedrig ist!
		if param in ["Scale_2", "TimeSpan"]   and current_count < 1: continue
		if param in ["Scale_3", "TimeSpan_2"] and current_count < 2: continue
		if param in ["Scale_4", "TimeSpan_3"] and current_count < 3: continue
		if param in ["Scale_5", "TimeSpan_4"] and current_count < 4: continue
		if param in ["Scale_6", "TimeSpan_5"] and current_count < 5: continue # NEU
		
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
			return _get_internal_value(param, KNOWN_PARAMS[param])
	return null

func _set(property: StringName, value: Variant) -> bool:
	var prop_str = str(property)
	for param in KNOWN_PARAMS.keys():
		if prop_str.ends_with(param):
			var was_missing = not parsed_data.has(param)
			var expected_type = KNOWN_PARAMS[param]
			
			# === ÜBERSETZER: Godot Objekt -> Text für .gfx ===
			if expected_type == TYPE_FLOAT:
				parsed_data[param] = "%.6f" % value # Erhält die 6 Nullen nach dem Komma
			elif expected_type == TYPE_INT:
				parsed_data[param] = str(value)
			else:
				parsed_data[param] = value
			
			# === INSPEKTOR UPDATEN ===
			# Wenn Count verändert wird, updaten wir den Editor live, damit Felder aufpoppen!
			if was_missing or param == "Count":
				notify_property_list_changed()
				
			return true
	return false

# --- INTERNE ABFRAGE LOGIK ---
func _get_internal_value(param: String, expected_type: int):
	if parsed_data.has(param):
		var val = parsed_data[param]
		
		# === ÜBERSETZER: Text aus Rohdaten -> Godot Objekt ===
		if typeof(val) == TYPE_STRING:
			if expected_type == TYPE_FLOAT: return val.to_float()
			if expected_type == TYPE_INT: return val.to_int()
		return val
	else:
		return _get_default_for_type(expected_type)

# --- HELPER DEFAULTS ---
func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
	return null
