@tool
extends Node3D

# ====================================================
# Datei-Node einer .gfx (Kopfzeile) und Laufzeit-Treiber der ganzen GFX (A3DGFXEx).
# Wie A3DGFXEx::TickAnimation / Render steuert der Header alle Elemente darunter:
#  - Zeit: ein gemeinsamer Takt in ms für alle Shader (Time_Manual / Time) und Treiber
#    (Time_Manual / Time_Ms), mal PlaySpeed der Datei * Play_Speed (m_fActualSpeed).
#    Playing hält an, Time_Manual + Time_Ms setzen die GFX-Zeit direkt.
#    Die Elemente wiederholen sich wie bisher nach ihrer GlobalLoopTime.
#  - DedaultScale setzt der Import als Node-Scale (CalcActualScale = DefScale * Scale).
#  - Alpha = DefaultAlpha * Alpha (bei FadeByDist statt Alpha das Ausblenden nach Kameraabstand
#    (FadeEnd - Abstand) / (FadeEnd - FadeStart)); unter 0.05 zeichnet Angelica nichts.
#    Wirkt über das Uniform GFX_Alpha der Element-Shader (Modelle 160 / 230 nicht), auf eigenen
#    Material-Kopien des Headers (_claim).
#  - FaceToViewer: die ganze GFX zeigt jeden Frame mit +Z zur Kamera (_build_matrix).
#  - NoChangeDir: die GFX übernimmt vom Elternteil nur Lage und Scale, ihre Drehung bleibt die der
#    Welt (A3DGFXEx::SetParentTM), z.B. an Hooks, als Unter-GFX oder als Dummy an Partikeln.
#  - ShakeCam: wackelt die Kamera (ShakeCamera / ShakeCamera2 mit Rauschen CtrlType 112,
#    ShakeDamp, Abschwächung bis 30 m). Im Spiel die aktive Kamera, im Editor nur mit
#    Shake_In_Editor; als h_offset / v_offset (Anteil entlang der Blickrichtung entfällt).
# Unter einem Container (ID 200) steuert dieser die Unter-GFX, der Header bleibt passiv.
# Mit Header_Control = aus laufen die Elemente wieder mit ihrer eigenen Zeit.
# GFX-Player (Leiste rechts, gfx_player_dock.gd): hält die Zeit an (player_paused) und setzt sie
# (player_seek); nur zur Laufzeit im Editor, nichts davon wird mit der Szene gespeichert.
# parsed_data wird mit der Szene gespeichert.
# ====================================================

const KP = preload("gfx_keypoint_eval.gd")
const META_OWNER = &"gfx_header_owner" # nur noch zum Entfernen aus alten Szenen
const SHAKE_DIR_RAND = 1
const SHAKE_DIR_UPDOWN = 2
const SHAKE_DIR_CAMERA = 3
const SHAKE_DAMP_LINEAR = 1
const SHAKE_DAMP_QUADRATIC = 2
const DEFAULT_SHAKE_ATTENU = 30.0 # IShakeCamera::m_fShakeAttenuDist
const HIDE_ALPHA = 0.05 # A3DGFXEx::Render

@export_storage var parsed_data: Dictionary = {}:
	set(value):
		parsed_data = value
		_cfg_dirty = true

@export_group("GFX_Steuerung")
## Header steuert Zeit, Alpha, Ausrichtung und Kamerawackeln aller Elemente (wie A3DGFXEx)
@export var Header_Control: bool = true:
	set(value):
		Header_Control = value
		if not value:
			_release()
		_dirty = true
## Zeit läuft (aus = angehalten)
@export var Playing: bool = true
## GFX-Zeit selbst setzen (Time_Ms, bereits mit PlaySpeed)
@export var Time_Manual: bool = false
## GFX-Zeit in ms
@export var Time_Ms: float = 0.0
## SetPlaySpeed des Spiels (zusätzlich zu PlaySpeed der Datei)
@export var Play_Speed: float = 1.0
## SetAlpha des Spiels (zusätzlich zu DefaultAlpha der Datei)
@export var Alpha: float = 1.0
## Kamerawackeln auch mit der Editor-Kamera zeigen
@export var Shake_In_Editor: bool = false
@export_tool_button("Перезапустить GFX", "Reload") var btn_restart = restart

