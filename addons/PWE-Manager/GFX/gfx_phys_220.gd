@tool
extends MultiMeshInstance3D

# ====================================================
# Laufzeit-Treiber für GFXELEMENTID 220 (A3DPhysEmitter), angelegt von create_id_220.gd.
# Angelica lässt die Partikel von PhysX als Fluid simulieren (NX_F_NO_PARTICLE_INTERACTION:
# jedes Partikel fliegt für sich). Hier wird das im PhysX-Takt (1/60 s) nachgerechnet:
#  - Start mit dem Element (OnActive), am Element-Ende verschwinden alle Partikel (OnFinish).
#  - Emitter: Emitter_Pose auf GetTranMatrix(kp) * GetParentTM() ohne GFX-Scale.
#    Fläche Rechteck / Ellipse mit Radien Emitter_Dimension + Random_Pos, Richtung lokales +Z
#    mit bis zu Random_Angle Abweichung, Velocity m/s (+ Bewegung des Emitters),
#    Rate Partikel / s, höchstens Emitter_Max_Particles (0 = unbegrenzt) und Max_Particles.
#  - Bewegung: Schwerkraft der PhysX-Szene (0, -9.81, 0) + External_Acceleration, Damping,
#    höchstens Motion_Limit m je Schritt, Lebensdauer Lifetime s (0 = unbegrenzt).
#  - Statische Kollision: Boden-Ebene Ground_Height über dem GFX-Ursprung (das Spiel kollidiert
#    mit dem Terrain) und optional die Godot-Physik der Szene (Scene_Collision):
#    Normal-Geschwindigkeit * -Restitution, tangential * (1 - Dynamic_Friction),
#    Abstand Collision_Distance zur Oberfläche.
# Gezeichnet wird je Partikel ein Quad (Shader von create_id_220.gd), Instanz-Daten:
#   Farbe = Partikelfarbe, Alpha = int(Partikel-Alpha * KeyPoint-Alpha), unter 5 nicht gezeichnet;
#   Custom = (GFX-Scale * KeyPoint-Scale * Partikel-Scale, 2D-Drehung). Die KeyPoint-Farbe
#   selbst färbt nicht (A3DPhysEmitter::Update_2D).
# Gleicher Zufall bei jedem Durchlauf (Random_Seed), Zurückspulen rechnet neu ab dem Start.
# ====================================================

const KP = preload("gfx_keypoint_eval.gd")
const STEP = 1.0 / 60.0 # APhysXSceneDesc::mTimeStep
const MAX_POOL = 1024 # A3DPhysEmitter::s_MaxSupportParticleNum
const MAX_STEPS_PER_FRAME = 600 # längere Sprünge: nur die letzten Partikel-Leben nachrechnen

@export_group("Time_Settings")
@export var Time_Manual: bool = false
## Manuelle Zeit in ms (entspricht dem Shader-Parameter "Time")
@export var Time_Ms: float = 0.0
@export var GlobalLoopTime: float = 3000.0
@export var LocalStartTime: float = 0.0
@export var LocalTotalTime: float = 3000.0
@export var Is_Endless: bool = false
@export var RepeatCount: int = 1
@export var RepeatDelay: float = 0.0

@export_group("Particles")
## ParWidth / ParHeight: halbe Breite / Höhe eines Partikels
@export var Par_Width: float = 1.0:
	set(value):
		Par_Width = value
		_set_shader("Par_Width", value)
@export var Par_Height: float = 1.0:
	set(value):
		Par_Height = value
		_set_shader("Par_Height", value)
@export var Scale_Min: float = 1.0
@export var Scale_Max: float = 1.0
## 2D-Drehung in Bogenmaß
@export var Rot_Min: float = 0.0
@export var Rot_Max: float = 0.0
@export var Color_Min: Color = Color.WHITE
@export var Color_Max: Color = Color.WHITE
## IsFaceToView: 0 = Quad in der Welt (X / Y), 1 = zur Kamera, 2 = PhysX-Drehung (wie 0)
@export_enum("Normal", "Face_To_View", "Phys_Orient") var Par_Type: int = 1:
	set(value):
		Par_Type = value
		_set_shader("Par_Type", value)
@export var Random_Seed: int = 0

