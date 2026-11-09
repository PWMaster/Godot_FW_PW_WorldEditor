@tool
extends RefCounted

# ====================================================
# KeyPoint-Zustand auf der CPU (A3DGFXKeyPointSet::TickAnimation / GetCurKeyPoint)
# ====================================================
# Gegenstück zu gfx_keypoint_shader.gd für Elemente, die sich nicht per Shader steuern lassen:
# gfx_light_130.gd (Licht) und gfx_model_160.gd (Modell).
# Die KeyPoints baut create_id_130.gd (_build_keypoints / _ctrl_to_dict) als Dictionaries:
#   {time_span, interp, pos, dir, color, scale, rad, ctrls: [{type, start, end, ...}]}
#  - InterpolateMode != 0: Mischung KeyPoint i -> i + 1, CtrlMethods ruhen.
#  - InterpolateMode 0: der Zustand läuft weiter, die CtrlMethods wirken analytisch darauf.
#  - Lineare Bewegungen verschieben die Drehzentren mit (ProcData.m_vAxisOff).
#  - GetCurKeyPoint addiert das Scale-Rauschen (CtrlType 109) zum Scale.
# ====================================================

const CurvePath = preload("gfx_curve_path.gd")
const INFINITE_SPAN_SEC = 4294967.295 # TimeSpan -1 = 0xFFFFFFFF ms


# ====================================================
# ZEIT (identisch zur Zeit-Synchronisation der ID_100-Shader)
# ====================================================
static func clock_ms(time_manual: bool, time_ms: float) -> float:
	if time_manual:
		return time_ms
	# Shader-TIME läuft seit Engine-Start und springt nach time_rollover_secs zurück
	var rollover = float(ProjectSettings.get_setting("rendering/limits/time/time_rollover_secs", 3600.0))
	return fmod(Time.get_ticks_msec() / 1000.0, rollover) * 1000.0

# Element-Zeit in ms zur globalen Zeit active_time
static func element_time(active_time: float, global_loop_time: float, local_start: float, local_total: float, repeat_count: int, repeat_delay: float) -> float:
	var f_repeat = float(repeat_count)
	var loop_active_duration = maxf(0.001, local_total - local_start)
	var loop_full_duration = loop_active_duration + maxf(0.0, repeat_delay)
	if local_total <= 0.0:
		return active_time
	var t_global = active_time
	if f_repeat >= 0.0:
		t_global = fmod(active_time, maxf(0.001, global_loop_time))
	var t_since_start = t_global - local_start
	if t_since_start < 0.0:
		return t_global
	var current_loop = floor(t_since_start / loop_full_duration)
	if f_repeat >= 0.0 and current_loop >= f_repeat:
		return t_global
	return local_start + fmod(t_since_start, loop_full_duration)


# ====================================================
# A3DGFXKeyPointSet::TickAnimation / GetCurKeyPoint
# ====================================================
# span_ms = Zeit seit StartTime. Liefert {pos, dir, color, scale, rad}.
static func evaluate(keypoints: Array, span_ms: float) -> Dictionary:
	var state = _kp_state(keypoints[0]) # Resume(): m_KPProcess = KeyPoint 0
	state["noise"] = 0.0
	var axis_off = Vector3.ZERO
	var remaining = span_ms
	var last = keypoints.size() - 1

	for i in range(keypoints.size()):
		var kp: Dictionary = keypoints[i]
		var ts: float = kp["time_span"]
		var infinite = ts < 0.0
		var inside = infinite or remaining < ts or i == last
		var t_in = remaining if inside else ts

		if int(kp["interp"]) != 0:
			# Interpolationsmodus: Mischung KeyPoint i -> i + 1, CtrlMethods ruhen
			if i == last:
				var noise = state["noise"]
				state = _kp_state(kp)
				state["noise"] = noise
			else:
				var portion = 0.0 if infinite else clampf(t_in / maxf(ts, 0.001), 0.0, 1.0)
				_interpolate(state, kp, keypoints[i + 1], portion)
		else:
			# Kein Interpolieren: der Zustand läuft weiter, die CtrlMethods dieses KeyPoints wirken darauf
			var kp_span_sec = INFINITE_SPAN_SEC if infinite else ts / 1000.0
			axis_off = _process_ctrls(kp["ctrls"], state, t_in / 1000.0, kp_span_sec, axis_off)

		if inside:
			break
		remaining -= ts

	# GetCurKeyPoint: Scale + m_fScaleNoise
	state["scale"] += state["noise"]
	state.erase("noise")
	return state

static func _kp_state(kp: Dictionary) -> Dictionary:
	return {"pos": kp["pos"], "dir": kp["dir"], "color": kp["color"], "scale": kp["scale"], "rad": kp["rad"]}

# A3DGFXKeyPointSet::Interpolate (Richtung nur bei enumInterpAll = 1)
static func _interpolate(state: Dictionary, kp1: Dictionary, kp2: Dictionary, f: float) -> void:
	state["color"] = (kp1["color"] as Color).lerp(kp2["color"], f)
	state["rad"] = lerpf(kp1["rad"], kp2["rad"], f)
	state["scale"] = lerpf(kp1["scale"], kp2["scale"], f)
	state["pos"] = (kp1["pos"] as Vector3).lerp(kp2["pos"], f)
	if int(kp1["interp"]) == 1:
		state["dir"] = (kp1["dir"] as Quaternion).slerp(kp2["dir"], f)