var _t = 0.0
var _cfg = {}
var _cfg_dirty = true
var _dirty = true
var _controlling = false
var _materials: Array = [] # eigene Materialien mit Zeit (Time_Manual)
var _claimed: Array = [] # alle eigenen Materialien (Zeit und / oder GFX_Alpha)
var _drivers: Array = []
var _geometries: Array = []
var _loop_ms = 3000.0
var _last_alpha = -1.0
var _rng = RandomNumberGenerator.new()
# Kamerawackeln
var _shake_cam: Camera3D = null
var _shake_hv = Vector2.ZERO # angewendeter h_offset / v_offset
var _shaking = false
var _shake_count = 0
var _shake_offset = Vector3.ZERO
var _s2_time = 0.0
var _s2_half = 0.0
var _s2_cycle = 0
var _s2_dir = Vector3.ZERO
var _s2_last = Vector3.ZERO
var _last_loop_t = -1.0
# GFX-Player: Zeit angehalten (nicht gespeichert)
var player_paused = false
# Welcher Header welches Material steuert (Material-ID -> Header-ID). Nur zur Laufzeit:
# Instanz-IDs gelten nur in einer Sitzung und dürfen nicht mit der Szene gespeichert werden.
static var _material_owners: Dictionary = {}


# 1. Bekannte Parameter (Array gibt die genaue REIHENFOLGE im Inspektor vor!)
const KNOWN_PARAMS = [
	"MOXTVersion", "IsAngelica3", "DedaultScale", "PlaySpeed", "DefaultAlpha",
	"Raytrace", "FaceToViewer", "FadeByDist", "FadeStart", "FadeEnd",
	"Vec_1", "Vec_2", "UseAABB", "AccurateAABB", "ShakeCam",
	"CtrlType", "StartTime", "EndTime", "BufLen", "Amplitude", "WaveLen", "Persistence", "OctaveNum",
	"ShakePeriod", "ShakeByDistance", "ShakeCamBlur", "ShakeCamPixOff", "ShakeCamAttenu",
	"ShakeDamp", "NoChangeDir", "2DRender", "2DBackLayer", "PhysExist", "GFXELEMENTCOUNT"
]

# 2. Zuordnung der Datentypen für den Inspektor
const PARAM_TYPES: Dictionary = {
	"MOXTVersion": TYPE_INT,
	"IsAngelica3": TYPE_BOOL,
	"DedaultScale": TYPE_FLOAT,
	"PlaySpeed": TYPE_FLOAT,
	"DefaultAlpha": TYPE_FLOAT,
	"Raytrace": TYPE_BOOL,
	"FaceToViewer": TYPE_BOOL,
	"FadeByDist": TYPE_BOOL,
	"FadeStart": TYPE_FLOAT,
	"FadeEnd": TYPE_FLOAT,
	"Vec_1": TYPE_VECTOR3, # <-- Vektoren!
	"Vec_2": TYPE_VECTOR3, # <-- Vektoren!
	"UseAABB": TYPE_BOOL,
	"AccurateAABB": TYPE_BOOL,
	"ShakeCam": TYPE_INT,
	"CtrlType": TYPE_INT,
	"StartTime": TYPE_FLOAT,
	"EndTime": TYPE_FLOAT,
	"BufLen": TYPE_INT,
	"Amplitude": TYPE_FLOAT,
	"WaveLen": TYPE_FLOAT,
	"Persistence": TYPE_FLOAT,
	"OctaveNum": TYPE_INT,
	"ShakePeriod": TYPE_INT,
	"ShakeByDistance": TYPE_BOOL,
	"ShakeCamBlur": TYPE_STRING,
	"ShakeCamPixOff": TYPE_FLOAT,
	"ShakeCamAttenu": TYPE_FLOAT,
	"ShakeDamp": TYPE_INT,
	"NoChangeDir": TYPE_BOOL,
	"2DRender": TYPE_BOOL,
	"2DBackLayer": TYPE_BOOL,
	"PhysExist": TYPE_BOOL,
	"GFXELEMENTCOUNT": TYPE_INT
}


