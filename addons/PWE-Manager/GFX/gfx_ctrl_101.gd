@tool 
extends Node3D

@export_storage var parsed_data: Dictionary = {}

# Dictionary mit den neuen Parametern und ihren Datentypen
const PARAMS = {
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"Vel": TYPE_FLOAT,
	"Acc": TYPE_FLOAT
}

func _get_property_list() -> Array[Dictionary]: 
	return _build_props("101")

func _get(prop: StringName): 
	return _get_val(prop)

func _set(prop: StringName, val: Variant) -> bool:
	var prop_str = str(prop)
	for param in PARAMS.keys():
		if prop_str.ends_with(param):
			var was_missing = not parsed_data.has(param)
			parsed_data[param] = val
			
			# Inspektor updaten für den Emoji-Wechsel 🔵 -> 🟢
			if was_missing:
				notify_property_list_changed()
				
			return true
	return false

# --- Helper ---
func _build_props(id: String) -> Array[Dictionary]:
	var p: Array[Dictionary] = [{"name": "CtrlType " + id, "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
	for param in PARAMS.keys(): 
		var prefix = "🟢 " if parsed_data.has(param) else "🔵 [Fehlt] "
		p.append({
			"name": prefix + param, 
			"type": PARAMS[param], 
			"usage": PROPERTY_USAGE_EDITOR
		})
	return p

func _get_val(prop: StringName):
	var prop_str = str(prop)
	for param in PARAMS.keys():
		if prop_str.ends_with(param): 
			if parsed_data.has(param):
				return parsed_data[param]
			else:
				# Gibt zur Vermeidung von Fehlern einen passenden Nullwert zurück
				return _get_default_for_type(PARAMS[param])
	return null

func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
	return null
