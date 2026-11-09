@tool
extends Light3D

# ====================================================
# Laufzeit-Treiber für GFXELEMENTID 130 (A3DGFXLight), angelegt von create_id_130.gd.
# A3DGFXLight::TickAnimation übernimmt jeden Frame aus dem aktuellen KeyPoint:
#   Position = kp.m_vPos
#   Richtung = kp.m_vDir * (0, 0, 1)      (nur Spot / Directional)
#   Diffuse  = kp.m_color                 (RGB + Alpha)
# Den KeyPoint-Zustand bestimmt gfx_keypoint_eval.gd wie A3DGFXKeyPointSet::TickAnimation,
# die Zeit läuft wie in den ID_100-Shadern (Time_Manual / GlobalLoopTime / RepeatCount ...).
# ====================================================

const KP = preload("gfx_keypoint_eval.gd")

const LIGHT_POINT = 1
const LIGHT_SPOT = 2
const LIGHT_DIRECTIONAL = 3

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

@export_group("Light")
## A3DLIGHTTYPE: 1 = Point, 2 = Spot, 3 = Directional
@export var Light_Type: int = LIGHT_POINT
## Helligkeit aus Range + Attenuation0..2 (siehe create_id_130.gd)
@export var Energy_Base: float = 1.0
## true: Diffuse * Alpha * 2 (Szenenlicht), false: Diffuse ohne Alpha (InnerUse)
@export var Use_Alpha_Energy: bool = true

@export_group("KeyPoints")
@export var keypoints: Array = []


func _process(_delta: float) -> void:
	apply_time(_clock_ms())

func _clock_ms() -> float:
	return KP.clock_ms(Time_Manual, Time_Ms)

# Setzt das Licht auf den Zustand zur globalen Zeit active_time (ms)
func apply_time(active_time: float) -> void:
	var t = element_time(active_time)
	var active = Is_Endless or (t >= LocalStartTime and t <= LocalTotalTime)
	if not active or keypoints.is_empty():
		# Vor StartTime, in der RepeatDelay-Pause und nach dem Ende ist das Licht aus
		visible = false
		return

	var state = evaluate(t - LocalStartTime)
	var basis = transform.basis
	if Light_Type != LIGHT_POINT:
		# Angelica leuchtet entlang +Z der KeyPoint-Richtung, Godot-Lichter entlang -Z
		var dir: Vector3 = ((state["dir"] as Quaternion) * Vector3.BACK).normalized()
		if dir.length() > 0.000001:
			var up = Vector3.RIGHT if absf(dir.y) > 0.999 else Vector3.UP
			basis = Basis.looking_at(dir, up)
	transform = Transform3D(basis, state["pos"])

	var c: Color = state["color"]
	light_color = Color(c.r, c.g, c.b)
	light_energy = Energy_Base * (c.a * 2.0 if Use_Alpha_Energy else 1.0)
	visible = true

# Element-Zeit in ms (identisch zur Zeit-Synchronisation der ID_100-Shader)
func element_time(active_time: float) -> float:
	return KP.element_time(active_time, GlobalLoopTime, LocalStartTime, LocalTotalTime, RepeatCount, RepeatDelay)

# span_ms = Zeit seit StartTime. Liefert {pos, dir, color, scale, rad}.
func evaluate(span_ms: float) -> Dictionary:
	return KP.evaluate(keypoints, span_ms)