# ====================================================
# LAUFZEIT (A3DGFXEx::TickAnimation / Render)
# ====================================================
func _ready() -> void:
	_rng.seed = hash(str(name))
	if not get_tree().node_added.is_connected(_on_tree_changed):
		get_tree().node_added.connect(_on_tree_changed)
		get_tree().node_removed.connect(_on_tree_changed)

func _exit_tree() -> void:
	_shake_stop()
	_unclaim()
	_dirty = true
	if get_tree().node_added.is_connected(_on_tree_changed):
		get_tree().node_added.disconnect(_on_tree_changed)
		get_tree().node_removed.disconnect(_on_tree_changed)

func _on_tree_changed(node: Node) -> void:
	if is_ancestor_of(node):
		_dirty = true

func _process(delta: float) -> void:
	tick(delta * 1000.0)

# Ein Frame mit dt_ms echter Zeit (öffentlich für Tests)
func tick(dt_ms: float) -> void:
	if not Header_Control or is_passive():
		if _controlling:
			_release()
		return
	if _cfg_dirty:
		_read_cfg()
	if _dirty or not _controlling:
		_prepare()
	var step = dt_ms * actual_speed() if (Playing and not Time_Manual and not player_paused) else 0.0
	_t += step
	var t = gfx_time()
	_push_time(t)
	apply_no_change_dir()
	var cam = _camera()
	_apply_face(cam)
	_apply_alpha(cam)
	_apply_shake(step, t, cam)

# Unter einem Container (ID 200): der steuert Zeit, Lage, Scale und Alpha der Unter-GFX
func is_passive() -> bool:
	var p = get_parent()
	return p != null and p.has_method("prepare_sub_gfx")

func gfx_time() -> float:
	return Time_Ms if Time_Manual else _t

# A3DGFXEx::m_fActualSpeed = PlaySpeed der Datei * SetPlaySpeed
func actual_speed() -> float:
	return float(_cfg.get("speed", 1.0)) * Play_Speed

func restart() -> void:
	_t = 0.0
	_shake_stop()

# ====================================================
# GFX-PLAYER (gfx_player_dock.gd): Zeiten in echten ms seit dem Start, vor PlaySpeed
# ====================================================
func player_time_ms() -> float:
	if _cfg_dirty:
		_read_cfg()
	var speed = actual_speed()
	return gfx_time() / speed if absf(speed) > 0.000001 else 0.0

func player_seek(ms: float) -> void:
	if _cfg_dirty:
		_read_cfg()
	_t = ms * actual_speed()
	_shake_stop()

# Ein Durchlauf: längste GlobalLoopTime der Elemente
func player_length_ms() -> float:
	if _cfg_dirty:
		_read_cfg()
	if _dirty or not _controlling:
		_prepare()
	var speed = absf(actual_speed())
	return _loop_ms / speed if speed > 0.000001 else _loop_ms

func _read_cfg() -> void:
	_cfg_dirty = false
	var d = parsed_data
	var f = func(key: String, def: float) -> float: return float(str(d.get(key, def))) if d.has(key) else def
	_cfg = {
		"speed": f.call("PlaySpeed", 1.0), "alpha": f.call("DefaultAlpha", 1.0),
		"face": _as_bool(d.get("FaceToViewer", "0")), "fade": _as_bool(d.get("FadeByDist", "0")),
		"no_dir": _as_bool(d.get("NoChangeDir", "0")),
		"fade_start": f.call("FadeStart", 10.0), "fade_end": f.call("FadeEnd", 0.0),
		"shake": int(str(d.get("ShakeCam", "0"))) if str(d.get("CtrlType", "")) == "112" else 0,
		"shake_start": f.call("StartTime", 0.0), "shake_end": f.call("EndTime", -1.0),
		"shake_amp": f.call("Amplitude", 2.0), "shake_wave": f.call("WaveLen", 1.0),
		"shake_pers": f.call("Persistence", 0.25), "shake_oct": int(f.call("OctaveNum", 5.0)),
		# Vor Version 90 fehlen Period / ByDistance: ShakeCamera mit Abschwächung
		"shake_period": int(f.call("ShakePeriod", 0.0)),
		"shake_by_dist": _as_bool(d.get("ShakeByDistance", "1")),
		"shake_attenu": f.call("ShakeCamAttenu", DEFAULT_SHAKE_ATTENU),
		"shake_damp": int(f.call("ShakeDamp", 0.0)),
	}


