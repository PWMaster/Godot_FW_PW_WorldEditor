@tool
extends Node3D

# --- Manueller Tracker für gemappte Parameter ---
@export_placeholder("TexRow, TexCol, StartTime...") 
var mapped_tracker: String = "Name, Direction, TexFile, Color, TexRow, TexCol,
	Position, Width, Height, RotFromView, TexInterval, Priority ":
	set(v):
		mapped_tracker = v
		notify_property_list_changed()

@export_storage var parsed_data: Dictionary = {}

const KNOWN_PARAMS = [
	"GFXELEMENTID", "Name", "SrcBlend", "DestBlend", "RepeatCount", "RepeatDelay",
	"TexFile", "BindEle", "ZEnable", "MatchGrnd", "GroundHeight", "TexRow", "TexCol",
	"TexInterval", "Priority", "IsDummy", "DummyEle", "Warp", "TileMode",
	"TexSpeed_1", "TexSpeed_2", "UReverse", "VReverse", "UVExchg", "RenderLayer",
	"NoDownSample", "ResetLoopEnd", "TexAnimMaxTime", "PSFileVersion", "ShaderFile",
	"ShaderTex", "PSConstCount", "CanDoFadeOut", "Width", "Height", "RotFromView",
	"GrndNormOnly", "NoScale_1", "NoScale_2", "OrgPt_1", "OrgPt_2", "ZOffset",
	"MatchSurface", "SurfaceUseParentDir", "MaxExtent", "YawEffect", "StartTime",
    "KEYPOINTCOUNT"
]

const PARAM_TYPES: Dictionary = {
	"GFXELEMENTID": TYPE_INT, "SrcBlend": TYPE_INT, "DestBlend": TYPE_INT,
	"RepeatCount": TYPE_INT, "RepeatDelay": TYPE_INT, "TexRow": TYPE_INT, "TexCol": TYPE_INT,
	"TexInterval": TYPE_INT, "Priority": TYPE_INT, "DummyEle": TYPE_INT,
	"RenderLayer": TYPE_INT, "TexAnimMaxTime": TYPE_INT, "PSConstCount": TYPE_INT,
	"KEYPOINTCOUNT": TYPE_INT, "PSConstIndex": TYPE_INT, "PSLoopCount": TYPE_INT,
	"PSTargetCount": TYPE_INT, "PSInterval": TYPE_INT, "CtrlMethodCount": TYPE_INT,
	"Width": TYPE_FLOAT, "Height": TYPE_FLOAT, "OrgPt_1": TYPE_FLOAT, "OrgPt_2": TYPE_FLOAT,
	"ZOffset": TYPE_FLOAT, "MaxExtent": TYPE_FLOAT, "StartTime": TYPE_FLOAT,
	"TexSpeed_1": TYPE_FLOAT, "TexSpeed_2": TYPE_FLOAT, "TimeSpan": TYPE_FLOAT,
	"Scale": TYPE_FLOAT, "Rad_2D": TYPE_FLOAT,
	"Name": TYPE_STRING, "TexFile": TYPE_STRING, "BindEle": TYPE_STRING,
	"Warp": TYPE_BOOL, "ShaderFile": TYPE_STRING, "ShaderTex": TYPE_STRING,
	"ZEnable": TYPE_BOOL, "MatchGrnd": TYPE_BOOL, "GroundHeight": TYPE_BOOL,
	"IsDummy": TYPE_BOOL, "TileMode": TYPE_BOOL, "UReverse": TYPE_BOOL, "VReverse": TYPE_BOOL,
	"UVExchg": TYPE_BOOL, "NoDownSample": TYPE_BOOL, "ResetLoopEnd": TYPE_BOOL,
	"PSFileVersion": TYPE_BOOL, "CanDoFadeOut": TYPE_BOOL, "RotFromView": TYPE_BOOL,
	"GrndNormOnly": TYPE_BOOL, "NoScale_1": TYPE_BOOL, "NoScale_2": TYPE_BOOL,
	"MatchSurface": TYPE_BOOL, "SurfaceUseParentDir": TYPE_BOOL, "YawEffect": TYPE_BOOL,
	"InterpolateMode": TYPE_INT,
	"Position": TYPE_VECTOR3, "PSConstValue": TYPE_VECTOR4,
	"Direction": TYPE_VECTOR4, "Color": TYPE_COLOR
}

