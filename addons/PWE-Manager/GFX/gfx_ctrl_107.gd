@tool
extends Node3D

@export_storage var parsed_data: Dictionary = {}

# Hier ordnen wir jedem Wert den passenden Typ für den Inspektor zu
const KNOWN_PARAMS = {
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"BufLen": TYPE_INT,
	"Amplitude": TYPE_FLOAT,
	"WaveLen": TYPE_FLOAT,
	"Persistence": TYPE_FLOAT,
	"OctaveNum": TYPE_INT,
	"BaseColor": TYPE_COLOR # Erzeugt den Godot Farbwähler
}

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = [{"name": "CtrlType 107", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
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
				
				# === ÜBERSETZER: Rohdaten -> Godot Objekt ===
				if typeof(val) == TYPE_STRING:
					if expected_type == TYPE_COLOR: return _int_string_to_color(val)
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
			
			# === ÜBERSETZER: Godot Objekt -> Text für deine .gfx Rohdaten ===
			if expected_type == TYPE_COLOR:
				parsed_data[param] = _color_to_int_string(value)
			elif expected_type == TYPE_FLOAT:
				parsed_data[param] = "%.6f" % value
			elif expected_type == TYPE_INT:
				parsed_data[param] = str(value)
			else:
				parsed_data[param] = value
			
			if was_missing:
				notify_property_list_changed()
				
			return true
	return false

# --- HELPER FUNKTIONEN ---

# Wandelt die große negative/positive Integer-Zahl aus dem Stringverlauf in eine Godot Farbe um
func _int_string_to_color(val_str: String) -> Color:
	var val_int = val_str.to_int()
	# In 32-bit unsigned zwingen, um die Bytes sauber auszulesen
	var u = val_int & 0xFFFFFFFF 
	var a = ((u >> 24) & 0xFF) / 255.0
	var r = ((u >> 16) & 0xFF) / 255.0
	var g = ((u >> 8)  & 0xFF) / 255.0
	var b = ( u        & 0xFF) / 255.0
	return Color(r, g, b, a)

# Wandelt die Godot Farbe aus dem Inspektor zurück in die große Signed-Integer-Zahl (als String)
func _color_to_int_string(c: Color) -> String:
	var a = int(round(c.a * 255.0))
	var r = int(round(c.r * 255.0))
	var g = int(round(c.g * 255.0))
	var b = int(round(c.b * 255.0))
	
	# Packt die 4 Bytes in einen 32-bit Unsigned Integer
	var u: int = (a << 24) | (r << 16) | (g << 8) | b
	
	# Konvertiert den Unsigned in den typischen Signed Integer (macht es in großen Werten negativ)
	if u >= 2147483648:
		u -= 4294967296
		
	return str(u)

# Standardwerte falls Felder fehlen
func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
		TYPE_COLOR: return Color(0, 0, 0, 1) # Schwarz, deckend
	return null