@export_group("Physics")
## PhysDesc in der .gphy
@export var Phys_Desc: String = ""
@export var Phys_File: String = ""
@export var Emitter_Enabled: bool = true
## relPose des Emitters (Ausstoß entlang lokal +Z)
@export var Emitter_Pose: Transform3D = Transform3D.IDENTITY
@export_enum("Rectangular:1", "Ellipse:2") var Emitter_Shape: int = 2
@export var Emitter_Dimension: Vector2 = Vector2(0.25, 0.25)
@export var Random_Pos: Vector3 = Vector3(0.05, 0.05, 0.05)
## Abweichung von +Z in Bogenmaß (ab PI in alle Richtungen)
@export var Random_Angle: float = 0.5
@export var Velocity: float = 5.0
@export var Rate: float = 100.0
@export var Emitter_Max_Particles: int = 0
## Lebensdauer in s (0 = unbegrenzt)
@export var Lifetime: float = 10.0
@export var Max_Particles: int = 1000
@export var Add_Body_Velocity: bool = true
@export var Gravity: Vector3 = Vector3(0, -9.81, 0)
@export var Disable_Gravity: bool = false
@export var External_Acceleration: Vector3 = Vector3.ZERO
@export var Damping: float = 0.0
@export var Motion_Limit: float = 0.36
@export var Collision_Distance: float = 0.012
@export var Restitution: float = 0.5
@export var Dynamic_Friction: float = 0.05

@export_group("Collision")
## Boden-Ebene als Ersatz für das Terrain des Spiels
@export var Ground_Collision: bool = true
## Höhe der Boden-Ebene über dem GFX-Ursprung
@export var Ground_Height: float = 0.0
## Zusätzlich gegen die Godot-Physik der Szene (Kollisionsformen)
@export var Scene_Collision: bool = false

@export_group("KeyPoints")
@export var keypoints: Array = []

# Simulation (nicht gespeichert)
var _steps = 0
var _emitted = 0
var _prev_origin = Vector3.ZERO
var _pos = PackedVector3Array()
var _vel = PackedVector3Array()
var _life = PackedFloat64Array()
var _scale = PackedFloat32Array()
var _rot = PackedFloat32Array()
var _color = PackedColorArray()


func _ready() -> void:
	# Partikel liegen in Welt-Koordinaten
	top_level = true
	transform = Transform3D.IDENTITY
	_set_shader("Par_Width", Par_Width)
	_set_shader("Par_Height", Par_Height)
	_set_shader("Par_Type", Par_Type)
	reset()

func _process(_delta: float) -> void:
	apply_time(KP.clock_ms(Time_Manual, Time_Ms))

func _set_shader(param: String, value) -> void:
	if material_override is ShaderMaterial:
		material_override.set_shader_parameter(param, value)

# Größe des Partikel-Speichers (MultiMesh)
func pool_size() -> int:
	var n = Max_Particles
	if Emitter_Max_Particles > 0:
		n = mini(n, Emitter_Max_Particles)
	if Lifetime > 0.0:
		n = mini(n, int(ceil(Rate * (Lifetime + STEP))) + 1)
	return clampi(n, 1, MAX_POOL)

func particle_count() -> int:
	return _pos.size()

func particle_positions() -> PackedVector3Array:
	return _pos

func particle_velocities() -> PackedVector3Array:
	return _vel


# ====================================================
# ZEIT (gleiche Element-Zeit wie die Shader)
# ====================================================
func element_time(active_time: float) -> float:
	return KP.element_time(active_time, GlobalLoopTime, LocalStartTime, LocalTotalTime, RepeatCount, RepeatDelay)

func apply_time(active_time: float) -> void:
	var t = element_time(active_time)
	var active = Is_Endless or (t >= LocalStartTime and t <= LocalTotalTime)
	if not active or keypoints.is_empty():
		# Vor dem Start nichts, nach dem Element-Ende gibt OnFinish das Fluid frei
		if _steps > 0:
			reset()
		if multimesh != null:
			multimesh.visible_instance_count = 0
		return
	simulate_to((t - LocalStartTime) / 1000.0)
	_draw(t)

