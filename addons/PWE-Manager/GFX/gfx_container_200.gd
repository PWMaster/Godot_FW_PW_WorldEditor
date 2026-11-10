@tool
extends Node3D

# ====================================================
# Laufzeit-Treiber für GFXELEMENTID 200 (A3DGFXContainer), angelegt von create_id_200.gd.
# Die Unter-GFX (GfxPath aus den Spieldaten) liegt fertig aufgebaut als Kind "Sub_GFX"
# und wird von hier gesteuert, wie A3DGFXContainer::TickAnimation:
#   - Lage  = GetTranMatrix(kp) (Position, Richtung * Rad_2D um Z),
#             Scale = kp.Scale * DedaultScale der Unter-GFX (A3DGFXEx::CalcActualScale)
#   - Zeit  = Time_Manual / Time der Unter-GFX: läuft nur, solange der Container aktiv ist,
#             mal PlaySpeed des Containers * PlaySpeed der Unter-GFX (m_fActualSpeed);
#             LoopFlag startet sie bei jeder Wiederholung neu, ein neuer GFX-Durchlauf immer.
#             Die Unter-GFX läuft einmal durch (ihr GlobalLoopTime wird abgeschaltet).
#   - Alpha = kp-Alpha (Uniform GFX_Alpha der Element-Shader, auf eigenen Material-Kopien)
# Dummy-Container (IsDummy) zeigt Angelica nur an den Partikeln eines anderen Elements
# (DummyEle): er selbst bleibt unsichtbar, Kopien seiner Unter-GFX führt gfx_dummy_particles.gd.
# ====================================================

const KP = preload("gfx_keypoint_eval.gd")
const SUB_GFX_NODE_NAME = "Sub_GFX"
const NO_LOOP_MS = 1000000000.0 # GlobalLoopTime der Unter-GFX: kein eigener Neustart

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

@export_group("Container")
## GfxPath aus der .gfx (relativ zum gfx-Ordner der Spieldaten)
@export var Gfx_Path: String = ""
## PlaySpeed: Tempo der Unter-GFX (mal deren eigenem PlaySpeed)
@export var Play_Speed: float = 1.0
## PlaySpeed aus der Kopfzeile der Unter-GFX (beim Erstellen übernommen)
@export var Sub_Gfx_Speed: float = 1.0
## DedaultScale aus der Kopfzeile der Unter-GFX (beim Erstellen übernommen)
@export var Sub_Gfx_Scale: float = 1.0
## LoopFlag: Unter-GFX bei jeder Wiederholung des Containers neu starten
@export var Loop_Flag: bool = false
## OutColor: KeyPoint-Farbe tönt die Unter-GFX (noch nicht umgesetzt)
@export var Outer_Color: bool = false
## IsDummy: nur an den Partikeln von Dummy_Users sichtbar (Kopien der Unter-GFX, gfx_dummy_particles.gd)
@export var Is_Dummy: bool = false:
	set(value):
		Is_Dummy = value
		update_configuration_warnings()
## DummyUseGScale: als Dummy zusätzlich mit dem GFX-Scale skalieren
@export var Dummy_Use_GScale: bool = true
## Elemente, die diesen Container als DummyEle nutzen (nur zur Info)
@export var Dummy_Users: String = ""
## Unter-GFX neu aus den Spieldaten aufbauen (nur im Editor)
@export_tool_button("Перезагрузить вложенные GFX", "Reload") var btn_reload = rebuild_sub_gfx

@export_group("KeyPoints")
@export var keypoints: Array = []

var _materials: Array = [] # ShaderMaterials der Unter-GFX
var _drivers: Array = [] # Treiber-Nodes der Unter-GFX (Time_Manual / Time_Ms)
var _geometries: Array = []
var _last_alpha = -1.0


func _ready() -> void:
	prepare_sub_gfx(true)

func _process(_delta: float) -> void:
	apply_time(_clock_ms())

