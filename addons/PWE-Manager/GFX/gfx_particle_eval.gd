@tool
extends RefCounted

# ====================================================
# Partikel eines Partikel-Elements (120 - 125) auf der CPU, für die Dummies an den Partikeln
# (gfx_dummy_particles.gd). Dieselbe Rechnung wie der Vertex-Shader aus create_id_120.gd
# (emitter_state, eval_particle, Emission -> Slot), Zeile für Zeile übertragen, mit dem
# gleichen Zufall (32-Bit-Hash je Emission und Schlüssel). Die Werte kommen aus dem
# Partikel-Material (Uniforms, sonst deren Standardwerte); was der Shader-Generator nur zur
# Bauzeit weiß (welche CtrlMethods / Affectors, KeyPoint-Zeiten), steht in info
# (create_id_120.gd, cpu_info()).
# Zeiten wie im Shader: Element-Zeit in ms, Partikel-Alter und Emitter-Zeit in Sekunden.
# ====================================================

const KP = preload("gfx_keypoint_eval.gd")
const M32 = 0xFFFFFFFF
const AXIS_X = Vector3(1.0, 0.0, 0.0)
const AXIS_Y = Vector3(0.0, 1.0, 0.0)
const AXIS_Z = Vector3(0.0, 0.0, 1.0)

var info: Dictionary
var _mat: ShaderMaterial
var _u = {} # deklarierte Uniforms -> Wert (beim Erstellen gelesen)
var _seed = 0
var _fixed_state = null # emitter_state ohne CtrlMethods: zu jeder Zeit gleich


func _init(mat: ShaderMaterial, p_info: Dictionary) -> void:
	_mat = mat
	info = p_info
	# Standardwerte aus dem Shader-Code: RenderingServer kennt sie erst nach dem Kompilieren
	# (headless nie)
	var defaults = {}
	var re = RegEx.create_from_string("uniform\\s+\\w+\\s+(\\w+)\\s*(?:\\[\\s*\\d+\\s*\\])?\\s*(?::[^=;]*)?=\\s*([^;]+);")
	for m in re.search_all(mat.shader.code):
		defaults[m.get_string(1)] = _parse_glsl(m.get_string(2).strip_edges())
	for entry in mat.shader.get_shader_uniform_list():
		var n: String = entry["name"]
		var v = mat.get_shader_parameter(n)
		if v == null:
			v = defaults.get(n)
		_u[n] = v
	_seed = int(_val("Random_Seed", 0))
	if info.get("ctrls", []).is_empty() and info.get("orbits", []).is_empty():
		_fixed_state = emitter_state(0.0)

# GLSL-Wert aus dem Shader-Code: true / false, Zahl, vecN(...)
static func _parse_glsl(s: String):
	if s == "true" or s == "false":
		return s == "true"
	if s.begins_with("vec"):
		var nums = s.substr(s.find("(") + 1).trim_suffix(")").split(",")
		var f = []
		for x in nums:
			f.append(float(x))
		match f.size():
			2: return Vector2(f[0], f[1])
			3: return Vector3(f[0], f[1], f[2])
			4: return Vector4(f[0], f[1], f[2], f[3])
		return null
	if s.is_valid_int():
		return int(s)
	if s.is_valid_float():
		return float(s)
	return null

# Uniform, falls deklariert, sonst der Ersatzwert (wie _u() im Generator)
func _val(n: String, fallback):
	if _u.has(n) and _u[n] != null:
		return _u[n]
	return fallback

func _has(n: String) -> bool:
	return _u.has(n)

func _f(n: String, fallback: float) -> float:
	return float(_val(n, fallback))

func _b(n: String, fallback: bool) -> bool:
	return bool(_val(n, fallback))

func _v3(n: String, fallback: Vector3) -> Vector3:
	var v = _val(n, fallback)
	return v if v is Vector3 else fallback

func _v4(n: String, fallback: Vector4) -> Vector4:
	return _to_v4(_val(n, fallback))

static func _to_v4(v) -> Vector4:
	if v is Vector4:
		return v
	if v is Color:
		return Vector4(v.r, v.g, v.b, v.a)
	if v is Quaternion:
		return Vector4(v.x, v.y, v.z, v.w)
	if v is Plane:
		return Vector4(v.normal.x, v.normal.y, v.normal.z, v.d)
	return Vector4(1.0, 1.0, 1.0, 1.0)

static func _q(v: Vector4) -> Quaternion:
	return Quaternion(v.x, v.y, v.z, v.w)


