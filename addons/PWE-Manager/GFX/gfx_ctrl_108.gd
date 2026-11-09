@tool
extends Node3D

@export_storage var parsed_data: Dictionary = {}

# Das Dictionary bestimmt die korrekten Typen für den Inspektor
const KNOWN_PARAMS = {
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"Color": TYPE_COLOR,
	"Count": TYPE_INT,
	"AlphaOnly": TYPE_BOOL, # "0" oder "1" wird eine schöne Checkbox
	"Color_2": TYPE_COLOR,
	"TimeSpan": TYPE_FLOAT,
	"Color_3": TYPE_COLOR,
	"TimeSpan_2": TYPE_FLOAT,
	"Color_4": TYPE_COLOR,
	"TimeSpan_3": TYPE_FLOAT,
	"Color_5": TYPE_COLOR,
	"TimeSpan_4": TYPE_FLOAT,
	"Color_6": TYPE_COLOR,
	"TimeSpan_5": TYPE_FLOAT
}

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = [{"name": "CtrlType 108", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
	# Wir lesen den aktuellen Count aus, um zu wissen, wie viele Parameter wir anzeigen müssen
	var current_count = _get_internal_value("Count", TYPE_INT)
	
	for param in KNOWN_PARAMS.keys():
		# DYNAMISCHER INSPEKTOR: Ausblenden der "Array"-Zusatzfelder, wenn Count zu niedrig ist!
		if param in ["Color_2", "TimeSpan"]   and current_count < 1: continue
		if param in ["Color_3", "TimeSpan_2"] and current_count < 2: continue
		if param in ["Color_4", "TimeSpan_3"] and current_count < 3: continue
		if param in ["Color_5", "TimeSpan_4"] and current_count < 4: continue
		if param in ["Color_6", "TimeSpan_5"] and current_count < 5: continue
		
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
			
			# === ÜBERSETZER: Godot -> Text für .gfx ===
			if expected_type == TYPE_COLOR:
				parsed_data[param] = _color_to_int_string(value)
			elif expected_type == TYPE_FLOAT:
				parsed_data[param] = "%.6f" % value
			elif expected_type == TYPE_BOOL:
				parsed_data[param] = "1" if value else "0" # True = 1, False = 0
			elif expected_type == TYPE_INT:
				parsed_data[param] = str(value)
			else:
				parsed_data[param] = value
			
			# === INSPEKTOR UPDATEN ===
			# Wenn eine Checkbox/Farbe neu gesetzt wurde ODER man die Anzahl (Count) ändert,
			# updaten wir den ganzen Editor, damit Felder live aufpoppen / reagieren!
			if was_missing or param == "Count":
				notify_property_list_changed()
				
			return true
	return false

# --- INTERNE ABFRAGE LOGIK ---
func _get_internal_value(param: String, expected_type: int):
	if parsed_data.has(param):
		var val = parsed_data[param]
		
		# === ÜBERSETZER: Text -> Godot Objekt ===
		if typeof(val) == TYPE_STRING:
			if expected_type == TYPE_COLOR: return _int_string_to_color(val)
			if expected_type == TYPE_FLOAT: return val.to_float()
			if expected_type == TYPE_INT: return val.to_int()
			if expected_type == TYPE_BOOL: return (val == "1" or val.to_lower() == "true")
		return val
	else:
		return _get_default_for_type(expected_type)


# --- HELPER FUNKTIONEN (Farben & Defaults) ---

func _int_string_to_color(val_str: String) -> Color:
	var val_int = val_str.to_int()
	var u = val_int & 0xFFFFFFFF
	var a = ((u >> 24) & 0xFF) / 255.0
	var r = ((u >> 16) & 0xFF) / 255.0
	var g = ((u >> 8)  & 0xFF) / 255.0
	var b = ( u        & 0xFF) / 255.0
	return Color(r, g, b, a)

func _color_to_int_string(c: Color) -> String:
	var a = int(round(c.a * 255.0))
	var r = int(round(c.r * 255.0))
	var g = int(round(c.g * 255.0))
	var b = int(round(c.b * 255.0))
	var u: int = (a << 24) | (r << 16) | (g << 8) | b
	if u >= 2147483648: u -= 4294967296
	return str(u)

func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
		TYPE_BOOL: return false
		TYPE_COLOR: return Color(0, 0, 0, 1)
	return null
