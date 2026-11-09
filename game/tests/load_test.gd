extends SceneTree

# ====================================================
# Lasttest (Fahrplan 11.2): viele Bots gleichzeitig gegen einen eigenen Server (tests/test_server.gd:
# Ordner user://test_server/last, frische Datenbank, Maps s9, s10, s11, s31):
#   godot --headless --path <Projekt> -s res://game/tests/load_test.gd -- [--bots=25] [--seconds=60]
#         [--port=29120]
# Ablauf: alle Bots legen gleichzeitig Konto und Figur an (vier von fünf Menschen in s9, der Rest
# verteilt auf die anderen Startmaps), betreten die Welt und spielen dann --seconds lang: umherlaufen,
# Monster angreifen (nachlaufen bis es stirbt, tot -> wiederbeleben), "Sagen", Ziele wählen. Eine
# eigene Sitzung misst die ganze Zeit die Antwortzeit (ping; ohne Messungen, während derer der Test
# selbst hing); der Server meldet je 10 s die Dauer seines Welt-Takts, sein längstes Bild und den
# Netz-Durchsatz (status.json "load").
# Prüft: alle Bots in der Welt, jeder sieht die anderen in Sichtweite (gleiche Map, Startpunkte bis
# 120 m auseinander; Elfen und Steinmenschen starten in s10 weit getrennt), diese bekommen Positionen, der
# Server hängt beim gleichzeitigen Anmelden nicht (Hash im Hintergrund: längstes Bild, Antwortzeit),
# Antwortzeit und Takt-Dauer im Spiel, keine unerwarteten Antworten, keine Rücksetzungen beim Laufen,
# Kämpfe mit Kills, Chat kommt an, nach dem Abmelden ist der Server leer, keine Fehler im Server-Log.
# Eine einzelne Ping-Spitze um 230 ms beim Anmelden ist ENet (wiederholtes Paket einer jungen
# Verbindung), nicht der Server - deshalb gilt dort das längste Bild des Servers.
# Ende: "LAST-TEST OK" (Exit 0) oder "LAST-TEST FEHLER" (Exit 1), nach Zeitlimit Abbruch (Exit 2).
# ====================================================

const Proto = preload("../common/protocol.gd")
const Settings = preload("../common/settings.gd")
const Session = preload("../client/session.gd")
const TestServer = preload("test_server.gd")
const TestUtil = preload("test_util.gd")
const PLUGIN_SERVER = "res://addons/PWE-Manager/Server/"
const DIR = "user://test_server/last"
const DEFAULT_PORT = 29120
const MAPS = "s9,s10,s11,s31"
const PASSWORD = "geheim-123"
const LOOK = {"face": 1, "mask": 2, "hair": 3, "skin": 4, "hair_color": 0xD25720}
const WANDER = 15.0 # m um den Startpunkt
const FIGHT_RANGE = 80.0 # m: Monster so nah werden angegriffen
# Grenzen
const PING_LOGIN_MAX = 1000.0 # ms, während alle gleichzeitig anmelden (Hash im Haupt-Thread: Sekunden)
const FRAME_MAX = 100.0 # ms: längstes Bild des Servers
const PING_P95 = 100.0
const PING_MAX = 500.0
const TICK_AVG = 0.4 # ms je Bot (der Takt hat 100 ms; 25 Bots: 10 ms)
const TICK_MAX = 2.0 # ms je Bot, mindestens 50 ms
# erwartete Antworten je Anfrage (alles andere zählt als Fehler)
const ALLOWED = {"attack": [Proto.Code.OK, Proto.Code.ATTACK_INVALID, Proto.Code.YOU_ARE_DEAD],
	"target": [Proto.Code.OK, Proto.Code.TARGET_INVALID], "chat": [Proto.Code.OK, Proto.Code.CHAT_TOO_FAST],
	"revive": [Proto.Code.OK, Proto.Code.NOT_DEAD], "attack_stop": [Proto.Code.OK]}