# Bis zur Zeit tau (s seit dem Start) rechnen
func simulate_to(tau: float) -> void:
	var target = int(floor(tau / STEP + 0.000001))
	if target < _steps:
		reset()
	if target - _steps > MAX_STEPS_PER_FRAME:
		_skip_to(target - MAX_STEPS_PER_FRAME)
	while _steps < target:
		_step()

func reset() -> void:
	_steps = 0
	_emitted = 0
	_pos.clear()
	_vel.clear()
	_life.clear()
	_scale.clear()
	_rot.clear()
	_color.clear()
	_prev_origin = _emitter_transform(0.0).origin

# Lange Sprünge (z.B. endlose Elemente): ältere Partikel wären ohnehin verloschen
func _skip_to(steps: int) -> void:
	reset()
	_steps = steps
	_emitted = _emit_total(steps)
	if Emitter_Max_Particles > 0:
		_emitted = mini(_emitted, Emitter_Max_Particles)
	_prev_origin = _emitter_transform(steps * STEP * 1000.0).origin


# ====================================================
# EIN PHYSX-SCHRITT
# ====================================================
func _step() -> void:
	var em = _emitter_transform(_steps * STEP * 1000.0)
	# Der Emitter entsteht mit OnActive an der aktuellen Lage: im ersten Schritt ruht er
	if _steps == 0:
		_prev_origin = em.origin
	var body_vel = (em.origin - _prev_origin) / STEP if Add_Body_Velocity else Vector3.ZERO
	_prev_origin = em.origin

	# NX_FE_CONSTANT_FLOW_RATE: Rate * dt sammelt sich, je volles Partikel eines
	# (über die Schrittzahl gezählt, damit z.B. 20 / s genau jeden 3. Schritt ausstößt)
	if Emitter_Enabled:
		var due = _emit_total(_steps + 1) - _emit_total(_steps)
		for k in range(due):
			if Emitter_Max_Particles > 0 and _emitted >= Emitter_Max_Particles:
				break
			if _pos.size() >= mini(Max_Particles, MAX_POOL):
				break
			_spawn(em, body_vel)

	var acc = External_Acceleration + (Vector3.ZERO if Disable_Gravity else Gravity)
	var ground_y = _ground_y()
	var space = _space_state() if Scene_Collision else null
	var i = 0
	while i < _pos.size():
		if Lifetime > 0.0:
			_life[i] -= STEP
			if _life[i] <= 0.000001:
				_remove(i)
				continue
		var v = (_vel[i] + acc * STEP) * maxf(0.0, 1.0 - Damping * STEP)
		var d = v * STEP
		if d.length() > Motion_Limit:
			d = d.normalized() * Motion_Limit
		var old = _pos[i]
		var p = old + d
		if space != null:
			var hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(old, p + d.normalized() * Collision_Distance))
			if not hit.is_empty():
				p = hit["position"] + hit["normal"] * Collision_Distance
				v = _collide(v, hit["normal"])
		if Ground_Collision and p.y < ground_y + Collision_Distance:
			p.y = ground_y + Collision_Distance
			v = _collide(v, Vector3.UP)
		_pos[i] = p
		_vel[i] = v
		i += 1
	_steps += 1

func _emit_total(steps: int) -> int:
	return int(floor(steps * Rate * STEP + 0.00001))

# Normal-Anteil prallt mit Restitution ab, tangential bremst die Reibung
func _collide(v: Vector3, n: Vector3) -> Vector3:
	var vn = v.dot(n)
	if vn >= 0.0:
		return v
	var tangential = v - n * vn
	return tangential * (1.0 - Dynamic_Friction) - n * vn * Restitution