# ====================================================
# ELEMENTE SAMMELN / FREIGEBEN
# ====================================================
func _prepare() -> void:
	_dirty = false
	_controlling = true
	_unclaim()
	_materials.clear()
	_claimed.clear()
	_drivers.clear()
	_geometries.clear()
	_last_alpha = -1.0
	_loop_ms = 0.0
	for child in get_children():
		_collect(child)
	if _loop_ms <= 0.0:
		_loop_ms = 3000.0

func _collect(node: Node) -> void:
	if node is GeometryInstance3D:
		_geometries.append(node)
		var mat = node.get("material_override")
		if mat is ShaderMaterial and mat.shader != null:
			var timed = _has_uniform(mat.shader, "Time_Manual")
			if timed or _has_uniform(mat.shader, "GFX_Alpha"):
				mat = _claim(node, mat)
				_claimed.append(mat)
			if timed:
				mat.set_shader_parameter("Time_Manual", true)
				_loop_ms = maxf(_loop_ms, _shader_float(mat, "GlobalLoopTime"))
				_materials.append(mat)
	if "Time_Manual" in node and "Time_Ms" in node:
		node.Time_Manual = true
		_loop_ms = maxf(_loop_ms, float(node.get("GlobalLoopTime")) if node.get("GlobalLoopTime") != null else 0.0)
		_drivers.append(node)
		# Ein Container steuert seinen Teilbaum selbst
		if node.has_method("prepare_sub_gfx"):
			return
	for child in node.get_children():
		_collect(child)

# Geteiltes Material (z.B. duplizierte GFX): der zweite Header bekommt eine eigene Kopie
func _claim(node: Node, mat: ShaderMaterial) -> ShaderMaterial:
	# Frühere Versionen merkten sich den Besitzer als Metadaten, die mit der Szene gespeichert wurden
	if mat.has_meta(META_OWNER):
		mat.remove_meta(META_OWNER)
	var owner_id = int(_material_owners.get(mat.get_instance_id(), 0))
	if owner_id != 0 and owner_id != get_instance_id() and is_instance_valid(instance_from_id(owner_id)):
		mat = mat.duplicate()
		node.material_override = mat
	_material_owners[mat.get_instance_id()] = get_instance_id()
	return mat

func _unclaim() -> void:
	var my_id = get_instance_id()
	for mat in _claimed:
		if is_instance_valid(mat) and int(_material_owners.get(mat.get_instance_id(), 0)) == my_id:
			_material_owners.erase(mat.get_instance_id())

# Nie gesetzte Parameter liefern null -> Standardwert aus dem Shader
func _shader_float(mat: ShaderMaterial, param: String) -> float:
	var v = mat.get_shader_parameter(param)
	if v == null:
		v = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), param)
	return float(v) if v != null else 0.0

func _has_uniform(shader: Shader, uniform_name: String) -> bool:
	for u in shader.get_shader_uniform_list():
		if u["name"] == uniform_name:
			return true
	return false

# Header_Control aus: Elemente laufen wieder mit eigener Zeit
func _release() -> void:
	for mat in _materials:
		if is_instance_valid(mat):
			mat.set_shader_parameter("Time_Manual", false)
	for d in _drivers:
		if is_instance_valid(d):
			d.Time_Manual = false
	for g in _geometries:
		if is_instance_valid(g):
			preload("gfx_parser.gd").set_gfx_alpha(g, 1.0)
	_shake_stop()
	_unclaim()
	_materials.clear()
	_claimed.clear()
	_drivers.clear()
	_geometries.clear()
	_controlling = false

