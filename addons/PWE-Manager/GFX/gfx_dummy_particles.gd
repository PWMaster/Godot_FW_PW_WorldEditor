@tool
extends Node3D

# ====================================================
# Dummies an den Partikeln (A3DParticleSystemEx mit DummyEle, angelegt von create_id_120.gd):
# statt Quads zeigt Angelica an jedem Partikel eine Kopie des Dummy-Elements
# (Render_Dummy / TickDummy). Hier je Partikel-Slot eine Kopie mit eigenem GFX-Header. Ihre Zeit
# ist das Alter des Partikels (Stop() / Play() bei der Emission, dann DummyTick mit der
# GFX-Zeit), so folgen die Kopien auch Pause und Zeitregler des GFX-Players.
# Die Partikel rechnet gfx_particle_eval.gd auf der CPU wie der Partikel-Shader, mit der Zeit
# und den Werten aus dessen Material.
#   Container (200): die Unter-GFX selbst an der Partikel-Lage (SetParentTM, Scale wird
#     ignoriert), Scale = Partikel-Scale (DummyScale, mal GFX-Scale bei DummyUseGScale),
#     Alpha = Partikel-Alpha * KeyPoint-Alpha * GFX-Alpha, PlaySpeed des Containers.
#   Modell / Ring / ECModel (160 / 140 / 230): das Element unter der ganzen Partikel-Matrix
#     (samt Scale), mit der Dummy-Farbe als Alpha.
#   Decal (100 / 101 / 110): ohne DummyTick - Angelica zeichnet je lebendem Partikel eine
#     Kopie am ersten KeyPoint des Elements, angehalten.
# Facing: ausgerichtet nach der Flugrichtung (_build_matrix), Scale mit KeyPoint-Scale.
# NoChangeDir der Unter-GFX: ihre Drehung bleibt die der Welt (A3DGFXEx::SetParentTM).
# Zwei Wege:
#   Instanzen: besteht die Kopie nur aus Shader-Elementen (Zeit über "active_time" im
#     Vertex-Shader, z.B. Partikel, Decals, Ringe), zeichnet je Element ein MultiMesh alle Kopien;
#     Zeit und Alpha je Kopie kommen über INSTANCE_CUSTOM in eine Variante des Element-Shaders.
#     Je Frame nur ein Puffer je Element - so bleiben auch hunderte Dummies billig.
#   Nodes: sonst (Modelle, Lichter, Sounds, verschachtelte Container, FaceToViewer / FadeByDist
#     der Unter-GFX) je Partikel-Slot eine Kopie mit eigenem GFX-Header.
# Außerhalb des Kamera-Sichtfelds (Kugel um die bisherige Ausdehnung der Partikel) rechnet der
# Treiber nichts und blendet die Kopien aus - die Partikel hängen nur von der Zeit ab, danach
# geht es ohne Versatz weiter.
# Die Kopien hängen intern darunter und werden nicht gespeichert.
# ====================================================

const Eval = preload("gfx_particle_eval.gd")
const KP = preload("gfx_keypoint_eval.gd")
const HEADER_SCRIPT = preload("gfx_data_node.gd")
const CONTAINER_NODE_NAME = "GfxContainer_GFX"
const SUB_GFX_NODE_NAME = "Sub_GFX"
const STATIC_DUMMY_IDS = ["100", "101", "110"]
const ACTIVE_TIME_LINE = "\tfloat active_time = Time_Manual ? Time : (TIME * 1000.0);\n"
const NO_LOOP_MS = 1000000000.0 # wie gfx_container_200.gd: die Kopie läuft einmal durch
const VARIANT_META = &"dummy_instance_variant"

## Name des Dummy-Elements (DummyEle) in derselben GFX
@export var Dummy_Element: String = "":
	set(value):
		Dummy_Element = value
		_dirty = true
## Aufbau des Partikel-Shaders für die CPU (create_id_120.gd)
@export_storage var info: Dictionary = {}