# ====================================================
# ZEIT UND EMISSION (vertex() des Shaders)
# ====================================================
# Aktive Partikel zur Header-Zeit active_time (ms): je Slot null oder der Zustand aus eval()
# samt "e_idx" und "age"
func particles(active_time: float) -> Array:
	var pool = int(_val("Pool_Size", 0))
	var out = []
	out.resize(maxi(pool, 0))
	var b_start = _f("StartTime", _f("LocalStartTime", 0.0))
	var local_start = _f("LocalStartTime", 0.0)
	var local_total = _f("LocalTotalTime", 0.0)
	var v_time = KP.element_time(active_time, _f("GlobalLoopTime", 3000.0), b_start, local_total, int(_val("RepeatCount", 1)), _f("RepeatDelay", 0.0))
	var t_now = maxf(0.0, (v_time - local_start) * 0.001)
	var elem_active = _b("Is_Endless", false) or (v_time >= local_start and v_time <= local_total)
	var rate = _f("EmissionRate", 0.0)
	var ttl = _f("TTL", 0.0)
	if not (_b("Emitter_Enabled", true) and elem_active and pool > 0 and rate > 0.0 and ttl > 0.0):
		return out
	var emitted = floor(t_now * rate + 0.0001)
	var quota = int(_val("Quota", -1))
	if quota > 0:
		emitted = minf(emitted, float(quota))
	var e_last = emitted - 1.0
	var en = emitter_state(t_now) # Emitter jetzt: für alle Partikel gleich
	for slot in pool:
		if e_last < slot:
			continue
		var e_idx = slot + pool * floor((e_last - slot) / pool)
		var t_emit = (e_idx + 1.0) / rate
		var age = t_now - t_emit
		if age < 0.0 or age >= ttl:
			continue
		var p = eval(e_idx, age, t_emit, t_now, en)
		p["e_idx"] = e_idx
		p["age"] = age
		# Für Facing: Flugrichtung aus der Position kurz davor (wie im Shader)
		if _b("Facing", false):
			var age_prev = maxf(0.0, age - 0.02)
			var o = eval(e_idx, age_prev, t_emit, t_emit + age_prev)
			var md: Vector3 = p["pos"] - o["pos"]
			p["move_dir"] = md if md.length() > 0.000001 else p["move"]
		out[slot] = p
	return out


# ====================================================
# ZUFALL / QUATERNIONEN (wie im Shader, ohne Normierungs-Prüfung)
# ====================================================
static func _mul32(a: int, b: int) -> int:
	return (a * (b & 0xFFFF) + (((a * (b >> 16)) & 0xFFFF) << 16)) & M32

func rnd(idx: float, k: float) -> float:
	var h = (_mul32(int(idx) & M32, 747796405) + _mul32(int(k) & M32, 2891336453) + _mul32(_seed & M32, 277803737)) & M32
	h ^= h >> 16
	h = _mul32(h, 2246822519)
	h ^= h >> 13
	h = _mul32(h, 3266489917)
	h ^= h >> 16
	return float(h) / 4294967295.0

func srnd(idx: float, k: float) -> float:
	return rnd(idx, k) * 2.0 - 1.0

static func qmul(a: Quaternion, b: Quaternion) -> Quaternion:
	var av = Vector3(a.x, a.y, a.z)
	var bv = Vector3(b.x, b.y, b.z)
	var v = a.w * bv + b.w * av + av.cross(bv)
	return Quaternion(v.x, v.y, v.z, a.w * b.w - av.dot(bv))

static func qaxis(axis: Vector3, angle: float) -> Quaternion:
	var l = axis.length()
	if l < 0.000001:
		return Quaternion(0.0, 0.0, 0.0, 1.0)
	var a = axis / l * sin(angle * 0.5)
	return Quaternion(a.x, a.y, a.z, cos(angle * 0.5))

static func qrot(q: Quaternion, v: Vector3) -> Vector3:
	var u = Vector3(q.x, q.y, q.z)
	return v + 2.0 * u.cross(u.cross(v) + q.w * v)

# A3DParticleEmitter::GenDirection: +Z, zufällig um bis zu angle gekippt
func gen_direction(e_idx: float, is_bind: bool, parent_rot: Quaternion, angle: float) -> Vector3:
	var d = AXIS_Z
	if angle != 0.0:
		var az = rnd(e_idx, 1.0) * TAU
		d = qrot(qaxis(Vector3(cos(az), sin(az), 0.0), rnd(e_idx, 2.0) * angle), d)
	return d if is_bind else qrot(parent_rot, d)