func _push_time(t: float) -> void:
	for mat in _materials:
		mat.set_shader_parameter("Time", t)
	for d in _drivers:
		if is_instance_valid(d):
			d.Time_Ms = t


# ====================================================
# AUSRICHTUNG / ALPHA
# ====================================================
# Im Spiel die aktive Kamera, im Editor die Kamera des ersten 3D-Viewports
func _camera() -> Camera3D:
	if not is_inside_tree():
		return null
	var vp: Viewport = get_viewport()
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		vp = Engine.get_singleton(&"EditorInterface").get_editor_viewport_3d(0)
	return vp.get_camera_3d() if vp != null else null

# NoChangeDir: Drehung des Elternteils aufheben, Lage und Scale bleiben (öffentlich für den
# Container, der eine passive Unter-GFX selbst bewegt)
func apply_no_change_dir() -> void:
	if _cfg_dirty:
		_read_cfg()
	if not _cfg.get("no_dir", false) or not is_inside_tree():
		return
	var b = global_basis
	if not b.orthonormalized().is_equal_approx(Basis.IDENTITY):
		global_basis = Basis.from_scale(b.get_scale())

# FaceToViewer: _build_matrix(Kamera - GFX, Pos), Scale bleibt
func _apply_face(cam: Camera3D) -> void:
	if not _cfg.get("face", false) or cam == null:
		return
	var view = cam.global_position - global_position
	if view.length() < 0.000001:
		return
	var z = view.normalized()
	var x: Vector3
	var y: Vector3
	if absf(z.y) > 0.999:
		y = z.cross(Vector3.RIGHT).normalized()
		x = y.cross(z)
	else:
		x = Vector3.UP.cross(z).normalized()
		y = z.cross(x)
	var s = global_basis.get_scale()
	global_basis = Basis(x * s.x, y * s.y, z * s.z)

# DefaultAlpha * (Ausblenden nach Abstand oder Alpha)
func actual_alpha(cam: Camera3D) -> float:
	var a = Alpha
	if _cfg.get("fade", false) and cam != null:
		var dist = cam.global_position.distance_to(global_position)
		var span = _cfg["fade_end"] - _cfg["fade_start"]
		a = clampf((_cfg["fade_end"] - dist) / span, 0.0, 1.0) if absf(span) > 0.000001 else (1.0 if dist <= _cfg["fade_end"] else 0.0)
	return float(_cfg.get("alpha", 1.0)) * a

func _apply_alpha(cam: Camera3D) -> void:
	var a = actual_alpha(cam)
	var tr = 1.0 if a <= HIDE_ALPHA else clampf(1.0 - a, 0.0, 1.0)
	if absf(tr - _last_alpha) < 0.001:
		return
	_last_alpha = tr
	for g in _geometries:
		if is_instance_valid(g):
			preload("gfx_parser.gd").set_gfx_alpha(g, 1.0 - tr)


# ====================================================
# KAMERAWACKELN (ShakeCamera / ShakeCamera2)
# ====================================================
func _apply_shake(step_ms: float, t: float, cam: Camera3D) -> void:
	var shake_type = int(_cfg.get("shake", 0))
	var loop_t = fmod(t, maxf(0.001, _loop_ms))
	# Neuer GFX-Durchlauf: Wackeln beginnt von vorn
	if loop_t < _last_loop_t:
		_shake_stop()
	_last_loop_t = loop_t
	var allowed = shake_type > 0 and cam != null and Playing and not Time_Manual and not player_paused and (Shake_In_Editor or not Engine.is_editor_hint())
	if not allowed:
		_shake_stop()
		return
	if cam != _shake_cam:
		_shake_stop()
		_shake_cam = cam
	var ts = loop_t / 1000.0
	var end = float(_cfg["shake_end"])
	if ts < _cfg["shake_start"] or (end >= 0.0 and ts > end):
		_shake_stop()
		return
	var dist = cam.global_position.distance_to(global_position)
	if int(_cfg["shake_period"]) == 0:
		_shake_tick_1(loop_t, ts, dist, cam)
	else:
		_shake_tick_2(step_ms, ts, dist, cam)

