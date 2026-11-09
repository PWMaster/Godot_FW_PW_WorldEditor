@tool
extends Object

# ====================================================
# GFXELEMENTID 130 = ID_ELE_TYPE_LIGHT (A3DGFXLight)
# ====================================================
# Kein Sprite, sondern ein dynamisches D3D-Licht, das Angelica an beleuchtete Modelle gibt
# (AfxSetA3DSkinModelSceneLightInfo / A3DGFXElement::SkinModelRenderAtOnce).
# Godot: OmniLight3D / SpotLight3D / DirectionalLight3D je nach LightType.
# Position, Richtung und Farbe animiert gfx_light_130.gd jeden Frame aus KeyPoints + CtrlMethods
# (gleiche Zeitlogik wie die Shader, ein Licht lässt sich nicht per Shader steuern).
#
# D3D-Dämpfung 1 / (A0 + A1*d + A2*d²) -> Godot energy * d^-attenuation:
# Wert und Steigung stimmen bei halber Range überein.
#
# Basis für KeyPoint-Elemente mit CPU-Treiber (create_id_160 erbt davon):
#   _element_id(), _node_name(), _node_label(), build_node(parent_node, max_group_time)
# ====================================================

const LIGHT_NODE_NAME = "Light_GFX"
const DRIVER_SCRIPT = "gfx_light_130.gd"
const CurvePath = preload("gfx_curve_path.gd")

# A3DLIGHTTYPE (= D3DLIGHTTYPE)
const LIGHT_POINT = 1
const LIGHT_SPOT = 2
const LIGHT_DIRECTIONAL = 3

# ====================================================
# HOOKS FÜR ABGELEITETE ELEMENTE
# ====================================================
func _element_id() -> String:
	return "130"

func _node_name() -> String:
	return LIGHT_NODE_NAME

func _node_label() -> String:
	return "Lichter"

# Baut den Node des Elements (ohne Szene / UndoRedo)
func build_node(parent_node: Node, max_group_time: float) -> Node3D:
	return build_light_node(parent_node, max_group_time)


func execute(root_node: Node):
	var target_nodes = _find_target_nodes(root_node)

	if target_nodes.is_empty():
		push_warning("Keine Nodes mit der ID " + _element_id() + " gefunden!")
		return

	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Create " + _node_name() + " for ID_" + _element_id())

	# 1. Nodes nach Parent (Header) gruppieren
	var header_groups = {}
	for node in target_nodes:
		var parent = node.get_parent()
		if not header_groups.has(parent):
			header_groups[parent] = []
		header_groups[parent].append(node)

	# 2. Für jeden Header die max. Loop-Zeit berechnen und Nodes erzeugen
	for parent in header_groups.keys():
		var group_nodes = header_groups[parent]

		var max_group_time = _get_max_time_for_header(parent)

		if max_group_time <= 0.0:
			max_group_time = 3000.0

		for node in group_nodes:
			_create_element_node(node, root_node, undo_redo, max_group_time)

	undo_redo.commit_action()
	print(_node_label(), " für ", target_nodes.size(), " ID_", _element_id(), "-Nodes erstellt.")


func _get_max_time_for_header(header_node: Node) -> float:
	var max_time = 0.0

	for child in header_node.get_children():
		if child.name.begins_with("Element_"):
			var t_start = 0.0
			var t_total = 0.0
			var is_endless = false

			var data = child.get("parsed_data")
			if typeof(data) == TYPE_DICTIONARY:
				t_start = float(data.get("StartTime", 0.0))
				t_total = t_start
				if data.has("_keypoints"):
					for kp in data["_keypoints"]:
						if kp.has("TimeSpan"):
							var ts = float(kp["TimeSpan"])
							if ts == -1.0:
								is_endless = true
							elif ts > 0.0:
								t_total += ts
			else:
				if child.get("StartTime") != null:
					t_start = float(child.get("StartTime"))
					t_total = t_start

				var kp_idx = 0
				while true:
					var ts_val = child.get("KeyPoint " + str(kp_idx) + "/TimeSpan")
					if ts_val != null:
						var ts = float(ts_val)
						if ts == -1.0:
							is_endless = true
						elif ts > 0.0:
							t_total += ts
						kp_idx += 1
					else:
						break

			if not is_endless and t_total > max_time:
				max_time = t_total

	return max_time

func _find_target_nodes(current_node: Node) -> Array:
	var results = []
	if current_node.name.contains("_ID_" + _element_id()):
		results.append(current_node)

	for child in current_node.get_children():
		results.append_array(_find_target_nodes(child))

	return results