# CtrlMethods eines KeyPoints analytisch über die KeyPoint-Zeit t (Sekunden).
# Lineare Bewegungen (100) verschieben auch die Drehzentren (ProcData.m_vAxisOff).
static func _process_ctrls(ctrls: Array, state: Dictionary, t: float, kp_span_sec: float, axis_off: Vector3) -> Vector3:
	var lin = Vector3.ZERO
	var jump = Vector3.ZERO
	var p_rel: Vector3 = state["pos"]

	for c in ctrls:
		var s: float = c["start"]
		var e: float = c["end"]
		# A3DGFXKeyPointCtrlBase::Tick
		if t < s or (e >= 0.0 and s > e):
			continue
		var a0 = s
		var a1 = t if e < 0.0 else minf(t, e)
		var type = int(c["type"])
		var dist = 0.0
		if c.has("vel"):
			# CalcDist: v(t) = Vel + Acc * t
			dist = c["vel"] * (a1 - a0) + 0.5 * c["acc"] * (a1 * a1 - a0 * a0)

		match type:
			100:
				lin += (c["dir"] as Vector3) * dist
			101:
				state["rad"] += dist
			102, 103:
				var axis: Vector3 = c["axis"]
				if axis.length() > 0.000001 and dist != 0.0:
					var q = Quaternion(axis.normalized(), dist)
					var ctr = (c["pos"] as Vector3) + axis_off + jump
					p_rel = q * (p_rel - ctr) + ctr
					if type == 102:
						state["dir"] = (q * (state["dir"] as Quaternion)).normalized()
			104:
				if c["vel"] != 0.0:
					var ctr = (c["pos"] as Vector3) + axis_off + jump
					var r = p_rel - ctr
					var r_len = r.length()
					if r_len > 0.000001:
						p_rel = ctr + r / r_len * maxf(0.0, r_len + dist)
			105:
				var col: Color = state["color"] + (c["delta"] as Color) * (a1 - a0)
				state["color"] = Color(clampf(col.r, 0.0, 1.0), clampf(col.g, 0.0, 1.0), clampf(col.b, 0.0, 1.0), clampf(col.a, 0.0, 1.0))
			106:
				# ScaleChage = (Änderung pro Sekunde, Minimum, Maximum), wie clamp() im Shader
				var sc: Vector3 = c["scale_change"]
				state["scale"] = minf(maxf(state["scale"] + sc.x * (a1 - a0), sc.y), sc.z)
			107:
				var n = _fbm1d(a1 * 1000.0 / maxf(1.0, c["wave_len"]), int(c["octaves"]), c["persistence"])
				var base: Color = c["base_color"]
				state["color"] = Color(base.r, base.g, base.b, clampf(base.a + (n * 2.0 - 1.0) * c["amplitude"] / 255.0, 0.0, 1.0))
			108:
				if int(c["count"]) > 0:
					var col = _stage_value(c["colors"], c["times"], int(c["count"]), a1 * 1000.0)
					if c["alpha_only"]:
						var cur: Color = state["color"]
						state["color"] = Color(cur.r, cur.g, cur.b, col.a)
					else:
						state["color"] = col
			109:
				# Scale-Rauschen, erst GetCurKeyPoint addiert es zum Scale
				state["noise"] = _fbm1d(a1 * 1000.0 / maxf(0.001, c["wave_len"]), int(c["octaves"]), c["persistence"]) * c["amplitude"]
			110:
				# CurveMove: Position wird absolut auf den Pfad gesetzt (Ratio = Zeit / KeyPoint-Dauer)
				var pt = CurvePath.interp_point(c, a1 / maxf(kp_span_sec, 0.000001))
				var new_pos: Vector3 = pt["pos"]
				jump += new_pos - (p_rel + lin)
				p_rel = new_pos - lin
				if c["calc_dir"]:
					state["dir"] = pt["quat"]
			111:
				if int(c["count"]) > 0:
					state["scale"] = _stage_value(c["scales"], c["times"], int(c["count"]), a1 * 1000.0)

	state["pos"] = p_rel + lin
	return axis_off + lin + jump

# A3DGFXCtrlClTrans / A3DGFXCtrlScaleTrans::Process (Zeit in ms): Color- oder float-Stufen
static func _stage_value(values: Array, times: Array, stage_count: int, t_ms: float):
	var count = mini(stage_count, times.size())
	var seg = 0
	var span = t_ms
	while seg < count:
		if span < times[seg]:
			break
		span -= times[seg]
		seg += 1
	var portion = 1.0
	if seg >= count:
		seg = count - 1
	else:
		portion = minf(span / maxf(times[seg], 0.0001), 1.0)
	if values[seg] is Color:
		return (values[seg] as Color).lerp(values[seg + 1], portion)
	return lerpf(values[seg], values[seg + 1], portion)

# Gleiches Rauschen wie in den Shadern (CtrlType 107 / 109)
static func _fbm1d(x: float, octaves: int, persistence: float) -> float:
	var v = 0.0
	var a = 0.5
	for i in range(mini(octaves, 8)):
		v += a * _noise1d(x)
		x *= 2.0
		a *= persistence
	return v

static func _noise1d(p: float) -> float:
	var i = floor(p)
	var f = p - i
	return lerpf(_hash12(i), _hash12(i + 1.0), f * f * (3.0 - 2.0 * f))

static func _hash12(p: float) -> float:
	return fposmod(sin(p * 12.9898) * 43758.5453, 1.0)