var _eval = null
var _mat: ShaderMaterial = null
var _slots: Array = [] # Nodes: je Slot {node: Lage, gfx: Header der Kopie}
var _multis: Array = [] # Instanzen: je Element-Geometrie {mmi: MultiMeshInstance3D, local: Lage in der Kopie}
var _buf = PackedFloat32Array()
var _pool = 0
var _kind = "" # "container", "element", "static"
var _sub_scale = 1.0
var _use_gscale = true
var _no_dir = false # NoChangeDir der Unter-GFX
var _sub_alpha = 1.0 # DefaultAlpha der Unter-GFX (Instanzen; Nodes rechnen das selbst)
var _speed = 1.0 # PlaySpeed der Kopie (Container * Unter-GFX)
var force_nodes = false # immer Node-Kopien (zum Vergleich)
var _extent = -1.0 # größter Abstand eines Partikels vom Träger (lokal), < 0 = noch unbekannt
var _culled = false
var _dirty = true


func _process(_delta: float) -> void:
	if _dirty:
		_build()
	if _eval != null:
		tick()

func _exit_tree() -> void:
	_dirty = true

func _clear() -> void:
	for s in _slots:
		if is_instance_valid(s["node"]):
			remove_child(s["node"])
			s["node"].queue_free()
	_slots.clear()
	for m in _multis:
		if is_instance_valid(m["mmi"]):
			remove_child(m["mmi"])
			m["mmi"].queue_free()
	_multis.clear()
	_eval = null

func _build() -> void:
	_dirty = false
	_clear()
	var particles = get_parent()
	_mat = particles.material_override as ShaderMaterial if particles is GeometryInstance3D else null
	if _mat == null or _mat.shader == null:
		return
	var element = particles.get_parent()
	var header = element.get_parent() if element != null else null
	var dummy = _find_dummy(header, element)
	if dummy == null:
		return
	var template: Node = null
	var container = dummy.get_node_or_null(CONTAINER_NODE_NAME)
	if container != null:
		template = container.get_node_or_null(SUB_GFX_NODE_NAME)
		_kind = "container"
		_sub_scale = float(container.get("Sub_Gfx_Scale")) if container.get("Sub_Gfx_Scale") != null else 1.0
		_use_gscale = bool(container.get("Dummy_Use_GScale")) if container.get("Dummy_Use_GScale") != null else true
	else:
		template = dummy
		_kind = "static" if str(dummy.get("parsed_data").get("_system_id", "")) in STATIC_DUMMY_IDS else "element"
	if template == null:
		return
	_eval = Eval.new(_mat, info)
	_pool = int(_eval._val("Pool_Size", 0))
	var speed = float(container.get("Play_Speed")) if container != null and container.get("Play_Speed") != null else 1.0
	var cfg: Dictionary = template.get("parsed_data") if _kind == "container" else {}
	_speed = speed * float(str(cfg.get("PlaySpeed", "1"))) if _kind == "container" else 1.0
	_no_dir = str(cfg.get("NoChangeDir", "0")).strip_edges() == "1"
	_sub_alpha = float(str(cfg.get("DefaultAlpha", "1")))
	var per_node = false
	for key in ["FaceToViewer", "FadeByDist", "ShakeCam"]:
		if str(cfg.get(key, "0")).strip_edges() not in ["0", ""]:
			per_node = true
	if not per_node and not force_nodes and _build_instances(template):
		return
	for i in _pool:
		var slot = Node3D.new()
		slot.name = "Dummy_%d" % i
		slot.visible = false
		slot.process_mode = Node.PROCESS_MODE_DISABLED
		add_child(slot, false, Node.INTERNAL_MODE_BACK)
		var copy = template.duplicate()
		var gfx: Node3D
		if _kind == "container":
			# Die Unter-GFX wird selbst zum Header (nicht mehr passiv unter dem Container)
			gfx = copy
			gfx.transform = Transform3D.IDENTITY
			gfx.Play_Speed = speed
		else:
			copy.visible = true
			gfx = Node3D.new()
			gfx.set_script(HEADER_SCRIPT)
			gfx.parsed_data = {}
			gfx.add_child(copy)
		gfx.Time_Manual = true
		gfx.Time_Ms = 0.0
		slot.add_child(gfx)
		_slots.append({"node": slot, "gfx": gfx})

