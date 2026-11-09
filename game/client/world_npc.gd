extends Node3D

# ====================================================
# NPC oder Monster in der Welt des Clients: Modell (importierte oder zur Laufzeit gebaute Szene,
# world_screen.gd; kommt es später, set_model), darüber Titel und Name in der Namensfarbe;
# Animation 站立 (Stehen; Tiere und Gegenstände ohne 站立: 动作 bzw. 休闲), ab und zu 休闲 / 休闲1
# (CECNPC: ACT_IDLE1 + 0 / 1), beim Gehen 行走 bzw. 奔跑 (über 2,5 m/s). Position und Richtung vom
# Server (npc_enter);
# npc_move: läuft mit dem Tempo des Servers geradeaus zum Ziel, die Höhe folgt dem Boden
# (Strahl nach unten auf Ebene 1: Terrain und Gebäude) und endet genau am Ziel.
# Namen ab NAME_RANGE ausgeblendet. Fehlt das Modell, steht ein Platzhalter (Kapsel) da.
# Klick-Auswahl: Kapsel in Modellhöhe auf Ebene PICK_LAYER (Meta "pick_id" = ID, local_player.gd).
# Quest-Symbol über dem Namen (set_quest_icon, Bild aus quest_data.gd: annehmbar / abschließbar ...).
# Kampf (configs\actions_npc.txt): play_attack 普通攻击1 / 2 (sonst 攻击1 / 攻击), play_hurt 受伤1,
# die 死亡 - danach liegt die Leiche CORPSE_TIME s und verschwindet; face dreht zum Gegner.
# ====================================================

const ACT_STANDS = ["站立", "动作", "休闲"] # erste vorhandene = Stehen
const ACT_WALK = "行走"
const ACT_RUN = "奔跑"
const ACT_IDLES = ["休闲", "休闲1"]
const ACT_ATTACKS = ["普通攻击1", "普通攻击2", "攻击1", "攻击"]
const ACT_HURTS = ["受伤1", "受伤"]
const ACT_DIE = "死亡"
const CORPSE_TIME = 2.5
const RUN_FROM = 2.5 # m/s
const IDLE_MIN = 8.0
const IDLE_MAX = 20.0
const TURN_RATE = 10.0
const GROUND_UP = 0.6 # Strahl ab so weit über der Höhe (nicht höher: Vordächer, Tische über NPCs) ...
const GROUND_DOWN = 4.0 # ... bis so weit darunter
const LABEL_GAP = 0.35
const NAME_RANGE = 50.0 # m: weiter weg kein Name (sonst winzige Schilder durch Wände)
const NAME_FADE = 5.0
const FALLBACK_HEIGHT = 1.8
const PICK_LAYER = 4 # Ebene 3: Klick-Auswahl (local_player.gd)
const PICK_RADIUS = 0.5

var id = 0
var tid = 0
var level = 0
var model: Node3D
var anim: AnimationPlayer
var label: Label3D
var pick: Area3D
var quest_icon: Sprite3D
var dead = false
var height = FALLBACK_HEIGHT
var target = null # Vector3: läuft dorthin
var speed = 0.0
var _dir = 0.0
var _idle_t = 0.0
var _idle_end = 0.0


# entry: [id, Vorlage, x, y, z, Richtung, Stufe, Gang]; scene: PackedScene oder null;
# pending: das Modell wird noch gebaut (bis dahin nur der Name), sonst ohne Szene ein Platzhalter
func setup(entry: Array, info: Dictionary, scene: PackedScene, display_name: String, color: Color, pending: bool = false) -> void:
	id = int(entry[0])
	tid = int(entry[1])
	level = int(entry[6])
	name = "NPC_%d" % id
	if scene != null:
		_attach(scene.instantiate(), float(info["scale"]))
	elif not pending:
		_attach(_placeholder(), 1.0)
	label = Label3D.new()
	label.text = display_name if info["title"] == "" else "<%s>\n%s" % [info["title"], display_name]
	label.visible = label.text.strip_edges() != ""
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = height + LABEL_GAP
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	label.pixel_size = 0.004
	label.font_size = 36
	label.outline_size = 10
	label.modulate = color
	label.no_depth_test = true
	label.visibility_range_end = NAME_RANGE
	label.visibility_range_end_margin = NAME_FADE
	label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(label)
	_make_pick()
	position = Vector3(entry[2], entry[3], entry[4])
	set_dir(float(entry[5]))
	_idle_t = randf_range(IDLE_MIN, IDLE_MAX)
	var mv: Array = entry[7]
	if mv.size() == 4:
		move_to(position, Vector3(mv[0], mv[1], mv[2]), float(mv[3]))
	else:
		_play(_stand())