func _gather_ctrl_nodes(node: Node) -> Array:
	var results = []
	for child in node.get_children():
		if child.name == _node_name():
			continue

		var has_params = false
		if not _get_node_params(child).is_empty():
			has_params = true
			results.append(child)

		if not has_params:
			results.append_array(_gather_ctrl_nodes(child))

	return results

func _get_node_params(child: Node) -> Dictionary:
	if child.get_script() != null:
		var constants = child.get_script().get_script_constant_map()
		if constants.has("KNOWN_PARAMS"): return constants["KNOWN_PARAMS"]
		if constants.has("PARAMS"): return constants["PARAMS"]
	return {}

func _create_element_node(parent_node: Node3D, root_node: Node, undo_redo: EditorUndoRedoManager, max_group_time: float):
	if parent_node.has_node(NodePath(_node_name())):
		return

	var node = build_node(parent_node, max_group_time)
	if node == null:
		return

	undo_redo.add_do_method(parent_node, "add_child", node)
	undo_redo.add_do_property(node, "owner", root_node)
	undo_redo.add_undo_method(parent_node, "remove_child", node)
	undo_redo.add_do_reference(node)


# ====================================================
# BAUT DAS LICHT (ohne Szene / UndoRedo -> auch für Tests nutzbar)
# ====================================================
func build_light_node(parent_node: Node, max_group_time: float) -> Light3D:
	var parsed_data = parent_node.get("parsed_data")
	if typeof(parsed_data) != TYPE_DICTIONARY:
		return null

	# LightType roh aus parsed_data (1 = Point, 2 = Spot, 3 = Directional)
	var light_type = int(str(parsed_data.get("LightType", str(LIGHT_POINT))))
	# Untypisiert: Omni/Spot-Felder und die Treiber-Variablen kennt Light3D nicht
	var light
	match light_type:
		LIGHT_SPOT:
			light = SpotLight3D.new()
		LIGHT_DIRECTIONAL:
			light = DirectionalLight3D.new()
		_:
			light = OmniLight3D.new()
			light_type = LIGHT_POINT
	light.name = LIGHT_NODE_NAME
	light.shadow_enabled = false
	light.light_bake_mode = Light3D.BAKE_DISABLED

	# ====================================================
	# STATISCHE LICHTPARAMETER (A3DLIGHTPARAM)
	# ====================================================
	var range_val = _float(parsed_data, "Range", 10.0)
	# Alle drei Dämpfungswerte stehen in der .gfx unter "Attenuation0:" (Formatstring-Fehler in A3DGFXLight.cpp)
	var att = [_float(parsed_data, "Attenuation0", 0.0), _float(parsed_data, "Attenuation0_2", 0.1), _float(parsed_data, "Attenuation0_3", 0.0)]
	var inner_use = _as_bool(parsed_data.get("InnerUse", "0"))
	if inner_use:
		# A3DGFXElement::SkinModelRenderAtOnce: vPtAtten = (0, 6 / Range, 0), Farbe = Diffuse
		att = [0.0, 6.0 / maxf(range_val, 0.001), 0.0]
	var fit = _fit_attenuation(range_val, att)

	if light is OmniLight3D:
		light.omni_range = range_val
		light.omni_attenuation = fit["decay"]
	elif light is SpotLight3D:
		light.spot_range = range_val
		light.spot_attenuation = fit["decay"]
		# Phi = voller Außenkegel in Grad (drawSpot: DEG2RAD(Phi) / 2), Theta (Innenkegel) kennt Godot nicht
		light.spot_angle = clampf(_float(parsed_data, "Phi", 90.0) * 0.5, 0.01, 179.9)
		light.spot_angle_attenuation = _spot_attenuation(_float(parsed_data, "FallOff", 1.0))

	# Specular-Farbe -> Godot-Specular-Stärke (D3D-Standard: schwarz = kein Glanz)
	var spec = _argb_to_color(str(parsed_data.get("Specular", "0")))
	light.light_specular = maxf(spec.r, maxf(spec.g, spec.b))

	light.set_script(load(_driver_path(DRIVER_SCRIPT)))
	_apply_time_settings(light, parsed_data, max_group_time)
	light.Light_Type = light_type
	light.Energy_Base = 1.0 if light_type == LIGHT_DIRECTIONAL else fit["energy"]
	light.Use_Alpha_Energy = not inner_use
	light.keypoints = _build_keypoints(parent_node, parsed_data)

	# Startzustand für den Editor (Licht am ersten KeyPoint)
	if not light.keypoints.is_empty():
		var kp0: Dictionary = light.keypoints[0]
		light.position = kp0["pos"]
		light.light_color = Color(kp0["color"].r, kp0["color"].g, kp0["color"].b)
	return light


