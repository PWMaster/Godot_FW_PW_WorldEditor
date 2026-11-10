extends Node3D

# ====================================================
# Angriffs-Effekte in der Welt (wie CECModel::PlayAttackAction -> SGCAttackPointMark::Start ->
# A3DSkillGfxComposer::Play -> A3DSkillGfxEvent):
# Ein Normalangriff spielt die Aktion des Angreifers; zu den Zeitpunkten ihrer Angriffspunkte
# (Ereignis 104 der kombinierten Aktion in der .ecm: Plugin ecm_importer.gd attack_points, bei
# Spielern als Meta attack_points am Modell) startet die .att (gfx\SkillAttack\, Plugin
# GFX/angelica_att.gd):
#   Flug-GFX (z.B. der Energieball des Magiers) vom Haken des Angreifers (HH_spine) zur Mitte des
#   Ziels, gerade oder als Parabel mit FlySpeed m/s (Schwerkraft 9,8 m/s², CGfxLinearMove /
#   CGfxParabolicMove; die Parabel zielt auf den Ort beim Abschuss), höchstens FlyTime ms;
#   beim Einschlag - ohne Flug-GFX bzw. mit "am Ziel" (OnTarget, z.B. Schwert, Dolch) sofort - das
#   Treffer-GFX am Ziel (Mitte oder Füße, Scale = Zielhöhe / TarScl * Scale, begrenzt; Richtung vom
#   Angreifer zum Ziel). Erst dann kommt die Wirkung (A3DSkillGfxEvent::FlushTargetsInfo): impact,
#   d.h. Schadenszahl, Treffer-Aktion, Leben - nur mit dem ersten Angriffspunkt einer Aktion (der
#   Assassine schlägt zweimal, die Zahl kommt mit dem ersten; SGCAttackPointMark leert danach
#   die Ziele).
# Ohne Angriffspunkt (Aktion ohne Ereignis, Modell unbekannt) kommt die Wirkung nach FALLBACK s.
# Fertigkeiten: der Treffer kommt erst nach dem Zaubern (Meldung hit mit elapsed ms seit Beginn der Aktion),
# die Angriffspunkte zählen ab dem Beginn der Aktion; play_events zeigt die GFX- und Klang-Ereignisse
# der Aktion (z.B. Feuer in der Hand beim Zaubern, Zauber-Klang).
# attach: Dauer-GFX eines Statuseffekts am Haken eines Modells bzw. an der Figur (world_screen.gd gibt es frei).
# pending(Ziel) zählt noch nicht eingeschlagene Treffer: ein Monster stirbt erst danach sichtbar
# (after_impacts).
# GFX baut ein eigener Importer im Laufzeit-Modus (nichts wird geschrieben), je Datei einmal
# (prewarm() vorab, z.B. für die eigene Figur im Ladebildschirm); ein Treffer-GFX lebt seine Länge
# (player_length_ms), höchstens MAX_LIFE s.
# ====================================================

const IMPORTER = "res://addons/PWE-Manager/ECM/ecm_importer.gd"
const ATT = "res://addons/PWE-Manager/GFX/angelica_att.gd"
const FALLBACK = 0.4 # s
const GRAVITY = 9.8
const MAX_LIFE = 3.0 # s
const DEFAULT_HEIGHT = 1.8
const MOVE_PARABOLIC = 1
const ON_TARGET = [7, 13] # Treffer am Ziel, kein Flug
const MAX_EVENT_LIFE = 10.0 # s: GFX eines Aktions-Ereignisses höchstens

var importer = null # ecm_importer.gd (runtime)
var _att_script: Script = null
var _att = {} # .att -> Dictionary
var _gfx = {} # GfxPath -> PackedScene oder null
var _points = {} # .ecm -> attack_points
var _flying: Array = [] # {node, att, attacker, target, key, impact, from, t, mode, speed, max, total, vel, vy}
var _pending = {} # Instanz-ID des Ziels -> Anzahl ausstehender Wirkungen
var _after = {} # Instanz-ID des Ziels -> [Callable] nach dem letzten Einschlag
var built = 0 # gebaute GFX (Test)


func setup(data_root: String) -> String:
	if not ResourceLoader.exists(IMPORTER) or not ResourceLoader.exists(ATT):
		return "Не найден плагин PWE-Manager: эффекты атак недоступны"
	importer = load(IMPORTER).new(data_root)
	importer.runtime = true
	_att_script = load(ATT)
	return ""

