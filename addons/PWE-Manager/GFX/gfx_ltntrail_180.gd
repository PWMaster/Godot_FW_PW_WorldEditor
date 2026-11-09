@tool
extends MeshInstance3D

# ====================================================
# Laufzeit-Helfer für GFXELEMENTID 180 (A3DLtnTrail), angelegt von create_id_180.gd.
# Bind = 0: Angelica legt die Schweif-Punkte im Welt-Raum ab (GetTranMatrix(kp) * GetParentTM()),
# sie bleiben liegen, wenn sich das GFX bewegt. Der Shader kennt nur die aktuelle Lage, deshalb
# merkt sich dieses Skript für jeden Tick die Welt-Lage des Nodes (Hist_*, Slot = Tick mod
# History_Slots) und gibt die aktuelle Lage als Cur_* weiter. Die Tick-Rechnung ist dieselbe
# wie im Shader. Bind = 1 braucht das nicht (die Punkte liegen im GFX-Raum).
# ====================================================

const KP = preload("gfx_keypoint_eval.gd")
const ENDLESS_TICKS = 16777216.0 # wie lt_J im Shader

## Anzahl der Hist_*-Slots im Shader
@export var History_Slots: int = 1

var _origins = PackedVector3Array()
var _rots = PackedVector4Array()
var _scales = PackedFloat32Array()
var _written = -1.0 # letzter Tick mit fester Welt-Lage
var _cycle = -1.0
var _prev_time = -INF
var _prev_xf = Transform3D()


func _process(_delta: float) -> void:
	update_history()

func update_history() -> void:
	var mat = material_override as ShaderMaterial
	if mat == null or mat.shader == null or History_Slots <= 0:
		return
	if bool(_param(mat, "Bind", true)):
		if bool(_param(mat, "Use_Driver_Time", false)):
			mat.set_shader_parameter("Use_Driver_Time", false)
		return

	var xf = global_transform
	mat.set_shader_parameter("Cur_Origin", xf.origin)
	mat.set_shader_parameter("Cur_Rot", _quat4(xf))
	mat.set_shader_parameter("Cur_Scale", _scale(xf))

	# Der Shader rechnet mit derselben Uhr (Driver_Time), sonst passen Tick und Slot nicht zusammen
	var active_time = KP.clock_ms(bool(_param(mat, "Time_Manual", false)), float(_param(mat, "Time", 0.0)))
	mat.set_shader_parameter("Use_Driver_Time", true)
	mat.set_shader_parameter("Driver_Time", active_time)
	var g = tick_grid(mat, active_time)
	var now: float = g["now"]
	if _origins.size() != History_Slots:
		_origins.resize(History_Slots)
		_rots.resize(History_Slots)
		_scales.resize(History_Slots)
		_written = INF # erzwingt das Füllen

	if g["cycle"] != _cycle or active_time < _prev_time or now < _written or now - _written > History_Slots:
		# Start, neuer GFX-Durchlauf oder Zeitsprung: keine Vergangenheit bekannt
		for k in range(History_Slots):
			_store(float(k), xf)
		_written = now
	else:
		# Neue Ticks seit dem letzten Frame: Lage zwischen letztem und aktuellem Frame
		var k = _written + 1.0
		while k <= now:
			var t_k = active_time - (g["tau"] - tick_time(k, g))
			var f = 1.0 if active_time <= _prev_time else clampf((t_k - _prev_time) / (active_time - _prev_time), 0.0, 1.0)
			_store(k, _prev_xf.interpolate_with(xf, f))
			k += 1.0
		_written = now
	# Vorläufig: die Shader-Zeit kann der CPU-Zeit ein paar ms voraus sein
	_store(now + 1.0, xf)
	_store(now + 2.0, xf)

	mat.set_shader_parameter("Hist_Origin", _origins)
	mat.set_shader_parameter("Hist_Rot", _rots)
	mat.set_shader_parameter("Hist_Scale", _scales)
	_cycle = g["cycle"]
	_prev_time = active_time
	_prev_xf = xf

# Tick-Raster wie im Shader: {cycle, tau, J, full, T, now}
func tick_grid(mat: ShaderMaterial, active_time: float) -> Dictionary:
	var f_repeat = float(_param(mat, "RepeatCount", 1))
	var start = float(_param(mat, "LocalStartTime", 0.0))
	var total = float(_param(mat, "LocalTotalTime", 3000.0))
	var loop_time = maxf(0.001, float(_param(mat, "GlobalLoopTime", 3000.0)))
	var t = maxf(1.0, float(_param(mat, "Tick_Ms", 40.0)))
	var g = {"cycle": 0.0, "T": t, "J": ENDLESS_TICKS, "full": 0.0}
	var t_glob = active_time
	if f_repeat >= 0.0:
		g["cycle"] = floor(active_time / loop_time)
		t_glob = fmod(active_time, loop_time)
	var tau = maxf(0.0, t_glob - start)
	var r = 0.0
	if not bool(_param(mat, "Is_Endless", false)):
		var active_duration = maxf(0.001, total - start)
		g["J"] = maxf(1.0, ceil(active_duration / t))
		g["full"] = active_duration + maxf(0.0, float(_param(mat, "RepeatDelay", 0.0)))
		r = floor(tau / g["full"])
	g["tau"] = tau
	g["now"] = r * g["J"] + minf(floor((tau - r * g["full"]) / t), g["J"] - 1.0)
	return g

func tick_time(k: float, g: Dictionary) -> float:
	return floor(k / g["J"]) * g["full"] + fmod(k, g["J"]) * g["T"]

func _store(k: float, xf: Transform3D) -> void:
	var slot = int(fposmod(k, float(History_Slots)))
	_origins[slot] = xf.origin
	_rots[slot] = _quat4(xf)
	_scales[slot] = _scale(xf)

func _quat4(xf: Transform3D) -> Vector4:
	var q = xf.basis.get_rotation_quaternion()
	return Vector4(q.x, q.y, q.z, q.w)

# GFX-Scale (gleichmäßig)
func _scale(xf: Transform3D) -> float:
	var s = xf.basis.get_scale()
	return (absf(s.x) + absf(s.y) + absf(s.z)) / 3.0

func _param(mat: ShaderMaterial, param_name: String, fallback):
	var v = mat.get_shader_parameter(param_name)
	if v == null:
		v = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), param_name)
	return fallback if v == null else v