# Instanzen: je Geometrie der Kopie ein MultiMesh mit Pool_Size Instanzen. false = nicht möglich
func _build_instances(template: Node) -> bool:
	var geoms = []
	if not _collect_instanceable(template, template, geoms) or geoms.is_empty():
		return false
	for g in geoms:
		var node: MeshInstance3D = g[0]
		var mat: ShaderMaterial = node.material_override.duplicate()
		mat.shader = _variant(mat.shader)
		if _kind == "container":
			mat.set_shader_parameter("GlobalLoopTime", NO_LOOP_MS)
		var mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = node.mesh
		mm.instance_count = _pool
		var mmi = MultiMeshInstance3D.new()
		mmi.name = "Dummies_" + str(node.get_parent().name)
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.extra_cull_margin = maxf(node.extra_cull_margin, 1000.0)
		add_child(mmi, false, Node.INTERNAL_MODE_BACK)
		_multis.append({"mmi": mmi, "local": g[1]})
	_buf.resize(_pool * 16)
	return true

# Geometrien der Kopie samt Lage darin; false bei CPU-Treibern (Zeit_Ms), verschachtelten Dummies
# oder Shadern ohne die active_time-Zeile
func _collect_instanceable(node: Node, root: Node, out: Array) -> bool:
	if node != root and "Time_Manual" in node and "Time_Ms" in node:
		return false
	if node.get_script() == get_script():
		return false
	if node is GeometryInstance3D:
		var mat = node.material_override
		if not (node is MeshInstance3D) or not (mat is ShaderMaterial) or mat.shader == null or not ACTIVE_TIME_LINE in mat.shader.code:
			return false
		if node.mesh != null and node.visible:
			var t: Transform3D = node.transform
			var p = node.get_parent()
			while p != root and p is Node3D:
				t = p.transform * t
				p = p.get_parent()
			out.append([node, t])
	for c in node.get_children():
		if not _collect_instanceable(c, root, out):
			return false
	return true

# Shader-Variante: Zeit und Alpha je Instanz (INSTANCE_CUSTOM.x / .y), am Original gemerkt
static func _variant(shader: Shader) -> Shader:
	if shader.has_meta(VARIANT_META):
		return shader.get_meta(VARIANT_META)
	var code = shader.code.replace(ACTIVE_TIME_LINE, "\tfloat active_time = INSTANCE_CUSTOM.x;\n\tv_dummy_alpha = INSTANCE_CUSTOM.y;\n")
	code = code.replace("ALPHA *= GFX_Alpha;", "ALPHA *= GFX_Alpha * v_dummy_alpha;")
	var at = code.find("void vertex()")
	code = code.substr(0, at) + "varying float v_dummy_alpha;\n\n" + code.substr(at)
	var variant = Shader.new()
	variant.code = code
	shader.set_meta(VARIANT_META, variant)
	return variant

# Element derselben GFX mit Name = Dummy_Element und IsDummy (A3DGFXElement::SetDummyEle)
func _find_dummy(header: Node, element: Node) -> Node:
	if header == null or Dummy_Element == "":
		return null
	for sibling in header.get_children():
		var data = sibling.get("parsed_data")
		if sibling != element and typeof(data) == TYPE_DICTIONARY and str(data.get("Name", "")).strip_edges() == Dummy_Element:
			return sibling
	return null