# ShakeCamera: abwechselnd neuer Ausschlag (Rauschen * Richtung) und zurück
func _shake_tick_1(loop_t: float, ts: float, dist: float, cam: Camera3D) -> void:
	if not _shaking:
		_shaking = true
		_shake_count = 0
	if _shake_count % 2 == 0:
		var off = Vector3.ZERO
		if dist < _cfg["shake_attenu"]:
			off = _shake_dir(cam) * (shake_noise(loop_t) * _dist_co(dist))
		_shake_offset = _damp(ts, off)
	else:
		_shake_offset = -_shake_offset
	_shake_count += 1
	_add_cam_offset(cam, _shake_offset)

# ShakeCamera2: Sinus mit ShakePeriod, je Periode neue Richtung, je halbe Periode gedämpft
func _shake_tick_2(step_ms: float, ts: float, dist: float, cam: Camera3D) -> void:
	var period = float(_cfg["shake_period"])
	var new_dir = false
	if not _shaking:
		_shaking = true
		_s2_time = 0.0
		_s2_half = 0.0
		_s2_cycle = 0
		_s2_last = Vector3.ZERO
		new_dir = true
	if int(_s2_time / period) != _s2_cycle:
		_s2_cycle = int(_s2_time / period)
		new_dir = true
	if new_dir:
		_s2_dir = Vector3.ZERO if dist >= _cfg["shake_attenu"] else _shake_dir(cam) * (_cfg["shake_amp"] * _dist_co(dist))
	_s2_time += step_ms
	var half = floorf(period / 2.0)
	if _s2_half >= half:
		_s2_half -= half
		_s2_dir = _damp(ts, _s2_dir)
	_s2_half += step_ms
	var cur = _s2_dir * sin(TAU * _s2_time / period)
	_add_cam_offset(cam, cur - _s2_last)
	_s2_last = cur

# A3DGFXCtrlNoiseBase::GetNoiseVal(GFX-Zeit in ms), Rauschen wie bei CtrlType 107
func shake_noise(t_ms: float) -> float:
	var n = KP._fbm1d(t_ms / maxf(1.0, _cfg["shake_wave"]), int(_cfg["shake_oct"]), _cfg["shake_pers"])
	return (n * 2.0 - 1.0) * _cfg["shake_amp"]

# GenerateDirection
func _shake_dir(cam: Camera3D) -> Vector3:
	match int(_cfg["shake"]):
		SHAKE_DIR_RAND:
			var x = Quaternion(Vector3.UP, _rng.randf() * TAU) * Vector3.RIGHT
			return (Quaternion(x, _rng.randf() * TAU) * Vector3.UP).normalized()
		SHAKE_DIR_UPDOWN:
			return Vector3.UP
		SHAKE_DIR_CAMERA:
			return -cam.global_basis.z
	return Vector3.ZERO

func _dist_co(dist: float) -> float:
	return 1.0 - dist / _cfg["shake_attenu"] if _cfg["shake_by_dist"] else 1.0

# ShakeAffector: linear 1 - (t - Start) / Dauer, quadratisch ((Ende - t) / Dauer)²
func _damp(ts: float, v: Vector3) -> Vector3:
	var start = float(_cfg["shake_start"])
	var end = float(_cfg["shake_end"])
	if end <= start or ts < start or ts > end:
		return v
	match int(_cfg["shake_damp"]):
		SHAKE_DAMP_LINEAR:
			return v * (1.0 - (ts - start) / (end - start))
		SHAKE_DAMP_QUADRATIC:
			var r = (end - ts) / (end - start)
			return v * r * r
	return v

# AfxSetCamOffset: Versatz addieren (hier auf h_offset / v_offset der Kamera)
func _add_cam_offset(cam: Camera3D, v: Vector3) -> void:
	var hv = Vector2(v.dot(cam.global_basis.x), v.dot(cam.global_basis.y))
	cam.h_offset += hv.x
	cam.v_offset += hv.y
	_shake_hv += hv