# Angriffspunkte einer Aktion eines Modells -> [[ms, .att], ...]
func points_of(model: Node, action: String) -> Array:
	if model == null or action == "":
		return []
	if model.has_meta("attack_points"):
		return model.get_meta("attack_points").get(action, [])
	var ecm = str(model.get_meta("ecm_path", ""))
	if ecm == "" or importer == null:
		return []
	if not _points.has(ecm):
		_points[ecm] = importer.attack_points(importer.read_ecm(ecm))
	return _points[ecm].get(action, [])

# GFX der Angriffe eines Modells vorab bauen
func prewarm(model: Node, actions: Array) -> void:
	for a in actions:
		for p in points_of(model, a):
			var att = _att_of(p[1])
			for g in [att.get("fly", {}).get("gfx", ""), att.get("hit", {}).get("gfx", "")]:
				_scene(g)

# Angriff: Aktion action des Modells von attacker auf target; impact kommt mit dem ersten Einschlag.
# elapsed ms: die Aktion läuft schon so lange (Fertigkeit: Treffer kommt nach dem Zaubern)
func play(attacker: Node3D, model: Node, action: String, target: Node3D, impact: Callable, elapsed: int = 0) -> void:
	var pts = points_of(model, action)
	var key = target.get_instance_id()
	_pending[key] = int(_pending.get(key, 0)) + 1
	if pts.is_empty():
		get_tree().create_timer(maxf(0.0, FALLBACK - elapsed / 1000.0)).timeout.connect(_impact.bind(key, impact))
		return
	for i in pts.size():
		var cb = impact if i == 0 else Callable()
		get_tree().create_timer(maxf(0.0, (int(pts[i][0]) - elapsed) / 1000.0)).timeout.connect(_fire.bind(attacker, model, str(pts[i][1]), target, key, cb))

# GFX- und Klang-Ereignisse einer Aktion (Ereignis 100 / 101 der .ecm, Meta action_events der Figur), z.B.
# der Feuerball in der Hand beim Zaubern: GFX am Haken (BindParent: folgt ihm), TimeSpan ms (-1 = bis die
# Aktion endet), GfxScale; Klang (sfx\) am Ort der Figur, hörbar bis MaxDist m
func play_events(fig: Node3D, model: Node, action: String, length: float) -> void:
	if model == null or importer == null or not model.has_meta("action_events"):
		return
	for e in model.get_meta("action_events").get(action, []):
		var t = int(e.get("start", 0)) / 1000.0
		if t <= 0.0:
			_event(e, fig, model, length)
		else:
			get_tree().create_timer(t).timeout.connect(_event.bind(e, fig, model, maxf(0.1, length - t)))

func _event(e: Dictionary, fig, model, left: float) -> void:
	if not is_instance_valid(fig) or not is_instance_valid(model) or not fig.is_inside_tree():
		return
	var file = str(e["files"][0])
	if int(e["type"]) == 101:
		var stream = importer.source_sound(file)
		if stream == null:
			return
		var sp = AudioStreamPlayer3D.new()
		sp.stream = stream
		sp.max_distance = maxf(1.0, float(e.get("MaxDist", "25")))
		sp.unit_size = maxf(1.0, float(e.get("MinDist", "5")))
		sp.volume_db = linear_to_db(clampf(float(e.get("VolMax", "100")) / 100.0, 0.01, 1.0))
		fig.add_child(sp)
		sp.finished.connect(sp.queue_free)
		sp.play()
		return
	var scene = _scene(file)
	if scene == null:
		return
	var node: Node3D = scene.instantiate()
	node.scale = Vector3.ONE * maxf(0.01, float(e.get("GfxScale", "1")))
	var span = int(e.get("TimeSpan", "-1"))
	var life = minf(MAX_EVENT_LIFE, span / 1000.0 if span > 0 else left)
	var hook = str(e.get("hook", ""))
	var sk = model.get_node_or_null("Skeleton3D") as Skeleton3D
	var bone = _bone(sk, hook) if sk != null and hook != "" else -1
	if bone >= 0 and str(e.get("BindParent", "1")) == "1":
		var ba = BoneAttachment3D.new()
		ba.bone_name = sk.get_bone_name(bone)
		sk.add_child(ba)
		ba.add_child(node)
		node.position = _vec(str(e.get("HookOffset", "")))
		get_tree().create_timer(life).timeout.connect(ba.queue_free)
		return
	add_child(node)
	node.global_position = sk.global_transform * sk.get_bone_global_pose(bone).origin if bone >= 0 else fig.global_position
	if model is Node3D:
		node.global_basis = (model as Node3D).global_basis.orthonormalized() * Basis.from_scale(node.scale)
	get_tree().create_timer(life).timeout.connect(node.queue_free)