var u: TestUtil
var srv: TestServer
var port = DEFAULT_PORT
var count = 25
var seconds = 60.0
var checks = 0
var failures = 0
var bots: Array = [] # {i, s, map, home, pos, id, kills, deaths, revives, chats, heard, requests, errors, states, bad}
var phase = "" # login / play / logout
var pings = {"login": [], "play": []}
var loads: Array = [] # status.json "load", jede neue Messung mit der Phase: [Phase, load]
var monsters = {} # Vorlagen-IDs der Monster (Plugin Server/npc_templates.json): nur die greifen Bots an
var _running = 0
var _stalls = 0 # Bilder des Tests über 50 ms (Pings darüber messen den Test, nicht den Server)
var _ended = false


func _initialize() -> void:
	var args = Settings.user_args()
	port = int(args.get("port", str(DEFAULT_PORT)))
	count = maxi(2, int(args.get("bots", "25")))
	seconds = maxf(10.0, float(args.get("seconds", "60")))
	Engine.max_fps = 120
	var t = JSON.parse_string(FileAccess.get_file_as_string(PLUGIN_SERVER + "npc_templates.json"))
	for k in (t.get("monsters", {}) if t is Dictionary else {}):
		monsters[int(k)] = true
	u = TestUtil.new(self)
	srv = TestServer.new(DIR, port, ["--maps=" + MAPS, "--max_clients=%d" % (count + 16)])
	create_timer(seconds + 240.0).timeout.connect(func(): _end(2))
	_run.call_deferred()

func _process(delta: float) -> bool:
	if delta > 0.05:
		_stalls += 1
	u.poll()
	return false