# Ein Frame: Partikel zur Header-Zeit, Kopien nachführen (TickDummy)
func tick() -> void:
	var active_time = KP.clock_ms(bool(_mat.get_shader_parameter("Time_Manual")), float(_mat.get_shader_parameter("Time") if _mat.get_shader_parameter("Time") != null else 0.0))
	if _off_screen():
		if not _culled:
			_culled = true
			for m in _multis:
				m["mmi"].visible = false
			for s in _slots:
				s["node"].visible = false
				s["node"].process_mode = Node.PROCESS_MODE_DISABLED
		return
	if _culled:
		_culled = false
		for m in _multis:
			m["mmi"].visible = true
	var parts = _eval.particles(active_time)
	for p in parts:
		if p != null:
			_extent = maxf(_extent, (p["pos"] as Vector3).length())
	if not _multis.is_empty():
		_tick_instances(parts)
		return
	var gfx_alpha = _gfx_alpha()
	var facing = bool(_eval._val("Facing", false))
	var parent_scale = get_parent().global_basis.get_scale().x
	for i in _slots.size():
		var s = _slots[i]
		var p = parts[i] if i < parts.size() else null
		var slot: Node3D = s["node"]
		if p == null:
			if slot.visible:
				# Ohne Partikel ruht die Kopie ganz
				slot.visible = false
				slot.process_mode = Node.PROCESS_MODE_DISABLED
			continue
		var gfx = s["gfx"]
		if not slot.visible:
			slot.visible = true
			slot.process_mode = Node.PROCESS_MODE_INHERIT
		if _kind == "static":
			continue # angehalten am ersten KeyPoint
		gfx.Time_Ms = p["age"] * 1000.0 * _speed
		var size: float = p["size"]
		var rot: Basis
		var scale = size
		if facing:
			rot = _build_matrix(p["move_dir"])
			scale = size * p["k_scale"]
		else:
			var q: Quaternion = p["rot"]
			rot = Basis(q.normalized() if q.length() > 0.000001 else Quaternion.IDENTITY)
			if p["bind"]:
				scale = size * p["k_scale"]
		gfx.Alpha = clampf((p["col"] as Vector4).w * p["k_alpha"] * gfx_alpha, 0.0, 1.0)
		if _kind == "container":
			# SetParentTM ohne Scale, SetScale(DummyScale [* GFX-Scale])
			slot.transform = Transform3D(rot, p["pos"])
			var s_gfx = size * _sub_scale
			if not _use_gscale and absf(parent_scale) > 0.000001:
				s_gfx /= parent_scale
			gfx.scale = Vector3.ONE * s_gfx
		else:
			slot.transform = Transform3D(rot.scaled(Vector3.ONE * scale), p["pos"])

# Kugel um die Partikel (bisherige Ausdehnung + Rand für die Kopien) außerhalb aller Ebenen des
# Kamera-Sichtfelds? Ohne Kamera oder vor dem ersten Rechnen: nein
func _off_screen() -> bool:
	if _extent < 0.0 or not is_inside_tree():
		return false
	var vp: Viewport = get_viewport()
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		vp = Engine.get_singleton(&"EditorInterface").get_editor_viewport_3d(0)
	var cam = vp.get_camera_3d() if vp != null else null
	if cam == null:
		return false
	var s = global_basis.get_scale()
	var radius = (_extent + 10.0) * maxf(s.x, maxf(s.y, s.z))
	var center = global_position
	for plane in cam.get_frustum():
		if plane.distance_to(center) > radius:
			return true
	return false