# Modell nachreichen (zur Laufzeit gebaut); null = Platzhalter
func set_model(scene: PackedScene, scale_factor: float) -> void:
	if model != null:
		model.queue_free()
		model = null
		anim = null
	if scene != null:
		_attach(scene.instantiate(), scale_factor)
	else:
		_attach(_placeholder(), 1.0)
	model.rotation.y = _dir
	label.position.y = height + LABEL_GAP
	_make_pick()
	_place_icon()
	if target != null:
		_play(ACT_RUN if speed > RUN_FROM and _has(ACT_RUN) else ACT_WALK)
	else:
		_play(_stand())

func _attach(node: Node3D, scale_factor: float) -> void:
	model = node
	model.scale = Vector3.ONE * scale_factor
	add_child(model)
	anim = model.get_node_or_null("AnimationPlayer")
	height = FALLBACK_HEIGHT
	var aabb = AABB()
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		aabb = aabb.merge(mi.get_aabb())
	if aabb.size.y > 0.1:
		height = aabb.end.y * scale_factor

# Quest-Symbol (null = keins)
func set_quest_icon(tex: Texture2D) -> void:
	if tex == null:
		if quest_icon != null:
			quest_icon.visible = false
		return
	if quest_icon == null:
		quest_icon = Sprite3D.new()
		quest_icon.name = "QuestSymbol"
		quest_icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		quest_icon.pixel_size = 0.012
		quest_icon.no_depth_test = true
		quest_icon.render_priority = 1
		quest_icon.visibility_range_end = NAME_RANGE
		quest_icon.visibility_range_end_margin = NAME_FADE
		quest_icon.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(quest_icon)
	quest_icon.texture = tex
	quest_icon.visible = true
	_place_icon()

func _place_icon() -> void:
	if quest_icon != null and label != null:
		var lines = label.text.count("\n") + 1
		quest_icon.position.y = label.position.y + lines * label.font_size * label.pixel_size * 1.1 + 0.25

# Auswahl-Kapsel (neu, wenn sich die Höhe ändert)
func _make_pick() -> void:
	if pick != null:
		pick.queue_free()
	pick = Area3D.new()
	pick.name = "Auswahl"
	pick.collision_layer = PICK_LAYER
	pick.collision_mask = 0
	pick.monitoring = false
	pick.set_meta("pick_id", id)
	var shape = CapsuleShape3D.new()
	shape.radius = PICK_RADIUS
	shape.height = maxf(height, PICK_RADIUS * 2.0)
	var cs = CollisionShape3D.new()
	cs.shape = shape
	cs.position.y = shape.height / 2.0
	pick.add_child(cs)
	add_child(pick)

func set_dir(dir: float) -> void:
	_dir = dir
	if model != null:
		model.rotation.y = dir

# npc_move: von pos nach to mit speed
func move_to(pos: Vector3, to: Vector3, p_speed: float) -> void:
	position = pos
	target = to
	speed = maxf(0.05, p_speed)
	var flat = Vector2(to.x - pos.x, to.z - pos.z)
	if flat.length() > 0.01:
		_dir = atan2(flat.x, flat.y)
	_play(ACT_RUN if speed > RUN_FROM and _has(ACT_RUN) else ACT_WALK)

