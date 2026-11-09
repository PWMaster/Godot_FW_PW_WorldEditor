@tool
extends Node3D

@export_storage var parsed_data: Dictionary = {}

const KNOWN_PARAMS = {
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"ColorDelta": TYPE_COLOR # Erzeugt einen echten Godot-Farbwähler!
}

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = [{"name": "CtrlType 105", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
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
				# SPEZIALFALL: Wenn wir hier deinen ARGB-String aus den Rohdaten erhalten, 
				# wandeln wir ihn blitzschnell für Godot in ein Farb-Objekt um
				if param == "ColorDelta" and val is String:
					return _argb_string_to_color(val)
				return val
			else:
				return _get_default_for_type(KNOWN_PARAMS[param])
	return null

func _set(property: StringName, value: Variant) -> bool: 
	var prop_str = str(property)
	for param in KNOWN_PARAMS.keys():
		if prop_str.ends_with(param):
			var was_missing = not parsed_data.has(param)
			
			# SPEZIALFALL: Wenn der Inspektor uns (z.B. per Godot Farbwähler oder Hexcode) 
			# eine Godot-Farbe übergibt, wandeln wir sie zurück in deinen ARGB-String!
			if param == "ColorDelta" and value is Color:
				parsed_data[param] = _color_to_argb_string(value)
			else:
				parsed_data[param] = value
			
			if was_missing:
				notify_property_list_changed()
				
			return true
	return false

# --- Helper Standardwerte ---
func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
		TYPE_COLOR: return Color(0, 0, 0, 1) # Schwarz, voller Alpha-Wert als Fallback
	return null

# --- Helper Farbumwandlung ---

# Wandelt dein Datenformat "A, R, G, B" (z.B. "0, 0, 0, -500") in Godot RGBA um (0.0 bis 1.0)
func _argb_string_to_color(argb_str: String) -> Color:
	var parts = argb_str.replace(" ", "").split(",")
	if parts.size() >= 4:
		var a = parts[0].to_float() / 255.0
		var r = parts[1].to_float() / 255.0
		var g = parts[2].to_float() / 255.0
		# Unterstützt auch negative Deltas (z.B. -500 / 255.0 = -1.96)
		var b = parts[3].to_float() / 255.0 
		return Color(r, g, b, a)
	return Color(0, 0, 0, 1)

# Wandelt eine Godotfarbe (oder Hex Eingabe) wieder in dein "A, R, G, B" (z.B. 0, 255, 0, -500) um
func _color_to_argb_string(c: Color) -> String:
	var a = int(round(c.a * 255.0))
	var r = int(round(c.r * 255.0))
	var g = int(round(c.g * 255.0))
	var b = int(round(c.b * 255.0))
	return "%d, %d, %d, %d" % [a, r, g, b]