# ====================================================
# ZEITEINSTELLUNGEN DES TREIBERS (wie bei den Shadern)
# ====================================================
func _apply_time_settings(driver: Node, parsed_data: Dictionary, max_group_time: float) -> void:
	var start_time = float(parsed_data.get("StartTime", 0.0))
	var local_total_time = start_time
	var is_endless = false
	for kp_block in parsed_data.get("_keypoints", []):
		if kp_block.has("TimeSpan"):
			var ts = float(kp_block["TimeSpan"])
			if ts == -1:
				is_endless = true
			elif ts > 0:
				local_total_time += ts
	if local_total_time <= start_time and not is_endless:
		local_total_time = start_time + 3000.0

	driver.GlobalLoopTime = max_group_time
	driver.LocalStartTime = start_time
	driver.LocalTotalTime = local_total_time
	driver.Is_Endless = is_endless
	driver.RepeatCount = int(parsed_data.get("RepeatCount", 1))
	driver.RepeatDelay = float(parsed_data.get("RepeatDelay", 0.0))

# Treiber-Skript liegt neben diesem Skript (res://addons/PWE-Manager/GFX/...)
func _driver_path(file_name: String) -> String:
	return get_script().resource_path.get_base_dir().path_join(file_name)


# ====================================================
# KEYPOINTS + CTRLMETHODS FÜR DIE TREIBER (gfx_keypoint_eval.gd)
# ====================================================
# Werte roh aus parsed_data (InterpolateMode: 0 = keine, 1 = alles, 2 = ohne Richtung)
func _build_keypoints(parent_node: Node, parsed_data: Dictionary) -> Array:
	var ctrl_methods = []
	for child in _gather_ctrl_nodes(parent_node):
		if child.name.findn("Affector") == -1:
			ctrl_methods.append(child)

	var result = []
	var ctrl_idx = 0
	for kp_block in parsed_data.get("_keypoints", []):
		var kp = {
			"time_span": float(kp_block.get("TimeSpan", 0.0)), # -1 = endlos
			"interp": int(str(kp_block.get("InterpolateMode", "0"))),
			"pos": _string_to_vector3(str(kp_block.get("Position", "0, 0, 0"))),
			"color": _argb_to_color(str(kp_block.get("Color", "-1"))),
			"scale": float(kp_block.get("Scale", 1.0)),
			"dir": _string_to_quat(str(kp_block.get("Direction", "0, 0, 0, 1"))),
			"rad": float(kp_block.get("Rad_2D", 0.0)),
			"ctrls": [],
		}
		for i in range(int(kp_block.get("CtrlMethodCount", 0))):
			if ctrl_idx < ctrl_methods.size():
				var d = _ctrl_to_dict(ctrl_methods[ctrl_idx])
				if not d.is_empty():
					kp["ctrls"].append(d)
				ctrl_idx += 1
		result.append(kp)
	return result