# Hilfsfunktion, um alle visuellen Marker für die interne Logik zu entfernen
func _get_clean_name(property: String) -> String:
	return property.replace("🟢 ", "").replace("🔵 ", "").replace("[Fehlt] ", "").replace(" ✅", "").strip_edges()

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = [{"name": "GFX Element (Type 100)", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
	# Vorbereiten der manuellen Liste für den Abgleich
	var manual_list = mapped_tracker.split(",")
	for i in range(manual_list.size()):
		manual_list[i] = manual_list[i].strip_edges()

	# Hauptparameter
	for param in KNOWN_PARAMS:
		var has_param = parsed_data.has(param)
		var prefix = "🟢 " if has_param else "🔵 [Fehlt] "
		var suffix = " ✅" if param in manual_list else ""
		var type = PARAM_TYPES.get(param, TYPE_STRING)
		props.append({"name": prefix + param + suffix, "type": type, "usage": PROPERTY_USAGE_EDITOR})

	# PS Const Blocks
	if parsed_data.has("_ps_consts"):
		var ps_array = parsed_data["_ps_consts"]
		for p in range(ps_array.size()):
			var block = ps_array[p]
			var path = "PS Const Block " + str(p) + "/"
			for param in ["PSConstIndex", "PSConstValue", "PSLoopCount", "PSTargetCount"]:
				var pfx = "🟢 " if block.has(param) else "🔵 "
				var sfx = " ✅" if param in manual_list else ""
				props.append({"name": path + pfx + param + sfx, "type": PARAM_TYPES.get(param, TYPE_STRING), "usage": PROPERTY_USAGE_EDITOR})
			
			if block.has("_targets"):
				var targets = block["_targets"]
				for t in range(targets.size()):
					var t_path = path + "Target " + str(t) + "/"
					var tgt = targets[t]
					for param in ["PSInterval", "PSConstValue"]:
						var pfx = "🟢 " if tgt.has(param) else "🔵 "
						var sfx = " ✅" if param in manual_list else ""
						props.append({"name": t_path + pfx + param + sfx, "type": PARAM_TYPES.get(param, TYPE_STRING), "usage": PROPERTY_USAGE_EDITOR})

	# KeyPoints
	if parsed_data.has("_keypoints"):
		var kp_array = parsed_data["_keypoints"]
		for k in range(kp_array.size()):
			var kp = kp_array[k]
			var path = "KeyPoint " + str(k) + "/"
			for param in ["InterpolateMode", "TimeSpan", "Position", "Color", "Scale", "Direction", "Rad_2D", "CtrlMethodCount"]:
				var pfx = "🟢 " if kp.has(param) else "🔵 "
				var sfx = " ✅" if param in manual_list else ""
				props.append({"name": path + pfx + param + sfx, "type": PARAM_TYPES.get(param, TYPE_STRING), "usage": PROPERTY_USAGE_EDITOR})

	return props

func _get(property: StringName):
	var prop_str = _get_clean_name(str(property))
	
	var is_valid = (prop_str in KNOWN_PARAMS) or prop_str.begins_with("PS Const Block ") or prop_str.begins_with("KeyPoint ")
	if not is_valid: return null

	var expected_type = TYPE_STRING
	var dict_ref = parsed_data
	var param_name = prop_str

	if prop_str.begins_with("PS Const Block "):
		var parts = prop_str.split("/")
		var b_idx = parts[0].trim_prefix("PS Const Block ").to_int()
		if not parsed_data.has("_ps_consts") or b_idx >= parsed_data["_ps_consts"].size(): return null
		if parts.size() == 2:
			dict_ref = parsed_data["_ps_consts"][b_idx]
			param_name = parts[1]
		elif parts.size() == 3:
			var t_idx = parts[1].trim_prefix("Target ").to_int()
			var tgts = parsed_data["_ps_consts"][b_idx].get("_targets", [])
			if t_idx >= tgts.size(): return null
			dict_ref = tgts[t_idx]
			param_name = parts[2]
			
	elif prop_str.begins_with("KeyPoint "):
		var parts = prop_str.split("/")
		var k_idx = parts[0].trim_prefix("KeyPoint ").to_int()
		if not parsed_data.has("_keypoints") or k_idx >= parsed_data["_keypoints"].size(): return null
		dict_ref = parsed_data["_keypoints"][k_idx]
		param_name = parts[1]

	expected_type = PARAM_TYPES.get(param_name, TYPE_STRING)
	if dict_ref.has(param_name):
		return _translate_to_godot(param_name, dict_ref[param_name], expected_type)
	else:
		return _get_default_for_type(expected_type)

func _set(property: StringName, value: Variant) -> bool:
	var prop_str = _get_clean_name(str(property))
	
	var is_valid = (prop_str in KNOWN_PARAMS) or prop_str.begins_with("PS Const Block ") or prop_str.begins_with("KeyPoint ")
	if not is_valid: return false

	var dict_ref = parsed_data
	var param_name = prop_str
	var should_notify = false

	if prop_str.begins_with("PS Const Block "):
		var parts = prop_str.split("/")
		var b_idx = parts[0].trim_prefix("PS Const Block ").to_int()
		if not parsed_data.has("_ps_consts") or b_idx >= parsed_data["_ps_consts"].size(): return false
		if parts.size() == 2:
			dict_ref = parsed_data["_ps_consts"][b_idx]
			param_name = parts[1]
		elif parts.size() == 3:
			var t_idx = parts[1].trim_prefix("Target ").to_int()
			var tgts = parsed_data["_ps_consts"][b_idx].get("_targets", [])
			if t_idx >= tgts.size(): return false
			dict_ref = tgts[t_idx]
			param_name = parts[2]
			
	elif prop_str.begins_with("KeyPoint "):
		var parts = prop_str.split("/")
		var k_idx = parts[0].trim_prefix("KeyPoint ").to_int()
		if not parsed_data.has("_keypoints") or k_idx >= parsed_data["_keypoints"].size(): return false
		dict_ref = parsed_data["_keypoints"][k_idx]
		param_name = parts[1]

	if not dict_ref.has(param_name): should_notify = true
	var expected_type = PARAM_TYPES.get(param_name, TYPE_STRING)
	dict_ref[param_name] = _translate_to_gfx(param_name, value, expected_type)
	
	if should_notify: notify_property_list_changed()
	return true

# ==========================================
# ====== TRANSLATOR / HELPER =============
# ==========================================

func _translate_to_godot(_param: String, val, expected_type: int):
	if typeof(val) == TYPE_STRING:
		match expected_type:
			TYPE_FLOAT: return val.to_float()
			TYPE_INT: return val.to_int()
			TYPE_BOOL: return (val == "1" or val.to_lower() == "true")
			TYPE_VECTOR3: return _string_to_vector3(val)
			TYPE_VECTOR4: return _string_to_vector4(val)
			TYPE_COLOR: return _int_string_to_color(val)
			_: return val
	return val

func _translate_to_gfx(_param: String, godot_val, expected_type: int):
	match expected_type:
		TYPE_FLOAT: return "%.6f" % godot_val
		TYPE_INT: return str(godot_val)
		TYPE_BOOL: return "1" if godot_val else "0"
		TYPE_VECTOR3: return "%.6f, %.6f, %.6f" % [godot_val.x, godot_val.y, godot_val.z]
		TYPE_VECTOR4: return "%.6f, %.6f, %.6f, %.6f" % [godot_val.x, godot_val.y, godot_val.z, godot_val.w]
		TYPE_COLOR: return _color_to_int_string(godot_val)
		_: return str(godot_val)

func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
		TYPE_BOOL: return false
		TYPE_STRING: return ""
		TYPE_VECTOR3: return Vector3.ZERO
		TYPE_VECTOR4: return Vector4.ZERO
		TYPE_COLOR: return Color(0,0,0,1)
	return null

func _string_to_vector3(v_str: String) -> Vector3:
	var p = v_str.replace(" ", "").split(",")
	if p.size() >= 3: return Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float())
	return Vector3.ZERO

func _string_to_vector4(v_str: String) -> Vector4:
	var p = v_str.replace(" ", "").split(",")
	if p.size() >= 4: return Vector4(p[0].to_float(), p[1].to_float(), p[2].to_float(), p[3].to_float())
	return Vector4.ZERO

func _int_string_to_color(val_str: String) -> Color:
	var u = val_str.to_int() & 0xFFFFFFFF
	return Color(((u >> 16) & 0xFF)/255.0, ((u >> 8) & 0xFF)/255.0, (u & 0xFF)/255.0, ((u>>24) & 0xFF)/255.0)

func _color_to_int_string(c: Color) -> String:
	var u: int = (int(c.a * 255)<<24) | (int(c.r * 255)<<16) | (int(c.g * 255)<<8) | int(c.b * 255)
	if u >= 2147483648: u -= 4294967296
	return str(u)
