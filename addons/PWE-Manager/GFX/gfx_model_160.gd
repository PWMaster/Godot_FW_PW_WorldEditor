@tool
extends Node3D

# ====================================================
# Laufzeit-Treiber für GFXELEMENTID 160 (A3DGFXModel), angelegt von create_id_160.gd.
# A3DGFXModel::TickAnimation / UpdateModel übernimmt jeden Frame aus dem aktuellen KeyPoint:
#   Transform = Scale(kp.m_fScale) * GetTranMatrix(kp)   (Richtung * Rad_2D um Z, Position)
#   Farbe     = kp.m_color: RGB skaliert das Material (MTL_SCALED), Alpha -> SetTransparent(1 - a)
#   Aktion    = PlayActionByNameDC(ModelActName, Loops) beim ersten aktiven Tick
#   FacingDir = Blick in Bewegungsrichtung (PrepareRenderSkinModel, nur geteilte Modelle ohne Aktion)
# Den KeyPoint-Zustand bestimmt gfx_keypoint_eval.gd, die Zeit läuft wie in den ID_100-Shadern.
# Das Modell (Model_Resource) wird als interner Child-Node instanziert und nicht mitgespeichert.
# ====================================================

const KP = preload("gfx_keypoint_eval.gd")

const ALPHA_REF = 84.0 / 255.0 # SetAlphaRef(84) der Angelica-Modell-Elemente
const FACING_SAMPLE_MS = 20.0 # Abstand der Positionsproben für die Bewegungsrichtung

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

@export_group("Model")
## ModelPath aus der .gfx (relativ zu gfx\Models\), nur zur Info
@export var Model_Path: String = ""
## Konvertiertes Modell: PackedScene (.glb / .gltf / .tscn ...) oder Mesh
@export var Model_Resource: Resource:
	set(value):
		Model_Resource = value
		_dirty = true
		update_configuration_warnings()
## ModelActName: Aktion (Animation) des Modells, leer = keine
@export var Action_Name: String = "":
	set(value):
		Action_Name = value
		_dirty = true
## Loops: Wiederholungen der Aktion, -1 = endlos
@export var Action_Loops: int = 1
## FacingDir: Modell blickt in Bewegungsrichtung (wirkt nur ohne Aktion)
@export var Facing_Dir: bool = false
## DestBlend ONE / INVSRCCOLOR: additiv statt Alpha-Mischung
@export var Blend_Add: bool = false:
	set(value):
		Blend_Add = value
		_dirty = true
## AlphaCmp: Alpha-Test mit Referenz 84
@export var Alpha_Compare: bool = false:
	set(value):
		Alpha_Compare = value
		_dirty = true
## WriteZ: Tiefe schreiben (sonst wie ein Effekt im transparenten Durchgang)
@export var Z_Write: bool = false:
	set(value):
		Z_Write = value
		_dirty = true
## ZEnable: Tiefentest
@export var Z_Test: bool = true:
	set(value):
		Z_Test = value
		_dirty = true

@export_group("KeyPoints")
@export var keypoints: Array = []:
	set(value):
		keypoints = value
		_dirty = true

var _dirty = true
var _model: Node = null
var _player: AnimationPlayer = null
var _anim_name: StringName = &""
var _alpha_geometries: Array = [] # Geometrie mit fremdem Material (ShaderMaterial): Alpha über transparency
var _materials: Array = [] # {mat, albedo, emission}
var _needs_alpha = false
var _last_color = null
var _last_span = -1.0
var _last_move_dir = Vector3.ZERO


func _ready() -> void:
	if _dirty:
		rebuild_model()

func _process(_delta: float) -> void:
	apply_time(_clock_ms())

func _clock_ms() -> float:
	return KP.clock_ms(Time_Manual, Time_Ms)

func _get_configuration_warnings() -> PackedStringArray:
	if Model_Resource == null:
		return PackedStringArray(["Kein Modell geladen: Gfx\\Models\\" + Model_Path + " nicht in den Spieldaten (Leiste ECM-GFX-MAP: Spieldaten-Ordner), dann Element neu erstellen"])
	return PackedStringArray()