func is_moving() -> bool:
	return target != null

func face(p: Vector3) -> void:
	var flat = Vector2(p.x - position.x, p.z - position.z)
	if flat.length() > 0.05:
		_dir = atan2(flat.x, flat.y)

# -> gespielte Aktion (für die Angriffs-Effekte), "" ohne
func play_attack() -> String:
	var acts = ACT_ATTACKS.filter(func(a): return _has(a)).slice(0, 2)
	if acts.is_empty() or dead:
		return ""
	var a = acts[randi() % acts.size()]
	_play_once(a)
	return a

func play_hurt() -> void:
	if dead or target != null or _idle_end > 0.0:
		return
	for a in ACT_HURTS:
		if _has(a):
			_play_once(a)
			return

# Tod: Sterbe-Aktion, keine Auswahl mehr, nach CORPSE_TIME s weg
func die() -> void:
	dead = true
	target = null
	if label != null:
		label.visible = false
	if quest_icon != null:
		quest_icon.visible = false
	if pick != null:
		pick.queue_free()
		pick = null
	if _has(ACT_DIE):
		anim.get_animation(ACT_DIE).loop_mode = Animation.LOOP_NONE
		anim.play(ACT_DIE, 0.1)
	get_tree().create_timer(CORPSE_TIME).timeout.connect(queue_free)

func _play_once(act: String) -> void:
	anim.get_animation(act).loop_mode = Animation.LOOP_NONE
	anim.play(act, 0.1)
	_idle_end = anim.get_animation(act).length

func _process(delta: float) -> void:
	if model != null:
		model.rotation.y = lerp_angle(model.rotation.y, _dir, clampf(TURN_RATE * delta, 0.0, 1.0))
	if dead:
		return
	if target != null:
		var to: Vector3 = target
		var flat = Vector2(to.x - position.x, to.z - position.z)
		var step = speed * delta
		if flat.length() <= step:
			position = to
			target = null
			_play(_stand())
			_idle_t = randf_range(IDLE_MIN, IDLE_MAX)
		else:
			var f = flat.normalized() * step
			var rest = flat.length()
			var y = lerpf(position.y, to.y, step / rest)
			position = Vector3(position.x + f.x, _ground(position.x + f.x, y, position.z + f.y), position.z + f.y)
		return
	# stehend: ab und zu eine Leerlauf-Bewegung
	if _idle_end > 0.0:
		_idle_end -= delta
		if _idle_end <= 0.0:
			_play(_stand())
		return
	_idle_t -= delta
	if _idle_t <= 0.0:
		_idle_t = randf_range(IDLE_MIN, IDLE_MAX)
		var act = ACT_IDLES[randi() % ACT_IDLES.size()]
		if _has(act):
			anim.play(act, 0.2)
			_idle_end = anim.get_animation(act).length

# Bodenhöhe unter (x, z) nahe y (Ebene 1), sonst y
func _ground(x: float, y: float, z: float) -> float:
	if not is_inside_tree():
		return y
	var q = PhysicsRayQueryParameters3D.create(Vector3(x, y + GROUND_UP, z), Vector3(x, y - GROUND_DOWN, z), 1)
	var hit = get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"].y if not hit.is_empty() else y

func _stand() -> String:
	for act in ACT_STANDS:
		if _has(act):
			return act
	return ACT_STANDS[0]

func _has(act: String) -> bool:
	return anim != null and anim.has_animation(act)

func _play(act: String) -> void:
	_idle_end = 0.0
	if _has(act) and anim.current_animation != act:
		anim.play(act, 0.2)

func _placeholder() -> Node3D:
	var mi = MeshInstance3D.new()
	var capsule = CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = FALLBACK_HEIGHT
	mi.mesh = capsule
	mi.position.y = FALLBACK_HEIGHT / 2.0
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.75, 0.6)
	mi.material_override = mat
	var root = Node3D.new()
	root.name = "Platzhalter"
	root.add_child(mi)
	return root
