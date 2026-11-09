@tool
extends Node3D

@export_storage var parsed_data: Dictionary = {}

const KNOWN_PARAMS_TOP = [
	"GFXELEMENTID", "Name", "SrcBlend", "DestBlend", "RepeatCount", "RepeatDelay",
	"TexFile", "BindEle", "ZEnable", "MatchGrnd", "GroundHeight", "TexRow", "TexCol",
	"TexInterval", "Priority", "IsDummy", "DummyEle", "Warp", "TileMode",
	"TexSpeed_1", "TexSpeed_2", "UReverse", "VReverse", "UVExchg", "RenderLayer",
	"NoDownSample", "ResetLoopEnd", "TexAnimMaxTime", "PSFileVersion", "ShaderFile",
	"ShaderTex", "PSConstCount", "CanDoFadeOut",
	"wNumber", "hNumber" # <-- Das definiert die Grid-Größe
]

const KNOWN_PARAMS_BOTTOM = [
	"fGridSize", "fZOffset", "keyNumber", "AffByScl", "RotFromView", "fOffsetHeight",
	"StartTime", "KEYPOINTCOUNT"
]

const PARAM_TYPES: Dictionary = {
	"GFXELEMENTID": TYPE_INT, "SrcBlend": TYPE_INT, "DestBlend": TYPE_INT,
	"RepeatCount": TYPE_INT, "RepeatDelay": TYPE_INT, "TexRow": TYPE_INT, "TexCol": TYPE_INT,
	"TexInterval": TYPE_INT, "Priority": TYPE_INT, "DummyEle": TYPE_INT,
	"RenderLayer": TYPE_INT, "TexAnimMaxTime": TYPE_INT, "PSConstCount": TYPE_INT,
	"KEYPOINTCOUNT": TYPE_INT, "PSConstIndex": TYPE_INT, "PSLoopCount": TYPE_INT,
	"PSTargetCount": TYPE_INT, "PSInterval": TYPE_INT, "CtrlMethodCount": TYPE_INT,
	"wNumber": TYPE_INT, "hNumber": TYPE_INT, "keyNumber": TYPE_INT,
	
	"TexSpeed_1": TYPE_FLOAT, "TexSpeed_2": TYPE_FLOAT, "StartTime": TYPE_FLOAT,
	"TimeSpan": TYPE_FLOAT, "Scale": TYPE_FLOAT, "Rad_2D": TYPE_FLOAT,
	"fGridSize": TYPE_FLOAT, "fZOffset": TYPE_FLOAT, "fOffsetHeight": TYPE_FLOAT, 
	
	"Name": TYPE_STRING, "TexFile": TYPE_STRING, "BindEle": TYPE_STRING,
	"Warp": TYPE_STRING, "ShaderFile": TYPE_STRING, "ShaderTex": TYPE_STRING,
	
	"ZEnable": TYPE_BOOL, "MatchGrnd": TYPE_BOOL, "GroundHeight": TYPE_BOOL,
	"IsDummy": TYPE_BOOL, "TileMode": TYPE_BOOL, "UReverse": TYPE_BOOL, "VReverse": TYPE_BOOL,
	"UVExchg": TYPE_BOOL, "NoDownSample": TYPE_BOOL, "ResetLoopEnd": TYPE_BOOL,
	"PSFileVersion": TYPE_BOOL, "CanDoFadeOut": TYPE_BOOL, "InterpolateMode": TYPE_INT,
	"AffByScl": TYPE_BOOL, "RotFromView": TYPE_BOOL, 
	
	"Position": TYPE_VECTOR3, 
	"PSConstValue": TYPE_VECTOR4, "Direction": TYPE_VECTOR4,
	"Color": TYPE_COLOR 
}


