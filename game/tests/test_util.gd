extends RefCounted

# ====================================================
# Hilfen der Tests mit mehreren Sitzungen in einem Prozess (restart_test, load_test):
#   session(tag, port)        Sitzung mit eigener Multiplayer-API (Zweig /root/Sitzung<tag>/Game);
#                             ihre Meldungen sammelt sie als [Name, Daten] in get_meta("pushes")
#   freeze(s) / thaw(s)       Netz der Sitzung anhalten / weiterlaufen lassen (Verbindung hängt:
#                             der Server sieht nichts mehr von ihr, bis ENet aufgibt)
#   npcs(pushes)              NPC-Meldungen nachgespielt -> {ID: {tid, level, at}} (at = Ziel, wenn er läuft)
#   find_npc(pushes, tid)     Objekt-ID des ersten sichtbaren NPCs mit dieser Vorlage, 0 ohne
#   seen_players(pushes)      Spieler in Sicht nach player_enter / player_leave -> {ID: true}
#   last(pushes, name)        letzte Meldung dieses Namens ({} ohne)
#   walk(s, from, to, ...)    in Schritten bis stop m vor das Ziel laufen (Tempo, das der Server annimmt)
#   chase(s, id, from, cond, seconds)   einem NPC / Monster nachlaufen (wie der Client beim Angriff),
#                             bis cond wahr ist -> eigene Position
#   until(cond, seconds)      warten, bis cond wahr ist (false nach seconds)
# Der SceneTree pollt die Sitzungen nicht selbst (multiplayer_poll aus), sondern poll() je Bild -
# so lässt sich eine einzelne anhalten.
# ====================================================

const Proto = preload("../common/protocol.gd")
const Net = preload("../common/net.gd")
const Session = preload("../client/session.gd")

var tree: SceneTree
var host = "127.0.0.1"
var _sessions: Array = [] # [Session, SceneMultiplayer]
var _frozen = {} # Session -> true


func _init(p_tree: SceneTree) -> void:
	tree = p_tree
	tree.multiplayer_poll = false

# Je Bild aufrufen (SceneTree._process)
func poll() -> void:
	for e in _sessions:
		if is_instance_valid(e[0]) and not _frozen.has(e[0]):
			e[1].poll()

func session(tag: String, port: int) -> Session:
	var branch = Node.new()
	branch.name = "Sitzung" + tag
	tree.root.add_child(branch)
	var mp = SceneMultiplayer.new()
	tree.set_multiplayer(mp, branch.get_path())
	var game = Node.new()
	game.name = "Game"
	branch.add_child(game)
	var net = Net.new()
	net.name = "Net"
	game.add_child(net)
	var s = Session.new()
	s.name = "Session"
	s.host = host
	s.port = port
	game.add_child(s)
	var pushes = []
	s.set_meta("pushes", pushes)
	net.pushed.connect(func(what, data): pushes.append([what, data]))
	_sessions.append([s, mp])
	return s

func freeze(s: Session) -> void:
	_frozen[s] = true

func thaw(s: Session) -> void:
	_frozen.erase(s)

static func npcs(pushes: Array) -> Dictionary:
	var out = {}
	for e in pushes:
		match e[0]:
			"npc_enter":
				for n in e[1]["list"]:
					var mv: Array = n[7]
					out[n[0]] = {"tid": n[1], "level": n[6], "at": Vector3(mv[0], mv[1], mv[2]) if mv.size() == 4 else Vector3(n[2], n[3], n[4])}
			"npc_move":
				if out.has(e[1]["id"]):
					var to: Array = e[1]["to"]
					out[e[1]["id"]]["at"] = Vector3(to[0], to[1], to[2])
			"npc_leave":
				for id in e[1]["ids"]:
					out.erase(id)
	return out

static func find_npc(pushes: Array, tid: int) -> int:
	var nc = npcs(pushes)
	for id in nc:
		if nc[id]["tid"] == tid:
			return id
	return 0

static func seen_players(pushes: Array) -> Dictionary:
	var out = {}
	for e in pushes:
		if e[0] == "player_enter":
			out[e[1]["id"]] = true
		elif e[0] == "player_leave":
			out.erase(e[1]["id"])
	return out

static func last(pushes: Array, what: String) -> Dictionary:
	for i in range(pushes.size() - 1, -1, -1):
		if pushes[i][0] == what:
			return pushes[i][1]
	return {}

static func count(pushes: Array, what: String) -> int:
	var n = 0
	for e in pushes:
		if e[0] == what:
			n += 1
	return n

# Läuft mit speed m/s (Standard: Rennen) in Schritten je 0,1 s bis stop m vor das Ziel -> Ende
func walk(s: Session, from: Vector3, to: Vector3, stop: float = 2.0, speed: float = Proto.RUN_SPEED) -> Vector3:
	var d = to - from
	var flat = Vector2(d.x, d.z)
	if flat.length() <= stop:
		return from
	var goal = to - Vector3(flat.normalized().x, 0, flat.normalized().y) * stop
	var steps = maxi(1, ceili(from.distance_to(goal) / (speed * 0.1)))
	var p = from
	for i in steps:
		if s.state != Session.State.LOGGED_IN:
			return p
		p = from.lerp(goal, float(i + 1) / steps)
		s.send_move(p, atan2(d.x, d.z), Proto.MOVE_RUN)
		await tree.create_timer(0.1).timeout
	s.send_move(p, atan2(d.x, d.z), Proto.MOVE_STAND)
	await tree.create_timer(0.15).timeout
	return p

func chase(s: Session, id: int, from: Vector3, cond: Callable, seconds: float) -> Vector3:
	var pushes: Array = s.get_meta("pushes")
	var end = Time.get_ticks_msec() + int(seconds * 1000.0)
	var p = from
	while not cond.call() and Time.get_ticks_msec() < end and s.state == Session.State.LOGGED_IN:
		var n = npcs(pushes).get(id, {})
		if n.is_empty():
			break
		if Vector2(n["at"].x - p.x, n["at"].z - p.z).length() > 2.5:
			p = await walk(s, p, n["at"], 1.5)
		else:
			await tree.create_timer(0.1).timeout
	return p

func until(cond: Callable, seconds: float) -> bool:
	var end = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not cond.call():
		if Time.get_ticks_msec() > end:
			return false
		await tree.process_frame
	return true