func _clock_ms() -> float:
	return KP.clock_ms(Time_Manual, Time_Ms)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings = PackedStringArray()
	if Is_Dummy:
		warnings.append("Dummy-Element: Angelica zeigt es nur an den Partikeln von " + (Dummy_Users if Dummy_Users != "" else "einem Partikel-Element (DummyEle)") + ". Der Container selbst bleibt unsichtbar, die Kopien an den Partikeln führt deren Dummy_Particles.")
	if get_node_or_null(SUB_GFX_NODE_NAME) == null:
		warnings.append("Unter-GFX fehlt: gfx\\" + Gfx_Path + " nicht in den Spieldaten (Leiste ECM-GFX-MAP: Spieldaten-Ordner, dann 'Unter-GFX neu laden')")
	return warnings


# ====================================================
# UNTER-GFX VORBEREITEN / NEU AUFBAUEN
# ====================================================
# Zeit der Unter-GFX kommt von hier: Time_Manual an, eigener Loop aus.
# duplicate_materials: eigene Material-Kopien (z.B. nach Duplizieren des Containers im Editor)
func prepare_sub_gfx(duplicate_materials: bool) -> void:
	_materials.clear()
	_drivers.clear()
	_geometries.clear()
	_last_alpha = -1.0
	var sub = get_node_or_null(SUB_GFX_NODE_NAME)
	if sub != null:
		sub.transform = Transform3D.IDENTITY
		_prepare(sub, duplicate_materials)
	update_configuration_warnings()

func _prepare(node: Node, duplicate_materials: bool) -> void:
	if node is GeometryInstance3D:
		_geometries.append(node)
		var mat = node.material_override
		var shaded = mat is ShaderMaterial and mat.shader != null
		var timed = shaded and _has_uniform(mat.shader, "Time_Manual")
		# Eigene Kopie auch für GFX_Alpha allein (Material-Uniform)
		if duplicate_materials and (timed or (shaded and _has_uniform(mat.shader, "GFX_Alpha"))):
			mat = mat.duplicate()
			node.material_override = mat
		if timed:
			mat.set_shader_parameter("Time_Manual", true)
			mat.set_shader_parameter("GlobalLoopTime", NO_LOOP_MS)
			_materials.append(mat)
	# Der Header der Unter-GFX (gfx_data_node.gd) bleibt unter dem Container passiv
	if "Time_Manual" in node and "Time_Ms" in node and not node.has_method("is_passive"):
		node.Time_Manual = true
		node.GlobalLoopTime = NO_LOOP_MS
		_drivers.append(node)
		# Ein Container in der Unter-GFX steuert seinen eigenen Teilbaum
		if node.get_script() == get_script():
			return
	for child in node.get_children():
		_prepare(child, duplicate_materials)

func _has_uniform(shader: Shader, uniform_name: String) -> bool:
	for u in shader.get_shader_uniform_list():
		if u["name"] == uniform_name:
			return true
	return false

# Button: Unter-GFX aus den Spieldaten neu aufbauen (Erstell-Skripte gibt es nur im Editor)
func rebuild_sub_gfx() -> void:
	if not Engine.is_editor_hint():
		return
	var dir = get_script().resource_path.get_base_dir()
	var creator = load(dir.path_join("create_id_200.gd")).new()
	var sub = creator.build_sub_gfx(Gfx_Path)
	creator.free()
	var sources = load(dir.path_join("gfx_sources.gd"))
	for w in sources.take_warnings():
		print("GFX: ", w)
	sources.release()
	var old = get_node_or_null(SUB_GFX_NODE_NAME)
	if old != null:
		remove_child(old)
		old.queue_free()
	if sub != null:
		add_child(sub)
		if owner != null:
			_set_owner_recursive(sub, owner)
		Sub_Gfx_Speed = float(sub.parsed_data.get("PlaySpeed", 1.0))
		Sub_Gfx_Scale = float(sub.parsed_data.get("DedaultScale", 1.0))
	prepare_sub_gfx(false)
	if Engine.has_singleton(&"EditorInterface"):
		Engine.get_singleton(&"EditorInterface").mark_scene_as_unsaved()