static func _rgb2hsv(c: Vector3) -> Vector3:
	var k = Vector4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0)
	var p = Vector4(c.z, c.y, k.w, k.z).lerp(Vector4(c.y, c.z, k.x, k.y), 1.0 if c.z <= c.y else 0.0)
	var q = Vector4(p.x, p.y, p.w, c.x).lerp(Vector4(c.x, p.y, p.z, p.x), 1.0 if p.x <= c.x else 0.0)
	var d = q.x - minf(q.w, q.y)
	return Vector3(absf(q.z + (q.w - q.y) / (6.0 * d + 1.0e-10)), d / (q.x + 1.0e-10), q.x)

static func _hsv2rgb(c: Vector3) -> Vector3:
	var p = Vector3(absf(fposmod(c.x + 1.0, 1.0) * 6.0 - 3.0), absf(fposmod(c.x + 2.0 / 3.0, 1.0) * 6.0 - 3.0), absf(fposmod(c.x + 1.0 / 3.0, 1.0) * 6.0 - 3.0))
	var t = (p - Vector3.ONE).clamp(Vector3.ZERO, Vector3.ONE)
	return c.z * Vector3.ONE.lerp(t, c.y)


# ====================================================
# EMITTER (GetCurKeyPoint): KeyPoint 0 + CtrlMethods zur Element-Zeit (Sekunden)
# ====================================================
func emitter_state(t_elem: float) -> Dictionary:
	if _fixed_state != null:
		return _fixed_state
	var origin = _v3("KP_0_Position", Vector3.ZERO) if info.get("origin_pos", false) else Vector3.ZERO
	var e_pos = origin
	var e_rot = _q(_v4("KP_0_Direction", Vector4(0.0, 0.0, 0.0, 1.0))) if _has("KP_0_Direction") else Quaternion(0.0, 0.0, 0.0, 1.0)
	var e_scale = _f("KP_0_Scale", 1.0)
	var e_rad = _f("KP_0_Rad_2D", 0.0)
	var e_alpha = _v4("KP_0_Color", Vector4.ONE).w if _has("KP_0_Color") else 1.0
	var ctrl_offset = Vector3.ZERO
	for c in info.get("ctrls", []):
		var p: String = c["p"]
		var tr = _ctrl_time(p, t_elem, float(c["base"]), float(c["dur"]))
		var t_run: float = tr[0]
		match str(c["t"]):
			"100":
				var dv = _v3(p + "Dir", Vector3.ZERO)
				var dir = dv.normalized() if dv.length() > 0.0001 else Vector3.ZERO
				if not c.get("blocked", false):
					ctrl_offset += dir * (_f(p + "Vel", 0.0) * t_run + 0.5 * _f(p + "Acc", 0.0) * t_run * t_run)
			"101":
				e_rad += _f(p + "Vel", 0.0) * t_run + 0.5 * _f(p + "Acc", 0.0) * t_run * t_run
			"104":
				var diff = origin - _v3(p + "Pos", Vector3.ZERO)
				var dir = diff.normalized() if diff.length() > 0.0001 else Vector3.ZERO
				if not c.get("blocked", false):
					ctrl_offset += dir * (_f(p + "Vel", 0.0) * t_run + 0.5 * _f(p + "Acc", 0.0) * t_run * t_run)
			"105":
				var cd = _argb(_v4(p + "ColorDelta", Vector4.ZERO))
				e_alpha = clampf(e_alpha + cd.w * t_run, 0.0, 1.0)
			"106":
				var key = p + ("ScaleChage" if _has(p + "ScaleChage") else "ScaleChange")
				if _has(key):
					var sc = _v3(key, Vector3.ZERO)
					e_scale = clampf(e_scale + sc.x * t_run, sc.y, sc.z)
			"107":
				var n = KP._fbm1d(t_run * maxf(0.001, _f(p + "WaveLen", 1.0)), int(_val(p + "OctaveNum", 1)), _f(p + "Persistence", 0.5))
				var flicker = maxf(0.0, 1.0 + (n - 0.5) * _f(p + "Amplitude", 0.0) * 0.001 * 2.0)
				e_alpha = clampf(_v4(p + "BaseColor", Vector4.ONE).w * flicker, 0.0, 1.0)
			"108":
				var st = _stage(p, "Color", t_run * 1000.0)
				if st != null and st[0] > 0:
					e_alpha = clampf(_to_v4(st[1]).w, 0.0, 1.0)
			"109":
				var n = KP._fbm1d((t_run * 1000.0) / maxf(0.001, _f(p + "WaveLen", 1.0)), int(_val(p + "OctaveNum", 1)), _f(p + "Persistence", 0.5))
				e_scale += n * _f(p + "Amplitude", 0.0)
			"110":
				var arr = _val(p + "Type_110_Pos_Array", null)
				var count = arr.size() if arr != null else 0
				if count > 1:
					var duration: float = tr[1]
					var progress = clampf(t_run / duration, 0.0, 1.0) if duration > 0.001 else 0.0
					var f_idx = progress * (count - 1)
					var i0 = int(floor(f_idx))
					var i1 = mini(i0 + 1, count - 1)
					ctrl_offset += (arr[i0] as Vector3).lerp(arr[i1], f_idx - floor(f_idx))
			"111":
				var st = _stage(p, "Scale", t_run * 1000.0)
				if st != null and st[0] > 0:
					e_scale = float(st[1])
	# 3D-Orbit und Achsrotation (102 / 103) auf die Emitter-Position
	for c in info.get("orbits", []):
		var p: String = c["p"]
		var t_run = _ctrl_time(p, t_elem, float(c["base"]), float(c["dur"]))[0]
		var angle = _f(p + "Vel", 0.0) * t_run + 0.5 * _f(p + "Acc", 0.0) * t_run * t_run
		var q_orbit = qaxis(_v3(p + "Axis", AXIS_Y), angle)
		var ctr = _v3(p + "Pos", Vector3.ZERO)
		e_pos = qrot(q_orbit, e_pos - ctr) + ctr
		if str(c["t"]) == "102":
			e_rot = qmul(q_orbit, e_rot)
	e_pos += ctrl_offset
	return {"pos": e_pos, "rot": e_rot, "scale": e_scale, "rad": e_rad, "alpha": e_alpha}