# ====================================================
# MODELL INSTANZIEREN (A3DGFXModel::ChangeModel)
# ====================================================
func rebuild_model() -> void:
	_dirty = false
	if _model != null:
		remove_child(_model)
		_model.queue_free()
	_model = null
	_player = null
	_anim_name = &""
	_alpha_geometries.clear()
	_materials.clear()
	_last_color = null
	_needs_alpha = _can_fade()

	var inst: Node = null
	if Model_Resource is PackedScene:
		inst = (Model_Resource as PackedScene).instantiate()
	elif Model_Resource is Mesh:
		inst = MeshInstance3D.new()
		inst.mesh = Model_Resource
	if inst == null:
		return

	# Die Aktion steuert apply_time, nichts darf von selbst abspielen
	_player = _find_player(inst)
	if _player != null:
		_player.autoplay = ""
		_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		_anim_name = _match_animation(_player, Action_Name.strip_edges())
		if _anim_name == &"" and Action_Name.strip_edges() != "":
			push_warning("GFX Model: Aktion '" + Action_Name + "' nicht im Modell " + Model_Path + " gefunden")

	add_child(inst, false, Node.INTERNAL_MODE_BACK)
	_model = inst
	_setup_materials(inst)

func _find_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children(true):
		var p = _find_player(child)
		if p != null:
			return p
	return null

# Angelica-Aktionsname -> Godot-Animation (auch in benannten Bibliotheken, ohne Groß/Klein)
func _match_animation(player: AnimationPlayer, act_name: String) -> StringName:
	if act_name == "":
		return &""
	var names = player.get_animation_list()
	for n in names:
		if n == act_name:
			return StringName(n)
	for n in names:
		if n.get_slice("/", n.get_slice_count("/") - 1).to_lower() == act_name.to_lower():
			return StringName(n)
	return &""

# Kann die KeyPoint-Farbe je unter Alpha 1 fallen? (KeyPoint-Farben, 105 / 107 / 108)
func _can_fade() -> bool:
	for kp in keypoints:
		if (kp["color"] as Color).a < 0.999:
			return true
		for c in kp["ctrls"]:
			match int(c["type"]):
				105:
					if (c["delta"] as Color).a < 0.0:
						return true
				107:
					return true
				108:
					for col in c["colors"]:
						if (col as Color).a < 0.999:
							return true
	return false

# Eigene Materialkopien: Farbe skalieren (MTL_SCALED) + Blend / Z-Zustand der .gfx
func _setup_materials(node: Node) -> void:
	if node is GeometryInstance3D:
		var own_alpha = false
		if node is MeshInstance3D and node.mesh != null:
			var mi: MeshInstance3D = node
			own_alpha = true
			if mi.material_override != null:
				mi.material_override = _prepare_material(mi.material_override)
				own_alpha = mi.material_override is BaseMaterial3D
			else:
				for s in range(mi.mesh.get_surface_count()):
					var nm = _prepare_material(mi.get_active_material(s))
					mi.set_surface_override_material(s, nm)
					own_alpha = own_alpha and nm is BaseMaterial3D
		if not own_alpha:
			_alpha_geometries.append(node)
	for child in node.get_children(true):
		_setup_materials(child)

func _prepare_material(src: Material) -> Material:
	var mat: BaseMaterial3D
	if src == null:
		mat = StandardMaterial3D.new()
	elif src is BaseMaterial3D:
		mat = src.duplicate()
	else:
		return src # ShaderMaterial: Alpha nur über GeometryInstance3D.transparency (Forward+ / Mobile)

	# Ohne WriteZ zeichnet Angelica das Modell nach der Szene wie einen Effekt.
	# Kann es ausblenden, liegt es von Anfang an im Alpha-Durchgang (kein Shaderwechsel zur Laufzeit).
	if Blend_Add or not Z_Write or _needs_alpha:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	elif Alpha_Compare:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = ALPHA_REF
	if Blend_Add:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS if Z_Write else BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.no_depth_test = not Z_Test
	_materials.append({"mat": mat, "albedo": mat.albedo_color, "emission": mat.emission})
	return mat