func _shake_stop() -> void:
	if _shake_cam != null and is_instance_valid(_shake_cam):
		_shake_cam.h_offset -= _shake_hv.x
		_shake_cam.v_offset -= _shake_hv.y
	_shake_hv = Vector2.ZERO
	_shaking = false
	_shake_offset = Vector3.ZERO
	_s2_last = Vector3.ZERO
	_shake_cam = null

func _as_bool(value) -> bool:
	var s = str(value).strip_edges().to_lower()
	return s == "1" or s == "true"


# ====================================================
# INSPEKTOR (Rohdaten der Kopfzeile)
# ====================================================
func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = []
	props.append({"name": "GFX Kopfzeile (Header)", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY})

	for param in KNOWN_PARAMS:
		var has_param = parsed_data.has(param)
		var prefix = "🟢 " if has_param else "🔵 [Fehlt] "
		# Typ aus dem Dictionary holen. Falls nicht gefunden, als Fallback STRING setzen.
		var expected_type = PARAM_TYPES.get(param, TYPE_STRING)

		props.append({
			"name": prefix + param,
			"type": expected_type,
			"usage": PROPERTY_USAGE_EDITOR
		})
	return props

func _get(property: StringName):
	var prop_str = str(property) # Godot 4: str() anstatt String()
	if not (prop_str.begins_with("🟢 ") or prop_str.begins_with("🔵 ")):
		return null
	for param in KNOWN_PARAMS:
		if prop_str.ends_with(param):
			if parsed_data.has(param):
				var val = parsed_data[param]
				var expected_type = PARAM_TYPES.get(param, TYPE_STRING)

				# === ÜBERSETZER: Text aus Rohdaten -> Godot Objekt ===
				if typeof(val) == TYPE_STRING:
					if expected_type == TYPE_VECTOR3: return _string_to_vector3(val)
					if expected_type == TYPE_FLOAT: return val.to_float()
					if expected_type == TYPE_INT: return val.to_int()
					if expected_type == TYPE_BOOL: return (val == "1" or val.to_lower() == "true")

				return val
			else:
				# GIBT STANDARDS ZURÜCK: Verhindert Editor-Fehler wenn Werte [Fehlen]
				var expected_type = PARAM_TYPES.get(param, TYPE_STRING)
				return _get_default_for_type(expected_type)
	return null

func _set(property: StringName, value: Variant) -> bool:
	var prop_str = str(property)
	if not (prop_str.begins_with("🟢 ") or prop_str.begins_with("🔵 ")):
		return false
	for param in KNOWN_PARAMS:
		if prop_str.ends_with(param):
			var expected_type = PARAM_TYPES.get(param, TYPE_STRING)
			var was_missing = not parsed_data.has(param)

			# === ÜBERSETZER: Godot Objekt -> Text für Rohdaten ===
			if expected_type == TYPE_VECTOR3:
				parsed_data[param] = _vector3_to_string(value)
			elif expected_type == TYPE_FLOAT:
				parsed_data[param] = "%.6f" % value # Erhält deine 6 Nullen nach dem Komma
			elif expected_type == TYPE_INT:
				parsed_data[param] = str(value)
			elif expected_type == TYPE_BOOL:
				parsed_data[param] = "1" if value else "0"
			else:
				# STRING Fallback
				parsed_data[param] = value
			_cfg_dirty = true

			# Wenn der Wert vorher gefehlt hat, updaten wir den Editor (🔵 -> 🟢)
			if was_missing:
				notify_property_list_changed()

			return true
	return false

# --- HELPER FUNKTIONEN ---

func _string_to_vector3(val_str: String) -> Vector3:
	# Filtert Klammern heraus, falls doch mal Werte wie "(1.0, 2.0, 3.0)" aufschlagen
	var clean = val_str.replace("(", "").replace(")", "").replace(" ", "")
	var parts = clean.split(",")
	if parts.size() >= 3:
		return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
	return Vector3.ZERO

func _vector3_to_string(v: Vector3) -> String:
	return "%.6f, %.6f, %.6f" % [v.x, v.y, v.z]

func _get_default_for_type(type: int):
	match type:
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
		TYPE_BOOL: return false
		TYPE_VECTOR3: return Vector3.ZERO
		TYPE_STRING: return ""
	return null