# Laufzeit einer CtrlMethod in ihrem KeyPoint -> [t_run, duration]
func _ctrl_time(p: String, t_elem: float, kp_base: float, kp_dur: float) -> Array:
	var kp_time = maxf(0.0, t_elem - kp_base)
	var start = _f(p + "StartTime", 0.0)
	var end = _f(p + "EndTime", -1.0)
	var t_run = maxf(0.0, kp_time - start)
	var duration = 0.0
	if end >= 0.0:
		duration = maxf(0.0001, end - start)
		t_run = minf(t_run, maxf(0.0, end - start))
	elif kp_dur != -1.0:
		duration = maxf(0.0001, kp_dur - start)
		t_run = minf(t_run, maxf(0.0, kp_dur - start))
	return [t_run, duration]

# gfx_ctrl_105 legt 'R, G, B, A' als Color(G, B, A, R) ab -> .argb ergibt wieder RGBA
static func _argb(v: Vector4) -> Vector4:
	return Vector4(v.w, v.x, v.y, v.z)

# Mehrstufige Übergänge (CtrlType 108 Farbe / 111 Scale) -> [stage_cnt, Wert] oder null
func _stage(p: String, base: String, t_ms: float):
	var vals = []
	for k in range(1, 7):
		var n = p + (base if k == 1 else base + "_" + str(k))
		if not _has(n):
			break
		vals.append(_val(n, null))
	if vals.is_empty():
		return null
	var times = []
	for k in range(1, vals.size()):
		var n = p + ("TimeSpan" if k == 1 else "TimeSpan_" + str(k))
		if not _has(n):
			break
		times.append(_f(n, 0.0))
	var stages = mini(vals.size() - 1, times.size())
	var stage_cnt = int(_val(p + "Count", 0)) if _has(p + "Count") else 0
	var out = vals[0]
	var stage_t = 0.0
	var done = false
	for s in stages:
		if not done and stage_cnt >= s + 1:
			var ts = maxf(0.0001, times[s])
			if t_ms <= stage_t + ts:
				out = _mix(vals[s], vals[s + 1], clampf((t_ms - stage_t) / ts, 0.0, 1.0))
				done = true
			stage_t += ts
	if stages > 0 and not done:
		for s in stages:
			if stage_cnt == s + 1:
				out = vals[s + 1]
		if stage_cnt > stages:
			out = vals[stages]
	return [stage_cnt, out]

static func _mix(a, b, f: float):
	if a is float or a is int:
		return lerpf(float(a), float(b), f)
	return _to_v4(a).lerp(_to_v4(b), f)