func _run() -> void:
	srv.fresh()
	_check("Server startet (Port %d, Maps %s)" % [port, MAPS], await srv.start(self))
	if not srv.running():
		_end(1)
		return
	var probe = u.session("Messung", port)
	_check_code("Mess-Sitzung verbunden", await probe.open(), Proto.Code.OK)
	_ping_loop(probe)
	_load_loop()

	# alle gleichzeitig anmelden
	phase = "login"
	var t0 = Time.get_ticks_msec()
	for i in count:
		var b = {"i": i, "name": "Last%02d" % i, "s": u.session("Last%02d" % i, port), "map": "", "home": Vector3.ZERO, "pos": Vector3.ZERO, "id": 0,
			"kills": 0, "deaths": 0, "revives": 0, "chats": 0, "heard": 0, "requests": 0, "errors": [], "states": 0, "bad": {}}
		b["s"].net.state_received.connect(func(entries): b["states"] += entries.size())
		bots.append(b)
		_bot_enter(b)
	await u.until(func(): return _running == 0, 120.0)
	var in_world = bots.filter(func(b): return b["id"] != 0)
	var login_s = (Time.get_ticks_msec() - t0) / 1000.0
	_check("%d von %d Bots in der Welt nach %.1f s (%s)" % [in_world.size(), count, login_s, _per_map()], in_world.size() == count)
	_check("Antwortzeit beim Anmelden: %s" % _stats(pings["login"]), not pings["login"].is_empty()
		and pings["login"].max() < PING_LOGIN_MAX)
	await create_timer(2.0).timeout
	var blind = []
	for b in in_world:
		var seen = u.seen_players(b["s"].get_meta("pushes")).size()
		if seen != _neighbours(b, Proto.VIEW_RANGE).size():
			blind.append("%s sieht %d von %d" % [b["name"], seen, _neighbours(b, Proto.VIEW_RANGE).size()])
	_check("jeder Bot sieht die anderen in Sichtweite %s" % str(blind.slice(0, 5)), blind.is_empty())
	if in_world.size() != count:
		_end(1)
		return

	# spielen
	phase = "play"
	var end = Time.get_ticks_msec() + int(seconds * 1000.0)
	for b in bots:
		_bot_play(b, end)
	await u.until(func(): return _running == 0, seconds + 60.0)
	var all_requests = 0
	var kills = 0
	var deaths = 0
	var chats = 0
	var heard = 0
	var corrections = 0
	var errors = []
	var no_states = []
	for b in bots:
		all_requests += b["requests"]
		kills += b["kills"]
		deaths += b["deaths"]
		chats += b["chats"]
		heard += b["heard"]
		errors.append_array(b["errors"])
		# Wiederbeleben setzt die Figur per pos_correct an den Wiederbelebungspunkt, das zählt nicht
		corrections += u.count(b["s"].get_meta("pushes"), "pos_correct") - b["revives"]
		if b["states"] == 0 and not _neighbours(b, Proto.VIEW_RANGE - 2.0 * WANDER).is_empty():
			no_states.append(b["name"])
	_check("Antwortzeit im Spiel: %s" % _stats(pings["play"]), not pings["play"].is_empty()
		and _percentile(pings["play"], 0.95) < PING_P95 and pings["play"].max() < PING_MAX)
	var play = loads.filter(func(x): return x[0] == "play" and int(x[1].get("in_world", 0)) == count).map(func(x): return x[1])
	var tick_avg = 0.0
	var tick_max = 0.0
	var sent = 0.0
	var recv = 0.0
	for l in play:
		tick_avg += float(l["tick_avg_ms"]) / play.size()
		tick_max = maxf(tick_max, float(l["tick_max_ms"]))
		sent += float(l["sent_kbps"]) / play.size()
		recv += float(l["recv_kbps"]) / play.size()
	_check("Server-Takt mit %d Spielern: Ø %.2f ms, max %.2f ms (%d Messungen); Netz Ø %.1f kB/s raus, %.1f kB/s rein" % [count, tick_avg,
		tick_max, play.size(), sent, recv], not play.is_empty() and tick_avg < TICK_AVG * count and tick_max < maxf(50.0, TICK_MAX * count))
	var frame = 0.0
	for x in loads:
		frame = maxf(frame, float(x[1].get("frame_max_ms", 0.0)))
	_check("längstes Bild des Servers (Anmelden und Spiel): %.1f ms" % frame, not loads.is_empty() and frame < FRAME_MAX)
	_check("%d Anfragen (%.0f / s), keine unerwarteten Antworten %s" % [all_requests, all_requests / seconds, str(errors.slice(0, 5))],
		errors.is_empty())
	_check("keine Rücksetzungen beim Laufen (%d)" % corrections, corrections == 0)
	_check("alle Bots bekommen Positionen der anderen %s" % str(no_states.slice(0, 5)), no_states.is_empty())
	_check("Kämpfe: %d Kills, %d Tode" % [kills, deaths], kills > 0)
	_check("Chat: %d Nachrichten, %d mal bei anderen angekommen" % [chats, heard], chats > 0 and heard > chats)

	# alle abmelden
	phase = "logout"
	for b in bots:
		_bot_leave(b)
	await u.until(func(): return _running == 0, 30.0)
	probe.close()
	var empty = func(): return srv.status().get("players", [1]).is_empty() and int(srv.status().get("in_world", 1)) == 0
	_check("nach dem Abmelden ist der Server leer", await u.until(empty, 5.0))
	_check("Server sauber beendet", await srv.stop(self))
	var bad_lines = Array(srv.log_text().split("\n")).filter(func(l): return l.contains("FEHLER"))
	_check("keine Fehler im Server-Log %s" % str(bad_lines.slice(0, 3)), bad_lines.is_empty())
	_end(0 if failures == 0 else 1)