func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = [{"name": "GFX Element (Type 211)", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	
	# 1. Obere Parameter
	for param in KNOWN_PARAMS_TOP:
		var has_param = parsed_data.has(param)
		var prefix = "🟢 " if has_param else "🔵 [Fehlt] "
		var type = PARAM_TYPES.get(param, TYPE_STRING)
		props.append({"name": prefix + param, "type": type, "usage": PROPERTY_USAGE_EDITOR})
		
	# --- DER BEARBEITBARE GRID-INSPEKTOR ---
	var w = _get_internal_value("wNumber", TYPE_INT)
	var h = _get_internal_value("hNumber", TYPE_INT)
	var total = w * h
	if total > 0:
		props.append({"name": "🟢 Grid Structure (" + str(total) + " Nodes)", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY})
		for i in range(1, total + 1):
			var node_path = "Grid Node " + str(i) + "/"
			# Erzeugt für jeden Node einen Vektor und einen Color-Picker
			props.append({"name": node_path + "Vector", "type": TYPE_VECTOR3, "usage": PROPERTY_USAGE_EDITOR})
			props.append({"name": node_path + "Color", "type": TYPE_COLOR, "usage": PROPERTY_USAGE_EDITOR})
	
	props.append({"name": "---- RESTLICHE WERTE ----", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY})
	
	# 2. Untere Parameter
	for param in KNOWN_PARAMS_BOTTOM:
		var has_param = parsed_data.has(param)
		var prefix = "🟢 " if has_param else "🔵 [Fehlt] "
		var type = PARAM_TYPES.get(param, TYPE_STRING)
		props.append({"name": prefix + param, "type": type, "usage": PROPERTY_USAGE_EDITOR})

	# 3. Pixel Shader Block
	if parsed_data.has("_ps_consts"):
		var ps_array = parsed_data["_ps_consts"]
		for p in range(ps_array.size()):
			var block = ps_array[p]
			var path = "PS Const Block " + str(p) + "/"
			for param in ["PSConstIndex", "PSConstValue", "PSLoopCount", "PSTargetCount"]:
				var pfx = "🟢 " if block.has(param) else "🔵 "
				props.append({"name": path + pfx + param, "type": PARAM_TYPES.get(param, TYPE_STRING), "usage": PROPERTY_USAGE_EDITOR})

			if block.has("_targets"):
				var targets = block["_targets"]
				for t in range(targets.size()):
					var t_path = path + "Target " + str(t) + "/"
					var tgt = targets[t]
					for param in ["PSInterval", "PSConstValue"]:
						var pfx = "🟢 " if tgt.has(param) else "🔵 "
						props.append({"name": t_path + pfx + param, "type": PARAM_TYPES.get(param, TYPE_STRING), "usage": PROPERTY_USAGE_EDITOR})

	# 4. Keypoints
	if parsed_data.has("_keypoints"):
		var kp_array = parsed_data["_keypoints"]
		for k in range(kp_array.size()):
			var kp = kp_array[k]
			var path = "KeyPoint " + str(k) + "/"
			for param in ["InterpolateMode", "TimeSpan", "Position", "Color", "Scale", "Direction", "Rad_2D", "CtrlMethodCount"]:
				var pfx = "🟢 " if kp.has(param) else "🔵 "
				props.append({"name": path + pfx + param, "type": PARAM_TYPES.get(param, TYPE_STRING), "usage": PROPERTY_USAGE_EDITOR})
				
	# 5. Grid Animations (Base64) - Bleibt als Array!
	if parsed_data.has("_grid_animations"):
		var anims = parsed_data["_grid_animations"]
		if anims.size() > 0:
			props.append({
				"name": "Grid Animations (Base64)",
				"type": TYPE_ARRAY,
				"usage": PROPERTY_USAGE_EDITOR
			})
			
	return props


func _get(property: StringName):
	var prop_str = str(property).replace("🟢 ", "").replace("🔵 ", "").replace("[Fehlt] ", "")
	
	# --- 🚨 SCHUTZSCHALTER GET 🚨 ---
	var is_valid = (prop_str in KNOWN_PARAMS_TOP) or (prop_str in KNOWN_PARAMS_BOTTOM) or prop_str.begins_with("PS Const Block ") or prop_str.begins_with("KeyPoint ") or prop_str.begins_with("Grid Node ") or prop_str.begins_with("Grid Animations")
	if not is_valid: return null
	# --------------------------------
	
	# === Grid Nodes Abfragen (Vector3 & Color) ===
	if prop_str.begins_with("Grid Node "):
		var parts = prop_str.split("/")
		var node_idx = parts[0].trim_prefix("Grid Node ").to_int()
		if parts.size() == 2:
			var sub_prop = parts[1]
			if sub_prop == "Vector":
				var key = "GridVector_" + str(node_idx)
				var raw = parsed_data.get(key, "0.000000 0.000000 0.000000")
				return _space_string_to_vector3(raw)
			elif sub_prop == "Color":
				var key = "dwColor" if node_idx == 1 else "dwColor_" + str(node_idx)
				var raw = parsed_data.get(key, "ffffffff") # Hex Standard für Weiß
				return _hex_to_color(raw)
		return null
		
	if prop_str == "Grid Animations (Base64)":
		return parsed_data.get("_grid_animations", [])
	
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
			if not parsed_data["_ps_consts"][b_idx].has("_targets"): return null
			var tgts = parsed_data["_ps_consts"][b_idx]["_targets"]
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
	var prop_str = str(property).replace("🟢 ", "").replace("🔵 ", "").replace("[Fehlt] ", "")
	
	# --- 🚨 SCHUTZSCHALTER SET 🚨 ---
	var is_valid = (prop_str in KNOWN_PARAMS_TOP) or (prop_str in KNOWN_PARAMS_BOTTOM) or prop_str.begins_with("PS Const Block ") or prop_str.begins_with("KeyPoint ") or prop_str.begins_with("Grid Node ") or prop_str.begins_with("Grid Animations")
	if not is_valid: return false
	# --------------------------------
	
	# === Grid Nodes Speichern ===
	if prop_str.begins_with("Grid Node "):
		var parts = prop_str.split("/")
		var node_idx = parts[0].trim_prefix("Grid Node ").to_int()
		if parts.size() == 2:
			var sub_prop = parts[1]
			if sub_prop == "Vector":
				var key = "GridVector_" + str(node_idx)
				parsed_data[key] = _vector3_to_space_string(value)
				return true
			elif sub_prop == "Color":
				var key = "dwColor" if node_idx == 1 else "dwColor_" + str(node_idx)
				parsed_data[key] = _color_to_hex(value)
				return true
		return false
		
	if prop_str == "Grid Animations (Base64)":
		return false # Base64 belassen wir sicherheitshalber auf Read-Only
	
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
			if not parsed_data["_ps_consts"][b_idx].has("_targets"): return false
			var tgts = parsed_data["_ps_consts"][b_idx]["_targets"]
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
	
	# WICHTIG: Wenn wNumber oder hNumber geändert werden, aktualisieren wir den Editor,
	# damit sofort die exakte Anzahl an Ordnern im Editor generiert wird.
	if param_name == "wNumber" or param_name == "hNumber" or should_notify: 
		notify_property_list_changed()
	return true


# ==========================================
# ====== TRANSLATOR / HELPER =============
# ==========================================

func _get_internal_value(param: String, expected_type: int):
	# Hilfsfunktion, um interne W/H Nummern sauber abzugreifen
	if parsed_data.has(param):
		var val = parsed_data[param]
		if typeof(val) == TYPE_STRING:
			if expected_type == TYPE_INT: return val.to_int()
		return val
	return 0

func _translate_to_godot(param: String, val, expected_type: int):
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

func _translate_to_gfx(param: String, godot_val, expected_type: int):
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
		TYPE_COLOR: return Color(1,1,1,1)
	return null

# --- Standard Übersetzer ---
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

# --- SPEZIAL: GRID / HEX TRANSLATOR (Exklusiv für 210 & 211) ---
func _space_string_to_vector3(v_str: String) -> Vector3:
	# Trennt am Leerzeichen statt am Komma (Grid-Knoten)
	var p = v_str.strip_edges().split(" ", false) 
	if p.size() >= 3: return Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float())
	return Vector3.ZERO

func _vector3_to_space_string(v: Vector3) -> String:
	# Erzeugt wieder "0.000000 0.000000 0.000000" (ohne Kommas)
	return "%.6f %.6f %.6f" % [v.x, v.y, v.z]

func _hex_to_color(hex_str: String) -> Color:
	# Wandelt "ffee200f" von ARGB (Hex) in Godot (RGBA) um
	var hex = hex_str.strip_edges().to_lower()
	if hex.begins_with("0x"): hex = hex.substr(2)
	if hex.length() >= 8:
		var a = hex.substr(0, 2).hex_to_int() / 255.0
		var r = hex.substr(2, 2).hex_to_int() / 255.0
		var g = hex.substr(4, 2).hex_to_int() / 255.0
		var b = hex.substr(6, 2).hex_to_int() / 255.0
		return Color(r, g, b, a)
	return Color.WHITE

func _color_to_hex(c: Color) -> String:
	# Konvertiert Godot Farbe zurück in "ffee200f" Format für deine .gfx Datei
	var a = "%02x" % int(clamp(c.a * 255, 0, 255))
	var r = "%02x" % int(clamp(c.r * 255, 0, 255))
	var g = "%02x" % int(clamp(c.g * 255, 0, 255))
	var b = "%02x" % int(clamp(c.b * 255, 0, 255))
	return (a + r + g + b).to_lower()