# ====================================================
# EIN PARTIKEL: InitParticle (Emitter) + ApplyMotion + Affectors (eval_particle)
# ====================================================
# -> {pos, move, rot (Ausrichtung samt Rad_2D und Bind), size, col (Vector4), k_scale, k_alpha}
# Lage im Raum des Partikel-Nodes (wie w_pos im Shader).
func eval(e_idx: float, age: float, t_emit: float, t_now: float, en = null) -> Dictionary:
	var ee = emitter_state(t_emit)
	if en == null:
		en = emitter_state(t_now)
	var is_bind = _b("IsBind", true)
	var scale_no_off = _b("ScaleNoOff", false)
	var ee_rot: Quaternion = ee["rot"]
	var ee_scale: float = ee["scale"]
	var ee_world: Vector3 = ee["pos"] if scale_no_off else ee["pos"] * ee_scale
	var en_world: Vector3 = en["pos"] if scale_no_off else en["pos"] * en["scale"]
	var par_dir = qmul(ee_rot, _q(_v4("ParIniDir_Quat", Vector4(0.0, 0.0, 0.0, 1.0))))

	var init = _emitter_init(e_idx, is_bind, ee_rot, ee_scale, ee_world, par_dir)
	var p_rel: Vector3 = init[0]
	var move_dir: Vector3 = init[1]
	var p_rot: Quaternion = init[2]
	var lin = Vector3.ZERO
	var p_size = lerpf(_f("ScaleMin", 1.0), _f("ScaleMax", 1.0), rnd(e_idx, 3.0))
	var p_rad = lerpf(_f("RotMin", 0.0), _f("RotMax", 0.0), rnd(e_idx, 4.0))
	var p_noise = 0.0

	# GenColor
	var col_min = _v4("ColorMin", Vector4.ONE)
	var col_max = _v4("ColorMax", Vector4.ONE)
	var p_col: Vector4
	if info.get("hsv", false) and _b("IsUseHSVInterp", false):
		var f = rnd(e_idx, 5.0)
		var h_min = _rgb2hsv(Vector3(col_min.x, col_min.y, col_min.z))
		var h_max = _rgb2hsv(Vector3(col_max.x, col_max.y, col_max.z))
		var hue = fposmod(h_min.x * f + (1.0 + h_max.x) * (1.0 - f), 1.0) if h_min.x > h_max.x else h_min.x * f + h_max.x * (1.0 - f)
		var sv = Vector2(h_min.y, h_min.z) * f + Vector2(h_max.y, h_max.z) * (1.0 - f)
		var rgb = _hsv2rgb(Vector3(hue, sv.x, sv.y))
		p_col = Vector4(rgb.x, rgb.y, rgb.z, col_min.w * f + col_max.w * (1.0 - f))
	else:
		p_col = Vector4(lerpf(col_min.x, col_max.x, rnd(e_idx, 5.0)), lerpf(col_min.y, col_max.y, rnd(e_idx, 6.0)), lerpf(col_min.z, col_max.z, rnd(e_idx, 7.0)), lerpf(col_min.w, col_max.w, rnd(e_idx, 8.0)))
		p_col.w *= ee["alpha"]

	# ApplyMotion: Eigengeschwindigkeit + Beschleunigung
	lin += move_dir * (_f("Speed", 0.0) * age + 0.5 * _f("ParAcc", 0.0) * age * age)
	lin += _v3("AccDir", Vector3(0.0, 0.0, -1.0)) * (0.5 * _f("Acc", 0.0) * age * age)

	var axis_off = Vector3.ZERO
	var axis_p: String = info.get("axis_prefix", "")
	if axis_p != "" and not is_bind:
		var ap = _v3(axis_p + "Pos", Vector3.ZERO)
		axis_off = qrot(ee_rot, ap) - ap

	for a in info.get("affectors", []):
		var p: String = a["p"]
		var a_start = _f(p + "StartTime", 0.0)
		var a_end = _f(p + "EndTime", -1.0)
		if not (age >= a_start and (a_end < 0.0 or a_start <= a_end)):
			continue
		var a0 = a_start
		var a1 = age if a_end < 0.0 else minf(age, a_end)
		var ct = str(a["t"])
		var dist = 0.0
		if ct in ["100", "101", "102", "103", "104"]:
			dist = _f(p + "Vel", 0.0) * (a1 - a0) + 0.5 * _f(p + "Acc", 0.0) * (a1 * a1 - a0 * a0)
		match ct:
			"100":
				lin += _v3(p + "Dir", Vector3.ZERO) * dist
			"101":
				p_rad += dist
			"102", "103":
				var ctr = _v3(p + "Pos", Vector3.ZERO) + axis_off
				var q_axis = qaxis(_v3(p + "Axis", AXIS_Y), dist)
				p_rel = qrot(q_axis, p_rel - ctr) + ctr
				if ct == "102":
					p_rot = qmul(q_axis, p_rot)
			"104":
				if _f(p + "Vel", 0.0) != 0.0:
					var ctr = _v3(p + "Pos", Vector3.ZERO) + axis_off
					var r = p_rel - ctr
					var r_len = r.length()
					if r_len > 0.000001:
						p_rel = ctr + r / r_len * maxf(0.0, r_len + dist)
			"105":
				var cd = _argb(_v4(p + "ColorDelta", Vector4.ZERO))
				p_col = (p_col + cd * (a1 - a0)).clamp(Vector4.ZERO, Vector4.ONE)
			"106":
				var key = p + ("ScaleChage" if _has(p + "ScaleChage") else "ScaleChange")
				if _has(key):
					var sc = _v3(key, Vector3.ZERO)
					p_size = clampf(p_size + sc.x * (a1 - a0), sc.y, sc.z)
			"107":
				var n = KP._fbm1d(a1 * 1000.0 / maxf(1.0, _f(p + "WaveLen", 1.0)), int(_val(p + "OctaveNum", 1)), _f(p + "Persistence", 0.5))
				var base_col = _v4(p + "BaseColor", Vector4.ONE)
				p_col = Vector4(base_col.x, base_col.y, base_col.z, clampf(base_col.w + (n * 2.0 - 1.0) * _f(p + "Amplitude", 0.0) / 255.0, 0.0, 1.0))
			"108":
				var st = _stage(p, "Color", a1 * 1000.0)
				if st != null and st[0] > 0:
					var c_out = _to_v4(st[1])
					if _has(p + "AlphaOnly") and _b(p + "AlphaOnly", false):
						p_col.w = c_out.w
					else:
						p_col = c_out
			"109":
				p_noise = KP._fbm1d(a1 * 1000.0 / maxf(0.001, _f(p + "WaveLen", 1.0)), int(_val(p + "OctaveNum", 1)), _f(p + "Persistence", 0.5)) * _f(p + "Amplitude", 0.0)
			"110":
				var arr = _val(p + "Type_110_Pos_Array", null)
				if arr != null and arr.size() > 0:
					# Affector-CurveMove: Ratio 1 = letzter Punkt
					p_rel = arr[arr.size() - 1] - (Vector3.ZERO if is_bind else ee_world)
					lin = Vector3.ZERO
			"111":
				var st = _stage(p, "Scale", a1 * 1000.0)
				if st != null and st[0] > 0:
					p_size = float(st[1])

	# Welt-Position (im Partikel-Node) und Ausrichtung
	var p_local = p_rel + lin
	var q3 = qmul(p_rot, qaxis(AXIS_Z, p_rad))
	var w_pos: Vector3
	var w_move: Vector3
	var rot: Quaternion
	var en_scale: float = en["scale"]
	if is_bind:
		var bind_rot = qmul(en["rot"], qaxis(AXIS_Z, en["rad"]))
		w_pos = (qrot(bind_rot, p_local * en_scale) + en["pos"]) if scale_no_off else ((qrot(bind_rot, p_local) + en["pos"]) * en_scale)
		w_move = qrot(bind_rot, move_dir)
		rot = qmul(bind_rot, q3)
	else:
		w_pos = ee_world + p_local
		if _b("IsDrag", false):
			var portion = pow(maxf(0.00001, clampf(age / maxf(0.0001, _f("TTL", 1.0)), 0.0, 1.0)), _f("DragPow", 1.0))
			w_pos += (1.0 - portion) * (en_world - ee_world)
		w_move = move_dir
		rot = q3
	return {"pos": w_pos, "move": w_move, "rot": rot, "size": p_size + p_noise, "col": p_col,
		"k_scale": en_scale, "k_alpha": en["alpha"], "bind": is_bind}