# ====================================================
# BOTS
# ====================================================
func _bot_enter(b: Dictionary) -> void:
	_running += 1
	var s: Session = b["s"]
	var acc = "Lastbot%02d" % b["i"]
	var r = await s.register(acc, PASSWORD)
	if r["code"] == Proto.Code.OK:
		r = await s.login(acc, PASSWORD)
	if r["code"] == Proto.Code.OK:
		r = await s.list_chars()
	if r["code"] == Proto.Code.OK:
		var combo = _combo(b["i"], r["data"].get("classes", []))
		var c = combo.split("_")
		r = await s.create_char("Lastheld%02d" % b["i"], int(c[0]), int(c[1]), int(c[2]), LOOK)
	if r["code"] == Proto.Code.OK:
		r = await s.enter_char(int(r["data"]["char"]["id"]))
	if r["code"] == Proto.Code.OK:
		var p: Array = r["data"]["pos"]
		b["map"] = r["data"]["map"]
		b["home"] = Vector3(p[0], p[1], p[2])
		b["pos"] = b["home"]
		r = await s.world_ready()
	if r["code"] == Proto.Code.OK:
		b["id"] = int(r["data"]["id"])
	else:
		b["errors"].append("%s: Anmelden %s" % [acc, Proto.text(int(r["code"]))])
	_running -= 1

# Vier von fünf Menschen (Rasse 1), sonst eine andere Rasse; Klasse / Geschlecht reihum aus den Vorlagen
func _combo(i: int, classes: Array) -> String:
	var human = classes.filter(func(c): return str(c).begins_with("1_"))
	var other = classes.filter(func(c): return not str(c).begins_with("1_"))
	var list = human if i % 5 != 4 or other.is_empty() else other
	return str(list[(i / 5 if list == other else i) % list.size()])

func _bot_play(b: Dictionary, end: int) -> void:
	_running += 1
	var s: Session = b["s"]
	var pushes: Array = s.get_meta("pushes")
	var chat_from = pushes.size()
	while Time.get_ticks_msec() < end and s.state == Session.State.LOGGED_IN:
		if _dead(b):
			await create_timer(1.0).timeout
			var r = await _req(b, "revive", s.revive)
			if r["code"] == Proto.Code.OK:
				var p: Array = r["data"]["pos"]
				b["pos"] = Vector3(p[0], p[1], p[2])
				b["revives"] += 1
			continue
		var roll = randf()
		if roll < 0.45:
			var to = b["home"] + Vector3(randf_range(-WANDER, WANDER), 0, randf_range(-WANDER, WANDER))
			b["pos"] = await u.walk(s, b["pos"], Vector3(to.x, b["pos"].y, to.z), 0.0)
		elif roll < 0.8:
			await _fight(b)
		else:
			var r = await _req(b, "chat", s.say.bind("Hallo von %s" % b["name"]))
			if r["code"] == Proto.Code.OK:
				b["chats"] += 1
			var seen = u.seen_players(pushes).keys()
			if not seen.is_empty():
				await _req(b, "target", s.select_target.bind(seen.pick_random()))
			await create_timer(randf_range(0.5, 1.5)).timeout
	for i in range(chat_from, pushes.size()):
		if pushes[i][0] == "chat" and int(pushes[i][1].get("id", 0)) != b["id"]:
			b["heard"] += 1
	_running -= 1

func _fight(b: Dictionary) -> void:
	var s: Session = b["s"]
	var pushes: Array = s.get_meta("pushes")
	var nc = u.npcs(pushes)
	var target = 0
	var best = FIGHT_RANGE
	for id in nc:
		var d = nc[id]["at"].distance_to(b["pos"])
		if d < best and monsters.has(int(nc[id]["tid"])) and not b["bad"].has(id):
			best = d
			target = id
	if target == 0:
		await create_timer(0.5).timeout
		return
	var r = await _req(b, "attack", s.attack.bind(target))
	if r["code"] != Proto.Code.OK:
		b["bad"][target] = true # nicht wählbar (Deko-Tier)
		return

	var gone = func(): return not u.npcs(pushes).has(target) or _dead(b)
	b["pos"] = await u.chase(s, target, b["pos"], gone, 20.0)
	if pushes.any(func(e): return e[0] == "kill" and e[1]["id"] == target):
		b["kills"] += 1
	if s.state == Session.State.LOGGED_IN and not _dead(b):
		await _req(b, "attack_stop", s.attack_stop)