func _set_owner_recursive(node: Node, new_owner: Node) -> void:
	node.owner = new_owner
	for child in node.get_children():
		_set_owner_recursive(child, new_owner)


# ====================================================
# ZUSTAND ZUR GLOBALEN ZEIT (A3DGFXContainer::TickAnimation)
# ====================================================
func apply_time(active_time: float) -> void:
	if Is_Dummy or get_node_or_null(SUB_GFX_NODE_NAME) == null:
		visible = false
		return
	var t = element_time(active_time)
	var active = Is_Endless or (t >= LocalStartTime and t <= LocalTotalTime)
	if not active or keypoints.is_empty():
		# Vor StartTime, in der RepeatDelay-Pause und nach dem Ende tickt und zeichnet die Unter-GFX nicht
		visible = false
		return

	var state = KP.evaluate(keypoints, maxf(0.0, t - LocalStartTime))
	var s: float = state["scale"] * Sub_Gfx_Scale
	if absf(s) < 0.000001:
		visible = false
		return
	# SetParentTM(GetTranMatrix(kp) * GetParentTM()), SetScale(kp.m_fScale * ...)
	var q: Quaternion = state["dir"]
	var rad: float = state["rad"]
	if rad != 0.0:
		q = q * Quaternion(Vector3.BACK, rad)
	transform = Transform3D(Basis(q).scaled(Vector3(s, s, s)), state["pos"])
	# NoChangeDir der Unter-GFX: sie folgt nur Lage und Scale
	var sub = get_node_or_null(SUB_GFX_NODE_NAME)
	if sub != null and sub.has_method("apply_no_change_dir"):
		sub.apply_no_change_dir()
	_apply_alpha((state["color"] as Color).a)
	_push_time(sub_gfx_ms(active_time) * Play_Speed * Sub_Gfx_Speed)
	visible = true

# Element-Zeit in ms (identisch zur Zeit-Synchronisation der ID_100-Shader)
func element_time(active_time: float) -> float:
	return KP.element_time(active_time, GlobalLoopTime, LocalStartTime, LocalTotalTime, RepeatCount, RepeatDelay)

# Zeit der Unter-GFX in Container-ms (vor PlaySpeed): sie tickt nur, solange der Container aktiv ist.
# LoopFlag: ResumeLoop startet sie bei jeder Wiederholung neu, sonst läuft sie über die Wiederholungen weiter.
func sub_gfx_ms(active_time: float) -> float:
	if LocalTotalTime <= 0.0:
		return maxf(0.0, active_time - LocalStartTime)
	var f_repeat = float(RepeatCount)
	var t_global = active_time
	if f_repeat >= 0.0:
		t_global = fmod(active_time, maxf(0.001, GlobalLoopTime))
	var t_since_start = t_global - LocalStartTime
	if t_since_start < 0.0:
		return 0.0
	if Is_Endless:
		return t_since_start
	var active_duration = maxf(0.001, LocalTotalTime - LocalStartTime)
	var full_duration = active_duration + maxf(0.0, RepeatDelay)
	var loop = floor(t_since_start / full_duration)
	var in_loop = minf(fmod(t_since_start, full_duration), active_duration)
	if f_repeat >= 0.0 and loop >= f_repeat:
		return active_duration if Loop_Flag else f_repeat * active_duration
	if Loop_Flag:
		return in_loop
	return loop * active_duration + in_loop

func _push_time(ms: float) -> void:
	for mat in _materials:
		mat.set_shader_parameter("Time", ms)
	for driver in _drivers:
		driver.Time_Ms = ms

# SetAlpha(kp-Alpha): ganze Unter-GFX (Forward+ / Mobile)
func _apply_alpha(a: float) -> void:
	if absf(a - _last_alpha) < 0.001:
		return
	_last_alpha = a
	for g in _geometries:
		preload("gfx_parser.gd").set_gfx_alpha(g, a)