# ====================================================
# InitParticle der Emitter (Hooks _gen_emitter_init in create_id_120 ... 125)
# -> [p_rel, move_dir, p_rot]
# ====================================================
func _emitter_init(e_idx: float, is_bind: bool, ee_rot: Quaternion, ee_scale: float, ee_world: Vector3, par_dir: Quaternion) -> Array:
	var identity = Quaternion(0.0, 0.0, 0.0, 1.0)
	var angle = _f("Angle", 0.0)
	match str(info.get("type", "120")):
		"121":
			var box_u: Vector3
			if _b("IsSurface", false):
				var sz = _v3("AreaSize", Vector3.ONE)
				var s1 = sz.x * sz.y
				var s2 = sz.y * sz.z
				var s_sum = maxf(0.000001, s1 + s2 + sz.z * sz.x)
				s1 /= s_sum
				s2 /= s_sum
				var side = -1.0 if rnd(e_idx, 14.0) < 0.5 else 1.0
				var f_rand = rnd(e_idx, 11.0)
				if f_rand < s1:
					box_u = Vector3(srnd(e_idx, 12.0), srnd(e_idx, 13.0), side)
				elif f_rand < s2:
					box_u = Vector3(side, srnd(e_idx, 12.0), srnd(e_idx, 13.0))
				else:
					box_u = Vector3(srnd(e_idx, 12.0), side, srnd(e_idx, 13.0))
			else:
				box_u = Vector3(srnd(e_idx, 11.0), srnd(e_idx, 12.0), srnd(e_idx, 13.0))
			return [_area_offset(box_u, is_bind, ee_rot, ee_scale), gen_direction(e_idx, is_bind, ee_rot, angle), identity if is_bind else par_dir]
		"122":
			var mp_dir = _q(_v4("ParIniDir_Quat", Vector4(0.0, 0.0, 0.0, 1.0))) if is_bind else par_dir
			var pts = _val("MultiPlane_Points", null)
			var count = pts.size() if pts != null else 0
			if count == 0:
				return [Vector3.ZERO, gen_direction(e_idx, is_bind, ee_rot, angle), mp_dir]
			var mp_idx = mini(int(rnd(e_idx, 11.0) * count), count - 1)
			var mp_pos: Vector3 = pts[mp_idx]
			var mp_n: Vector3 = _val("MultiPlane_Normals", PackedVector3Array())[mp_idx]
			var rel = mp_pos if is_bind else mp_pos - ee_world
			if _b("UseNormal", false):
				if _b("PerpToNormal", true):
					var z_ax = mp_n.normalized()
					var x_ax = _calc_vert_vec(z_ax).cross(z_ax).normalized()
					return [rel, gen_direction(e_idx, is_bind, ee_rot, angle), Basis(x_ax, z_ax.cross(x_ax), z_ax).get_rotation_quaternion()]
				var dir = _random_deviation(mp_n, angle, e_idx) if angle != 0.0 else mp_n
				return [rel, dir, mp_dir]
			return [rel, gen_direction(e_idx, is_bind, ee_rot, angle), mp_dir]
		"123":
			var surface = _b("IsSurface", false)
			var ell_u: Vector3
			var move_dir = Vector3.ZERO
			var gen_dir = true
			if _b("IsAvgGen", false):
				var a_delta = TAU / maxf(1.0, float(_val("AlphaSeg", 10)))
				var b_delta = PI / maxf(1.0, float(_val("BetaSeg", 10)))
				var cycle = float(_val("Avg_Cycle", 1))
				var k = fmod(e_idx, cycle)
				var alpha = 0.0
				var beta = 0.0
				if k > cycle - 1.5:
					beta = PI
				elif k > 0.5:
					var m = k - 1.0
					var n = float(_val("Avg_Ring_Count", 1))
					beta = (1.0 + floor(m / n)) * b_delta
					alpha = fmod(m, n) * a_delta
				var v = qrot(qaxis(AXIS_Y, alpha), qrot(qaxis(AXIS_X, beta), AXIS_Y))
				ell_u = v * (1.0 if surface else rnd(e_idx, 13.0))
			elif surface:
				var v = qrot(qaxis(AXIS_Y, rnd(e_idx, 11.0) * TAU), AXIS_X)
				v = qrot(qaxis(v, rnd(e_idx, 12.0) * TAU), AXIS_Y)
				ell_u = v
				move_dir = -v
				gen_dir = false
			else:
				var z = srnd(e_idx, 11.0)
				var phi = rnd(e_idx, 12.0) * TAU
				var rxy = sqrt(maxf(0.0, 1.0 - z * z))
				ell_u = pow(rnd(e_idx, 13.0), 1.0 / 3.0) * Vector3(rxy * cos(phi), rxy * sin(phi), z)
			if gen_dir:
				move_dir = gen_direction(e_idx, is_bind, ee_rot, angle)
			return [_area_offset(ell_u, is_bind, ee_rot, ee_scale), move_dir, identity if is_bind else par_dir]
		"124":
			var cyl_u: Vector3
			if _b("IsAvgGen", false):
				var a_delta = TAU / maxf(1.0, float(_val("AlphaSeg", 10)))
				var b_seg = maxf(1.0, float(_val("BetaSeg", 10)))
				var n = float(_val("Avg_Ring_Count", 1))
				var k = fmod(e_idx, float(_val("Avg_Cycle", 1)))
				var ring = floor(k / n)
				var v = qrot(qaxis(AXIS_Z, fmod(k, n) * a_delta), Vector3(0.0, 1.0, 1.0 - 2.0 * ring / b_seg))
				cyl_u = v * (1.0 if _b("IsSurface", false) else rnd(e_idx, 13.0))
			elif _b("IsSurface", false):
				var phi = rnd(e_idx, 11.0) * TAU
				cyl_u = Vector3(cos(phi), sin(phi), srnd(e_idx, 12.0))
			else:
				var r = sqrt(rnd(e_idx, 11.0))
				var phi = rnd(e_idx, 12.0) * TAU
				cyl_u = Vector3(r * cos(phi), r * sin(phi), srnd(e_idx, 13.0))
			return [_area_offset(cyl_u, is_bind, ee_rot, ee_scale), gen_direction(e_idx, is_bind, ee_rot, angle), identity if is_bind else par_dir]
		"125":
			var c_pos = Vector3.ZERO
			var pts = _val("Curve_Points", null)
			var count = pts.size() if pts != null else 0
			if count >= 2:
				var c_ratio = rnd(e_idx, 11.0)
				if _b("IsAvgGen", false):
					var seg_num = maxf(1.0, float(_val("AvgGenSeg", 1)))
					if _b("IsAvgGenSeq", true):
						c_ratio = fmod(e_idx, float(_val("Avg_Step_Count", 1))) / seg_num
					else:
						c_ratio = 0.0 if e_idx < 0.5 else floor(rnd(e_idx, 14.0) * seg_num) / seg_num
				var cp = _curve_point(c_ratio, pts, _val("Curve_Ratios", PackedFloat32Array()))
				c_pos = cp[0]
				var radius = _f("Radius", 0.0)
				if radius > 0.001:
					var c_r = radius if _b("IsSurface", false) else radius * rnd(e_idx, 12.0)
					var c_d: Vector3 = _val("Curve_Dirs", PackedVector3Array())[cp[1]]
					c_pos += qrot(qaxis(c_d, rnd(e_idx, 13.0) * TAU), _calc_vert_vec(c_d)) * c_r
			# Ungebunden wird die Kurve nur skaliert, nicht gedreht
			return [c_pos if is_bind else c_pos * ee_scale, gen_direction(e_idx, is_bind, ee_rot, angle), identity if is_bind else par_dir]
	# 120: A3DPointEmitter
	var move_dir: Vector3
	var p_rot: Quaternion
	if _b("IsSurface", false):
		var r_az = rnd(e_idx, 1.0) * TAU
		var up = Vector3(cos(r_az), sin(r_az), 0.0)
		var q = qmul(qaxis(up, PI * 0.5 - angle), qaxis(AXIS_Z, r_az))
		p_rot = q if is_bind else qmul(par_dir, q)
		move_dir = qrot(p_rot, AXIS_Y)
	else:
		move_dir = gen_direction(e_idx, is_bind, ee_rot, angle)
		p_rot = identity if is_bind else par_dir
	return [move_dir * 0.001, move_dir, p_rot]