# Instanzen: je Slot Lage (wie die Node-Kopien), Zeit = Partikel-Alter, Alpha; tote Slots
# bekommen eine leere Matrix (kein Pixel)
func _tick_instances(parts: Array) -> void:
	var gfx_alpha = _gfx_alpha()
	var facing = bool(_eval._val("Facing", false))
	var parent_scale = get_parent().global_basis.get_scale().x
	var no_dir_rot = global_basis.orthonormalized().inverse() if _no_dir else Basis.IDENTITY
	var xforms = []
	xforms.resize(_pool)
	var custom = []
	custom.resize(_pool)
	for i in _pool:
		var p = parts[i] if i < parts.size() else null
		if p == null:
			continue
		var size: float = p["size"]
		var alpha = clampf((p["col"] as Vector4).w * p["k_alpha"] * gfx_alpha, 0.0, 1.0)
		var t: Transform3D
		if _kind == "static":
			t = Transform3D.IDENTITY
			custom[i] = Vector2(0.0, 1.0)
		else:
			var rot: Basis
			var scale = size
			if facing:
				rot = _build_matrix(p["move_dir"])
				scale = size * p["k_scale"]
			else:
				var q: Quaternion = p["rot"]
				rot = Basis(q.normalized() if q.length() > 0.000001 else Quaternion.IDENTITY)
				if p["bind"]:
					scale = size * p["k_scale"]
			if _kind == "container":
				var s_gfx = size * _sub_scale
				if not _use_gscale and absf(parent_scale) > 0.000001:
					s_gfx /= parent_scale
				t = Transform3D((no_dir_rot if _no_dir else rot).scaled(Vector3.ONE * s_gfx), p["pos"])
				custom[i] = Vector2(p["age"] * 1000.0 * _speed, alpha * _sub_alpha)
			else:
				t = Transform3D(rot.scaled(Vector3.ONE * scale), p["pos"])
				custom[i] = Vector2(p["age"] * 1000.0, alpha)
		xforms[i] = t
	var base = PackedFloat32Array() # Puffer ohne eigene Lage der Geometrie, für alle mit local = 1
	for m in _multis:
		var local: Transform3D = m["local"]
		var plain = local == Transform3D.IDENTITY
		if plain and not base.is_empty():
			(m["mmi"] as MultiMeshInstance3D).multimesh.buffer = base
			continue
		for i in _pool:
			var o = i * 16
			if xforms[i] == null:
				for k in 16:
					_buf[o + k] = 0.0
				continue
			var t: Transform3D = xforms[i] if plain else xforms[i] * local
			var b = t.basis
			_buf[o] = b.x.x
			_buf[o + 1] = b.y.x
			_buf[o + 2] = b.z.x
			_buf[o + 3] = t.origin.x
			_buf[o + 4] = b.x.y
			_buf[o + 5] = b.y.y
			_buf[o + 6] = b.z.y
			_buf[o + 7] = t.origin.y
			_buf[o + 8] = b.x.z
			_buf[o + 9] = b.y.z
			_buf[o + 10] = b.z.z
			_buf[o + 11] = t.origin.z
			_buf[o + 12] = custom[i].x
			_buf[o + 13] = custom[i].y
			_buf[o + 14] = 0.0
			_buf[o + 15] = 0.0
		(m["mmi"] as MultiMeshInstance3D).multimesh.buffer = _buf
		if plain:
			base = _buf.duplicate()

# Alpha des GFX-Headers über dem Träger (m_pGfx->GetActualAlpha())
func _gfx_alpha() -> float:
	var element = get_parent().get_parent()
	var header = element.get_parent() if element != null else null
	if header != null and header.has_method("actual_alpha"):
		return float(header.actual_alpha(header._camera()))
	return 1.0

# _build_matrix(Richtung): +Z entlang dir (wie FaceToViewer in gfx_data_node.gd)
static func _build_matrix(dir: Vector3) -> Basis:
	if dir.length() < 0.000001:
		return Basis.IDENTITY
	var z = dir.normalized()
	var x: Vector3
	var y: Vector3
	if absf(z.y) > 0.999:
		y = z.cross(Vector3.RIGHT).normalized()
		x = y.cross(z)
	else:
		x = Vector3.UP.cross(z).normalized()
		y = z.cross(x)
	return Basis(x, y, z)