# Dauer-GFX eines Statuseffekts (CECModel::PlayGfx am Haken, ohne Haken CECPlayer::_PlayBindGfx an der Figur):
# bleibt, bis der Aufrufer den zurückgegebenen Node freigibt (das GFX wiederholt sich selbst). Fehlt dem Modell
# der Haken, sitzt es in halber Höhe der Figur
func attach(fig: Node3D, model: Node, gfx_path: String, hook: String) -> Node3D:
	var scene = _scene(gfx_path)
	if scene == null or not is_instance_valid(fig):
		return null
	var node: Node3D = scene.instantiate()
	var sk = model.get_node_or_null("Skeleton3D") as Skeleton3D if is_instance_valid(model) else null
	var bone = _bone(sk, hook) if sk != null and hook != "" else -1
	if bone >= 0:
		var ba = BoneAttachment3D.new()
		ba.bone_name = sk.get_bone_name(bone)
		sk.add_child(ba)
		ba.add_child(node)
		return ba
	var parent: Node3D = model if is_instance_valid(model) and model is Node3D else fig
	parent.add_child(node)
	if hook != "":
		node.global_position = fig.global_position + Vector3.UP * _height(fig) * 0.5
	return node

# Knochen eines Hakens (Groß- / Kleinschreibung egal), -1 = fehlt
static func _bone(sk: Skeleton3D, hook: String) -> int:
	var want = hook.to_lower()
	for i in sk.get_bone_count():
		if sk.get_bone_name(i).to_lower() == want:
			return i
	return -1

static func _vec(s: String) -> Vector3:
	var p = s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2])) if p.size() == 3 else Vector3.ZERO

func pending(target: Node) -> int:
	return int(_pending.get(target.get_instance_id(), 0)) if is_instance_valid(target) else 0

# cb nach dem letzten ausstehenden Einschlag auf target (sofort, wenn keiner aussteht)
func after_impacts(target: Node, cb: Callable) -> void:
	if pending(target) == 0:
		cb.call()
		return
	var key = target.get_instance_id()
	if not _after.has(key):
		_after[key] = []
	_after[key].append(cb)


# ====================================================
# ABLAUF
# ====================================================
# Figuren als Variant: sie können inzwischen freigegeben sein
func _fire(attacker, model, att_path: String, target, key: int, impact: Callable) -> void:
	if not is_instance_valid(target) or not is_instance_valid(attacker) or not target.is_inside_tree():
		if impact.is_valid():
			_impact(key, impact)
		return
	var att = _att_of(att_path)
	var fly: Dictionary = att.get("fly", {})
	var mode = int(att.get("move_mode", 7))
	var scene = _scene(fly.get("gfx", "")) if not mode in ON_TARGET else null
	if scene == null:
		_hit(att, attacker, target, key, impact)
		return
	var from = _pos_of(attacker, model if is_instance_valid(model) else null, fly.get("pos", {}))
	var to = _pos_of(target, target.get("model"), att.get("hit", {}).get("pos", {}))
	var node: Node3D = scene.instantiate()
	add_child(node)
	node.global_position = from
	node.scale = Vector3.ONE * float(fly.get("scale", 1.0))
	var f = {"node": node, "att": att, "attacker": attacker, "target": target, "key": key, "impact": impact, "from": from, "t": 0.0,
		"mode": mode, "speed": maxf(0.1, float(att.get("fly_speed", 20.0))), "max": maxf(0.1, int(att.get("fly_time", 0)) / 1000.0)}
	if mode == MOVE_PARABOLIC:
		var flat = Vector3(to.x - from.x, 0, to.z - from.z)
		var dist = flat.length()
		f["total"] = maxf(0.01, dist / f["speed"])
		f["vel"] = flat.normalized() * f["speed"] if dist > 0.001 else Vector3.ZERO
		f["vy"] = (to.y - from.y) / f["total"] + 0.5 * GRAVITY * f["total"]
	_orient(node, (to - from).normalized())
	_flying.append(f)