# Bots derselben Map, deren Startpunkt höchstens range m von dem von b liegt
func _neighbours(b: Dictionary, range: float) -> Array:
	return bots.filter(func(o): return o != b and o["id"] != 0 and o["map"] == b["map"] and o["home"].distance_to(b["home"]) <= range)

func _dead(b: Dictionary) -> bool:
	var pushes: Array = b["s"].get_meta("pushes")
	for i in range(pushes.size() - 1, -1, -1):
		var e = pushes[i]
		if e[0] == "die" and int(e[1]["id"]) == b["id"]:
			return true
		if e[0] == "revive" and int(e[1]["id"]) == b["id"]:
			return false
		if e[0] == "stats":
			return int(e[1]["hp"]) <= 0
	return false

func _bot_leave(b: Dictionary) -> void:
	_running += 1
	var s: Session = b["s"]
	if s.state == Session.State.LOGGED_IN:
		await s.world_leave()
		await s.logout()
	s.close()
	_running -= 1

# Anfrage zählen und ihre Antwort prüfen (ALLOWED)
func _req(b: Dictionary, what: String, call: Callable) -> Dictionary:
	var r: Dictionary = await call.call()
	b["requests"] += 1
	if not int(r["code"]) in ALLOWED.get(what, [Proto.Code.OK]):
		b["errors"].append("%s %s: %s" % [b["name"], what, Proto.text(int(r["code"]))])
	if what == "revive" and int(r["code"]) == Proto.Code.OK:
		b["deaths"] += 1
	return r


# ====================================================
# MESSUNG
# ====================================================
func _ping_loop(probe: Session) -> void:
	while probe.state != Session.State.OFFLINE:
		var t = Time.get_ticks_usec()
		var stalls = _stalls
		var r = await probe.net.request("ping")
		if r["code"] == Proto.Code.OK and pings.has(phase) and stalls == _stalls:
			pings[phase].append((Time.get_ticks_usec() - t) / 1000.0)
		await create_timer(0.2).timeout

# status.json lesen, jede neue Messung des Servers (alle 10 s) mit der Phase merken
func _load_loop() -> void:
	var last = ""
	while not _ended and srv.running():
		var l: Dictionary = srv.status().get("load", {})
		var key = JSON.stringify(l)
		if not l.is_empty() and key != last:
			last = key
			loads.append([phase, l])
		await create_timer(0.5).timeout

func _stats(list: Array) -> String:
	if list.is_empty():
		return "keine Messung"
	var sum = 0.0
	for v in list:
		sum += v
	return "Ø %.1f ms, 95 %% %.1f ms, max %.1f ms (%d Messungen)" % [sum / list.size(), _percentile(list, 0.95), list.max(), list.size()]

static func _percentile(list: Array, q: float) -> float:
	var s = list.duplicate()
	s.sort()
	return s[clampi(int(ceil(q * s.size())) - 1, 0, s.size() - 1)]

func _per_map() -> String:
	var n = {}
	for b in bots:
		if b["map"] != "":
			n[b["map"]] = n.get(b["map"], 0) + 1
	return ", ".join(n.keys().map(func(k): return "%s: %d" % [k, n[k]]))

func _check_code(what: String, r: Dictionary, expected: int) -> void:
	var code = int(r["code"])
	_check("%s -> %s" % [what, Proto.text(code)] if code == expected else
		"%s -> %s, erwartet: %s" % [what, Proto.text(code), Proto.text(expected)], code == expected)

func _check(what: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print(("ok      " if ok else "FEHLER  ") + what)

func _end(code: int) -> void:
	if _ended:
		return
	_ended = true
	if srv != null and srv.running():
		await srv.kill(self)
	if code == 2:
		print("LAST-TEST FEHLER: Zeitlimit überschritten (%d Prüfungen bis dahin)" % checks)
	elif failures == 0:
		print("LAST-TEST OK (%d Prüfungen)" % checks)
	else:
		print("LAST-TEST FEHLER: %d von %d Prüfungen" % [failures, checks])
	quit(code if code == 2 else (0 if failures == 0 else 1))