# ====================================================
# ZUSTAND ZUR GLOBALEN ZEIT (A3DGFXModel::TickAnimation / UpdateModel)
# ====================================================
func apply_time(active_time: float) -> void:
	if _dirty:
		rebuild_model()
	var t = element_time(active_time)
	var active = Is_Endless or (t >= LocalStartTime and t <= LocalTotalTime)
	if not active or keypoints.is_empty():
		# Vor StartTime, in der RepeatDelay-Pause und nach dem Ende ist das Modell unsichtbar
		visible = false
		return

	var span = maxf(0.0, t - LocalStartTime)
	var state = evaluate(span)
	var s: float = state["scale"]
	if absf(s) < 0.000001:
		visible = false
		return

	# GetTranMatrix: kp.m_vDir * A3DQUATERNION(_unit_z, m_fRad2D)
	var q: Quaternion = state["dir"]
	var rad: float = state["rad"]
	if rad != 0.0:
		q = q * Quaternion(Vector3.BACK, rad)
	var basis = Basis(q)

	if Facing_Dir and Action_Name.strip_edges() == "":
		# SetDirAndUp(Bewegungsrichtung, Y-Achse des Transforms), nur bei geteiltem Modell ohne Aktion
		var move = _movement_dir(span, state["pos"])
		if move != Vector3.ZERO:
			basis = _dir_up_basis(move, basis.y)

	transform = Transform3D(basis.scaled(Vector3(s, s, s)), state["pos"])
	_apply_color(state["color"])
	if _player != null and _anim_name != &"":
		_apply_action(_action_ms(active_time))
	visible = true

# Element-Zeit in ms (identisch zur Zeit-Synchronisation der ID_100-Shader)
func element_time(active_time: float) -> float:
	return KP.element_time(active_time, GlobalLoopTime, LocalStartTime, LocalTotalTime, RepeatCount, RepeatDelay)

# span_ms = Zeit seit StartTime. Liefert {pos, dir, color, scale, rad}.
func evaluate(span_ms: float) -> Dictionary:
	return KP.evaluate(keypoints, span_ms)

# RGB skaliert die Materialfarbe, Alpha die Deckkraft des ganzen Modells
# (Materialalpha statt GeometryInstance3D.transparency: wirkt auch im Compatibility-Renderer)
func _apply_color(c: Color) -> void:
	if _last_color != null and c.is_equal_approx(_last_color):
		return
	_last_color = c
	for m in _materials:
		var albedo: Color = m["albedo"]
		var emission: Color = m["emission"]
		m["mat"].albedo_color = Color(albedo.r * c.r, albedo.g * c.g, albedo.b * c.b, albedo.a * c.a)
		m["mat"].emission = Color(emission.r * c.r, emission.g * c.g, emission.b * c.b, emission.a)
	for g in _alpha_geometries:
		g.transparency = clampf(1.0 - c.a, 0.0, 1.0)

# Aktive Elementzeit seit dem GFX-Start: die Aktion läuft nur, solange das Element tickt,
# und startet erst mit einem neuen GFX-Durchlauf (Play) neu, nicht bei RepeatCount
func _action_ms(active_time: float) -> float:
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
	if f_repeat >= 0.0 and loop >= f_repeat:
		return f_repeat * active_duration
	return loop * active_duration + minf(fmod(t_since_start, full_duration), active_duration)

# PlayActionByNameDC(name, Loops): nach Loops Durchläufen bleibt das letzte Bild stehen
func _apply_action(action_ms: float) -> void:
	var anim = _player.get_animation(_anim_name)
	if anim == null:
		return
	var length = anim.length
	var pos = action_ms / 1000.0
	if length <= 0.0:
		pos = 0.0
	elif Action_Loops >= 0 and pos >= length * maxi(1, Action_Loops):
		pos = maxf(0.0, length - 0.0001)
	else:
		pos = fmod(pos, length)
	if _player.assigned_animation != _anim_name:
		_player.play(_anim_name)
		_player.pause()
	_player.seek(pos, true)

# Bewegungsrichtung wie m_matTran.GetRow(3) - m_vOldPos; im Stillstand bleibt die letzte Richtung
func _movement_dir(span: float, pos: Vector3) -> Vector3:
	if span < _last_span:
		_last_move_dir = Vector3.ZERO # neuer Durchlauf
	_last_span = span
	var d: Vector3
	if span >= FACING_SAMPLE_MS:
		d = pos - (evaluate(span - FACING_SAMPLE_MS)["pos"] as Vector3)
	else:
		d = (evaluate(span + FACING_SAMPLE_MS)["pos"] as Vector3) - pos
	if d.length() > 0.000001:
		_last_move_dir = d.normalized()
	return _last_move_dir

# a3d_TransformMatrix(vDir, vUp): Z = Richtung, X = Up x Z, Y = Z x X
func _dir_up_basis(dir: Vector3, up: Vector3) -> Basis:
	var z = dir.normalized()
	var x = up.cross(z)
	if x.length() < 0.000001:
		x = (Vector3.RIGHT if absf(z.y) > 0.999 else Vector3.UP).cross(z)
	x = x.normalized()
	return Basis(x, z.cross(x), z)