func _spawn(em: Transform3D, body_vel: Vector3) -> void:
	var rng = RandomNumberGenerator.new()
	rng.seed = hash([Random_Seed, _emitted])
	_emitted += 1
	var local: Vector3
	if Emitter_Shape == 1:
		local = Vector3(rng.randf_range(-1.0, 1.0) * Emitter_Dimension.x, rng.randf_range(-1.0, 1.0) * Emitter_Dimension.y, 0.0)
	else:
		var r = sqrt(rng.randf())
		var a = rng.randf() * TAU
		local = Vector3(r * cos(a) * Emitter_Dimension.x, r * sin(a) * Emitter_Dimension.y, 0.0)
	local += Vector3(rng.randf_range(-1.0, 1.0) * Random_Pos.x, rng.randf_range(-1.0, 1.0) * Random_Pos.y, rng.randf_range(-1.0, 1.0) * Random_Pos.z)
	# Richtung: gleichverteilt im Kegel um +Z (ab PI: Kugel)
	var cos_t = lerpf(1.0, cos(minf(absf(Random_Angle), PI)), rng.randf())
	var sin_t = sqrt(maxf(0.0, 1.0 - cos_t * cos_t))
	var phi = rng.randf() * TAU
	var dir = em.basis * Vector3(sin_t * cos(phi), sin_t * sin(phi), cos_t)
	_pos.append(em * local)
	_vel.append(dir.normalized() * Velocity + body_vel)
	_life.append(Lifetime)
	# A3DPhysEmitter::InitParticle
	_scale.append(lerpf(Scale_Min, Scale_Max, rng.randf()))
	_rot.append(_norm_rot(lerpf(Rot_Min, Rot_Max, rng.randf())))
	_color.append(_rand_color(rng))

func _remove(i: int) -> void:
	_pos.remove_at(i)
	_vel.remove_at(i)
	_life.remove_at(i)
	_scale.remove_at(i)
	_rot.remove_at(i)
	_color.remove_at(i)

# A3DPhysParticle::Set2DRot
func _norm_rot(r: float) -> float:
	var n = int(r / TAU)
	return r - TAU * n if r > 0.0 else r + TAU * (n + 1)

# genRandColor: je Kanal int(Min * (1 - f) + Max * f)
func _rand_color(rng: RandomNumberGenerator) -> Color:
	if Color_Min == Color_Max:
		return Color_Min
	var c = Color()
	for ch in range(4):
		var f = rng.randf()
		c[ch] = floor(roundf(Color_Min[ch] * 255.0) * (1.0 - f) + roundf(Color_Max[ch] * 255.0) * f) / 255.0
	return c

# GetTranMatrix(kp) * GetParentTM() ohne Scale, darauf die relPose des Emitters
func _emitter_transform(span_ms: float) -> Transform3D:
	var parent_tm = _parent_tm()
	var origin = parent_tm.origin
	var rot = parent_tm.basis.orthonormalized()
	if keypoints.is_empty():
		return Transform3D(rot, origin) * Emitter_Pose
	var state = KP.evaluate(keypoints, span_ms)
	var q: Quaternion = state["dir"]
	if state["rad"] != 0.0:
		q = q * Quaternion(Vector3.BACK, state["rad"])
	return Transform3D(rot * Basis(q), parent_tm * (state["pos"] as Vector3)) * Emitter_Pose

func _parent_tm() -> Transform3D:
	var p = get_parent() as Node3D
	return p.global_transform if p != null and p.is_inside_tree() else Transform3D.IDENTITY

func _ground_y() -> float:
	return _parent_tm().origin.y + Ground_Height

func _space_state() -> PhysicsDirectSpaceState3D:
	if not is_inside_tree() or get_world_3d() == null:
		return null
	return get_world_3d().direct_space_state


# ====================================================
# ZEICHNEN (A3DPhysEmitter::Update_2D / Update_3D)
# ====================================================
func _draw(t: float) -> void:
	if multimesh == null:
		return
	var span = maxf(0.0, t - LocalStartTime)
	_set_shader("Element_Time", span)
	var state = KP.evaluate(keypoints, span)
	var alpha_kp: float = (state["color"] as Color).a
	var s: float = _parent_tm().basis.x.length() * float(state["scale"])
	# Rate / Maximum im Inspektor geändert: Speicher anpassen
	if multimesh.instance_count != pool_size():
		multimesh.instance_count = pool_size()
	var n = 0
	var cap = multimesh.instance_count
	for i in range(_pos.size()):
		if n >= cap:
			break
		var c: Color = _color[i]
		var a = int(roundf(c.a * 255.0) * alpha_kp)
		if a < 5:
			continue
		multimesh.set_instance_transform(n, Transform3D(Basis.IDENTITY, _pos[i]))
		multimesh.set_instance_color(n, Color(c.r, c.g, c.b, a / 255.0))
		multimesh.set_instance_custom_data(n, Color(s * _scale[i], _rot[i], 0.0, 0.0))
		n += 1
	multimesh.visible_instance_count = n