func _ctrl_to_dict(child: Node) -> Dictionary:
	var ct = str(child.get("CtrlType"))
	var d = {"type": int(ct), "start": float(child.get("StartTime")), "end": float(child.get("EndTime"))}
	match ct:
		"100":
			d["dir"] = child.get("Dir")
			d["vel"] = float(child.get("Vel"))
			d["acc"] = float(child.get("Acc"))
		"101":
			d["vel"] = float(child.get("Vel"))
			d["acc"] = float(child.get("Acc"))
		"102", "103":
			d["pos"] = child.get("Pos")
			d["axis"] = child.get("Axis")
			d["vel"] = float(child.get("Vel"))
			d["acc"] = float(child.get("Acc"))
		"104":
			d["pos"] = child.get("Pos")
			d["vel"] = float(child.get("Vel"))
			d["acc"] = float(child.get("Acc"))
		"105":
			# gfx_ctrl_105 legt 'R, G, B, A' als Color(G, B, A, R) ab -> zurück nach RGBA
			var cd: Color = child.get("ColorDelta")
			d["delta"] = Color(cd.a, cd.r, cd.g, cd.b)
		"106":
			# (Änderung pro Sekunde, Minimum, Maximum)
			d["scale_change"] = child.get("ScaleChage")
		"107":
			d["base_color"] = child.get("BaseColor")
			d["amplitude"] = float(child.get("Amplitude"))
			d["wave_len"] = float(child.get("WaveLen"))
			d["persistence"] = float(child.get("Persistence"))
			d["octaves"] = int(child.get("OctaveNum"))
		"108":
			# gfx_ctrl_108 kennt bis zu 5 Übergänge (Color .. Color_6, TimeSpan .. TimeSpan_5)
			var count = clampi(int(child.get("Count")), 0, 5)
			var colors = [child.get("Color")]
			var times = []
			for k in range(count):
				colors.append(child.get("Color_" + str(k + 2)))
				times.append(float(child.get("TimeSpan" if k == 0 else "TimeSpan_" + str(k + 1))))
			d["colors"] = colors
			d["times"] = times
			d["count"] = count
			d["alpha_only"] = child.get("AlphaOnly") == true
		"109":
			d["amplitude"] = float(child.get("Amplitude"))
			d["wave_len"] = float(child.get("WaveLen"))
			d["persistence"] = float(child.get("Persistence"))
			d["octaves"] = int(child.get("OctaveNum"))
		"110":
			var verts = []
			var pos_data = child.get("Pos_Array")
			if typeof(pos_data) == TYPE_ARRAY or typeof(pos_data) == TYPE_PACKED_VECTOR3_ARRAY:
				for p in pos_data:
					verts.append(p if typeof(p) == TYPE_VECTOR3 else Vector3.ZERO)
			var path = CurvePath.gen_path(verts)
			if path.is_empty():
				return {} # < 3 Punkte: GenPath baut keinen Pfad, Process tut nichts
			d["points"] = path["points"]
			d["ratios"] = path["ratios"]
			d["quats"] = path["quats"]
			d["calc_dir"] = child.get("CalcDir") == true
		"111":
			# gfx_ctrl_111 kennt bis zu 5 Übergänge (Scale .. Scale_6, TimeSpan .. TimeSpan_5)
			var count = clampi(int(child.get("Count")), 0, 5)
			var scales = [float(child.get("Scale"))]
			var times = []
			for k in range(count):
				scales.append(float(child.get("Scale_" + str(k + 2))))
				times.append(float(child.get("TimeSpan" if k == 0 else "TimeSpan_" + str(k + 1))))
			d["scales"] = scales
			d["times"] = times
			d["count"] = count
		_:
			return {}
	return d


# ====================================================
# HELFER
# ====================================================
# 1 / (A0 + A1*d + A2*d²) ≈ energy * d^-decay mit gleichem Wert und gleicher Steigung bei d = Range / 2
func _fit_attenuation(range_val: float, att: Array) -> Dictionary:
	var d = maxf(range_val * 0.5, 0.001)
	var denom = att[0] + att[1] * d + att[2] * d * d
	if denom <= 0.000001:
		return {"decay": 0.0, "energy": 1.0}
	var decay = (att[1] * d + 2.0 * att[2] * d * d) / denom
	return {"decay": decay, "energy": pow(d, decay) / denom}

# D3D: ((cos a - cos phi) / (1 - cos phi))^Falloff, Godot: 1 - rim^x -> gleich bei halbem Kegel
func _spot_attenuation(falloff: float) -> float:
	if falloff <= 0.001:
		return 64.0 # Falloff 0 = harte Kante
	return clampf(log(1.0 / (1.0 - pow(0.5, falloff))) / log(2.0), 0.01, 64.0)

func _float(data: Dictionary, key: String, default_value: float) -> float:
	return float(data[key]) if data.has(key) else default_value

func _as_bool(value) -> bool:
	var s = str(value).strip_edges().to_lower()
	return s == "1" or s == "true"

func _string_to_vector3(v_str: String) -> Vector3:
	var p = v_str.replace(" ", "").split(",")
	if p.size() >= 3: return Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float())
	return Vector3.ZERO

func _string_to_quat(v_str: String) -> Quaternion:
	var p = v_str.replace(" ", "").split(",")
	if p.size() >= 4:
		var q = Quaternion(p[0].to_float(), p[1].to_float(), p[2].to_float(), p[3].to_float())
		if q.length() > 0.000001:
			return q.normalized()
	return Quaternion.IDENTITY

func _argb_to_color(val_str: String) -> Color:
	var u = val_str.to_int() & 0xFFFFFFFF
	return Color(((u >> 16) & 0xFF) / 255.0, ((u >> 8) & 0xFF) / 255.0, (u & 0xFF) / 255.0, ((u >> 24) & 0xFF) / 255.0)