func _process(delta: float) -> void:
	for f in _flying.duplicate():
		var node: Node3D = f["node"]
		var target = f["target"]
		var alive = is_instance_valid(target) and target.is_inside_tree()
		f["t"] += delta
		var arrived = false
		var pos: Vector3 = node.global_position
		if f["mode"] == MOVE_PARABOLIC:
			var t = minf(f["t"], f["total"])
			var vy = f["vy"] - GRAVITY * t
			pos = f["from"] + f["vel"] * t + Vector3(0, 0.5 * (vy + f["vy"]) * t, 0)
			_orient(node, (f["vel"] + Vector3(0, vy, 0)).normalized())
			arrived = f["t"] >= f["total"]
		else: # gerade, folgt dem Ziel
			var to = _pos_of(target, target.get("model"), f["att"].get("hit", {}).get("pos", {})) if alive else pos
			var d = to - pos
			var step = f["speed"] * delta
			if step >= d.length():
				pos = to
				arrived = true
			else:
				pos += d.normalized() * step
				_orient(node, d.normalized())
		node.global_position = pos
		if arrived or f["t"] >= f["max"] or not alive:
			_flying.erase(f)
			node.queue_free()
			if alive:
				_hit(f["att"], f["attacker"], target, f["key"], f["impact"])
			elif f["impact"].is_valid():
				_impact(f["key"], f["impact"])

# Treffer-GFX am Ziel, dann die Wirkung
func _hit(att: Dictionary, attacker, target, key: int, impact: Callable) -> void:
	var hit: Dictionary = att.get("hit", {})
	var scene = _scene(hit.get("gfx", ""))
	if scene != null and is_instance_valid(target) and target.is_inside_tree():
		var node: Node3D = scene.instantiate()
		add_child(node)
		node.global_position = _pos_of(target, target.get("model"), hit.get("pos", {}))
		var dir = Vector3.FORWARD
		if is_instance_valid(attacker):
			var d = target.global_position - attacker.global_position
			d.y = 0
			if d.length() > 0.001:
				dir = d.normalized()
		_orient(node, dir)
		var s = float(hit.get("scale", 1.0))
		if hit.get("rel_scale", false):
			s = clampf(_height(target) / maxf(0.01, float(hit.get("target_scale", 1.8))) * s, float(hit.get("min_scale", 0.01)),
				float(hit.get("max_scale", 99999.0)))
		node.scale = Vector3.ONE * s
		var life = MAX_LIFE
		if node.has_method("player_length_ms"):
			life = clampf(node.player_length_ms() / 1000.0, 0.2, MAX_LIFE)
		get_tree().create_timer(life).timeout.connect(node.queue_free)
	if impact.is_valid():
		_impact(key, impact)

func _impact(key: int, impact: Callable) -> void:
	if impact.is_valid():
		impact.call()
	var n = int(_pending.get(key, 0)) - 1
	if n > 0:
		_pending[key] = n
		return
	_pending.erase(key)
	for cb in _after.get(key, []):
		if cb.is_valid():
			cb.call()
	_after.erase(key)


# ====================================================
# HILFEN
# ====================================================
func _att_of(path: String) -> Dictionary:
	if not _att.has(path):
		var src = importer.find_game_file("gfx/SkillAttack/" + path) if importer != null else ""
		_att[path] = _att_script.read(importer.files, src) if src != "" else {}
	return _att[path]

func _scene(gfx_path: String) -> PackedScene:
	if gfx_path == "" or importer == null:
		return null
	if not _gfx.has(gfx_path):
		_gfx[gfx_path] = importer.gfx_scene(gfx_path)
		built += 1
	return _gfx[gfx_path]

# Ort an einer Figur wie A3DSkillGfxMan GetPositionById: Haken des Modells, sonst Mitte bzw. Füße
func _pos_of(fig, model, pos: Dictionary) -> Vector3:
	if not is_instance_valid(fig):
		return Vector3.ZERO
	var hook = str(pos.get("hook", ""))
	var sk = model.get_node_or_null("Skeleton3D") if model is Node else null
	if hook != "" and sk is Skeleton3D:
		var want = hook.to_lower()
		for i in sk.get_bone_count():
			if sk.get_bone_name(i).to_lower() == want:
				return sk.global_transform * sk.get_bone_global_pose(i).origin + pos.get("offset", Vector3.ZERO)
	var p = fig.global_position
	if not pos.get("bottom", false):
		p.y += _height(fig) * 0.5
	return p + pos.get("offset", Vector3.ZERO)

static func _height(fig: Node) -> float:
	var h = fig.get("height") if is_instance_valid(fig) else null
	return float(h) if h != null and float(h) > 0.1 else DEFAULT_HEIGHT

# +Z der GFX in Flugrichtung (Angelica: Dir = +Z, Up = +Y)
static func _orient(node: Node3D, dir: Vector3) -> void:
	if dir.length() < 0.001:
		return
	var up = Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x = up.cross(dir).normalized()
	node.global_basis = Basis(x, dir.cross(x).normalized(), dir) * Basis.from_scale(node.scale)