# A3DAreaEmitter: Achse * AreaSize / 2 (ungebunden gedreht und mit dem KeyPoint-Scale skaliert)
func _area_offset(u: Vector3, is_bind: bool, parent_rot: Quaternion, parent_scale: float) -> Vector3:
	var local_off = u * _v3("AreaSize", Vector3.ONE) * 0.5
	return local_off if is_bind else qrot(parent_rot, local_off * parent_scale)

static func _calc_vert_vec(d: Vector3) -> Vector3:
	var v = d.cross(AXIS_X) if absf(d.y) > 0.999 else AXIS_Y.cross(d)
	return v.normalized() if v.length() > 0.000001 else AXIS_X

func _random_deviation(d: Vector3, angle: float, e_idx: float) -> Vector3:
	var up = qrot(qaxis(d, rnd(e_idx, 12.0) * TAU), _calc_vert_vec(d))
	return qrot(qaxis(up, rnd(e_idx, 13.0) * angle), d)

# A3DGFXCtrlCurveMove::GetInterpPoint -> [Punkt, Segment]
static func _curve_point(ratio: float, pts, ratios) -> Array:
	var last = pts.size() - 1
	var seg = 0
	for i in last:
		if ratio <= ratios[i + 1]:
			break
		seg = i + 1
	if seg >= last:
		return [pts[last], last]
	var f = (ratio - ratios[seg]) / maxf(0.000001, ratios[seg + 1] - ratios[seg])
	return [(pts[seg] as Vector3).lerp(pts[seg + 1], f), seg]
