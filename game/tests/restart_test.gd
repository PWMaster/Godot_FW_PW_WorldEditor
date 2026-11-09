extends SceneTree

# ====================================================
# Test von Server-Neustart, Absturz und Wiederverbinden (Fahrplan 11.2) mit eigenem Server
# (tests/test_server.gd: Ordner user://test_server/neustart, frische Datenbank, nur s9):
#   godot --headless --path <Projekt> -s res://game/tests/restart_test.gd [-- --port=29110]
# Zwei Spieler in s9: R (Menschen-Priesterin, Quest 5965) und Z (Zuschauer, sieht R).
#  1 Sauberer Neustart mitten im Kampf: R schließt Teil 5972 bei Lady Vestry ab, läuft zu den
#    Wildschweinen bei Johnny, greift eins an und wird getroffen; der Server endet über die
#    Stopp-Datei -> R und Z bekommen server_closing und werden getrennt. Nach dem Neustart steht R an
#    derselben Stelle mit demselben Leben / Mana, derselben Quest (5973 dran), Inventar und Stufe.
#  2 Absturz: R schließt 5973 bei Adam ab (sofort gespeichert) und läuft weiter; der Server wird hart
#    beendet. Nach dem Neustart ist die Quest weiter, die Position die zuletzt gespeicherte (die
#    Neustart-Stelle, nicht bei Adam) und die Datenbank vollständig (2 Konten, 2 Figuren).
#  3 Verbindung weg: R trennt ohne Abmelden -> Z sieht R gehen, R meldet sich ohne "erzwingen" sofort
#    wieder an und steht an derselben Stelle. Verbindung hängt: Rs Netz steht still; eine neue
#    Anmeldung ohne "erzwingen" -> ACCOUNT_ONLINE, erzwungen -> OK, die hängende Sitzung fliegt
#    (Z sieht R gehen und wiederkommen), R steht an derselben Stelle.
# Zum Schluss sauber beenden: Status gestoppt, niemand online, keine Fehler im Server-Log.
# Ende: "NEUSTART-TEST OK" (Exit 0) oder "NEUSTART-TEST FEHLER" (Exit 1), nach 300 s Abbruch (Exit 2).
# ====================================================

const Proto = preload("../common/protocol.gd")
const Settings = preload("../common/settings.gd")
const Session = preload("../client/session.gd")
const TestServer = preload("test_server.gd")
const TestUtil = preload("test_util.gd")
const DIR = "user://test_server/neustart"
const DEFAULT_PORT = 29110
const PASSWORD = "geheim-123"
const LOOK = {"face": 1, "mask": 2, "hair": 3, "skin": 4, "hair_color": 0xD25720}
const VESTRY = 14429
const ADAM = 14432
const JOHNNY = 21041
const BOAR = 14563
const TIMEOUT = 300.0

var u: TestUtil
var srv: TestServer
var port = DEFAULT_PORT
var checks = 0
var failures = 0
var _ended = false


func _initialize() -> void:
	port = int(Settings.user_args().get("port", str(DEFAULT_PORT)))
	u = TestUtil.new(self)
	srv = TestServer.new(DIR, port, ["--maps=s9"])
	create_timer(TIMEOUT).timeout.connect(func(): _end(2))
	_run.call_deferred()

func _process(_delta: float) -> bool:
	u.poll()
	return false

func _run() -> void:
	srv.fresh()
	_check("Server startet (Port %d, %s)" % [port, DIR], await srv.start(self))
	if not srv.running():
		_end(1)
		return
	var r = u.session("R", port)
	var z = u.session("Z", port)
	var rc = await _new_player(r, "Neustart_R", "Neustarterin", 1, 6, 1)
	var zc = await _new_player(z, "Neustart_Z", "Zuschauer", 1, 1, 0)
	_check("zwei Konten mit Figur", rc != 0 and zc != 0)
	if rc == 0 or zc == 0:
		_end(1)
		return
	var rest = await _clean_restart(r, z, rc, zc)
	if rest.is_empty():
		_end(1)
		return
	var at = await _crash(r, rc, rest["pos"])
	await _reconnect(r, z, rc, zc, at)
	for s in [r, z]:
		if s.state == Session.State.LOGGED_IN:
			await s.logout()
	_check("Server sauber beendet", await srv.stop(self))
	var st = srv.status()
	_check("Status: gestoppt, niemand online", st.get("running", true) == false and st.get("players", [1]).is_empty())
	var errors = Array(srv.log_text().split("\n")).filter(func(l): return l.contains("FEHLER"))
	_check("keine Fehler im Server-Log %s" % str(errors.slice(0, 3)), errors.is_empty())
	_end(0 if failures == 0 else 1)


# ====================================================
# 1 SAUBERER NEUSTART MITTEN IM KAMPF
# ====================================================
func _clean_restart(r: Session, z: Session, rc: int, zc: int) -> Dictionary:
	var e = await _enter(r, rc)
	var ez = await _enter(z, zc)
	if e.is_empty() or ez.is_empty():
		_check("beide in der Welt", false)
		return {}
	var me: int = e["ready"]["id"]
	var rp: Array = r.get_meta("pushes")
	var zp: Array = z.get_meta("pushes")
	var pos = _pos(e["enter"])
	_check("R in s9, Quest 5965 mit Teil 5972", e["enter"]["map"] == "s9" and 5972 in _active(e["ready"]))
	_check("Z sieht R", await u.until(func(): return u.seen_players(zp).has(me), 5.0))
	await u.until(func(): return u.find_npc(rp, VESTRY) != 0 and u.find_npc(rp, JOHNNY) != 0, 5.0)
	_check_code("Teil 5972 bei Lady Vestry", await r.quest_complete(u.find_npc(rp, VESTRY), 5972), Proto.Code.OK)
	pos = await u.walk(r, pos, u.npcs(rp)[u.find_npc(rp, JOHNNY)]["at"], 3.0)
	var boar = _nearest(rp, BOAR, pos)
	_check("Wildschwein in Sicht", boar != 0)
	if boar == 0:
		return {}
	pos = await u.walk(r, pos, u.npcs(rp)[boar]["at"])
	_check_code("Wildschwein angreifen", await r.attack(boar), Proto.Code.OK)
	var hurt = func(): return rp.any(func(x): return x[0] == "hit" and x[1]["dst"] == me and not x[1]["miss"] and x[1]["dmg"] > 0)
	pos = await u.chase(r, boar, pos, hurt, 20.0)
	_check("das Wildschwein trifft R", hurt.call())
	await create_timer(0.3).timeout

	# Server beenden, während R kämpft
	var closing = func(s: Session): return s.get_meta("pushes").any(func(x): return x[0] == "server_closing")
	_check("Server über die Stopp-Datei beendet", await srv.stop(self))
	_check("R und Z bekommen server_closing", closing.call(r) and closing.call(z))
	_check("R und Z getrennt", await u.until(func(): return r.state == Session.State.OFFLINE and z.state == Session.State.OFFLINE, 5.0))
	var before = _state(rp.slice(e["mark"]), e["ready"])
	_check("R zuletzt verletzt: %d / %d HP, %d MP" % [before["hp"], before["max_hp"], before["mp"]], before["hp"] < before["max_hp"])

	_check("Server startet neu", await srv.start(self))
	rp.clear()
	_check_code("R meldet sich wieder an", await r.login("Neustart_R", PASSWORD), Proto.Code.OK)
	var e2 = await _enter(r, rc)
	if e2.is_empty():
		_check("R wieder in der Welt", false)
		return {}
	var after = _state([], e2["ready"])
	var at = _pos(e2["enter"])
	_check("nach Neustart: R an derselben Stelle (%.2f m daneben)" % at.distance_to(pos), at.distance_to(pos) < 0.05)
	_check("nach Neustart: Leben %d, Mana %d (vorher %d / %d)" % [int(e2["enter"]["hp"]), int(e2["enter"]["mp"]), before["hp"],
		before["mp"]], int(e2["enter"]["hp"]) == before["hp"] and int(e2["enter"]["mp"]) == before["mp"] and not e2["ready"].get("dead", true))
	_check("nach Neustart: Quest gleich (%s), 5973 dran" % str(after["active"]), after["active"] == before["active"]
		and after["done"] == before["done"] and 5973 in after["active"])
	_check("nach Neustart: Inventar und Stufe gleich", after["bag"] == before["bag"] and after["equip"] == before["equip"]
		and after["level"] == before["level"] and after["exp"] == before["exp"])
	await r.world_leave()
	return {"pos": at}


# ====================================================
# 2 ABSTURZ
# ====================================================
func _crash(r: Session, rc: int, saved: Vector3) -> Vector3:
	var e = await _enter(r, rc)
	if e.is_empty():
		_check("R in der Welt (vor dem Absturz)", false)
		return saved
	var rp: Array = r.get_meta("pushes")
	var pos = _pos(e["enter"])
	await u.until(func(): return u.find_npc(rp, ADAM) != 0, 5.0)
	var adam = u.find_npc(rp, ADAM)
	pos = await u.walk(r, pos, u.npcs(rp)[adam]["at"]) if adam != 0 else pos
	_check_code("Teil 5973 bei Adam", await r.quest_complete(adam, 5973), Proto.Code.OK)
	pos = await u.walk(r, pos, pos + Vector3(6, 0, 0), 0.0)
	var quests = u.last(rp, "quests")
	await srv.kill(self)
	_check("Server hart beendet (Absturz)", not srv.running())
	r.close()
	_check("Server startet nach dem Absturz", await srv.start(self))
	var line = Array(srv.log_text().split("\n")).filter(func(l): return l.contains("Datenbank "))
	_check("Datenbank nach dem Absturz vollständig (%s)" % (str(line[0]).get_slice("Datenbank ", 1) if not line.is_empty() else "?"),
		not line.is_empty() and str(line[0]).contains("2 Konten, 2 Figuren"))
	rp.clear()
	_check_code("R meldet sich an", await r.login("Neustart_R", PASSWORD), Proto.Code.OK)
	var e2 = await _enter(r, rc)
	if e2.is_empty():
		_check("R wieder in der Welt (nach dem Absturz)", false)
		return saved
	var at = _pos(e2["enter"])
	var active = _active(e2["ready"])
	_check("nach dem Absturz: Quest weiter (%s)" % str(active), not 5973 in active and 5965 in active
		and active == quests.get("active", []).map(func(x): return x[0]))
	_check("nach dem Absturz: zuletzt gespeicherte Stelle (%.2f m daneben, %.1f m von Adam)" % [at.distance_to(saved), at.distance_to(pos)],
		at.distance_to(saved) < 0.05 and at.distance_to(pos) > 5.0)
	return at


# ====================================================
# 3 WIEDERVERBINDEN
# ====================================================
func _reconnect(r: Session, z: Session, rc: int, zc: int, at: Vector3) -> void:
	var rp: Array = r.get_meta("pushes")
	var zp: Array = z.get_meta("pushes")
	z.close()
	zp.clear()
	_check_code("Z meldet sich an", await z.login("Neustart_Z", PASSWORD), Proto.Code.OK)
	await _enter(z, zc)
	var me: int = rc # Objekt-ID eines Spielers = Nummer der Figur
	var ready = func(): return u.seen_players(zp).has(me)
	_check("Z sieht R", await u.until(ready, 5.0))
	at = await u.walk(r, at, at + Vector3(0, 0, 4), 0.0)
	await create_timer(0.3).timeout
	var hp = int((await r.select_target(me))["data"].get("hp", -1)) # eigene Figur als Ziel: Leben jetzt

	# Verbindung weg ohne Abmelden
	r.close()
	_check("Verbindung weg: Z sieht R gehen", await u.until(func(): return not u.seen_players(zp).has(me), 5.0))
	rp.clear()
	_check_code("R meldet sich ohne 'erzwingen' wieder an", await r.login("Neustart_R", PASSWORD), Proto.Code.OK)
	var e = await _enter(r, rc)
	var pos = _pos(e.get("enter", {"pos": [0, 0, 0]}))
	_check("R an derselben Stelle (%.2f m), Leben %s (vorher %d)" % [pos.distance_to(at), e.get("enter", {}).get("hp"), hp],
		pos.distance_to(at) < 0.05 and int(e.get("enter", {}).get("hp", -1)) >= hp)
	_check("Z sieht R wieder", await u.until(ready, 5.0))

	# Verbindung hängt: Rs Netz steht still, eine neue Anmeldung übernimmt
	pos = await u.walk(r, pos, pos + Vector3(-4, 0, 0), 0.0)
	await create_timer(0.3).timeout
	u.freeze(r)
	var r2 = u.session("R2", port)
	_check_code("neue Anmeldung ohne 'erzwingen'", await r2.login("Neustart_R", PASSWORD), Proto.Code.ACCOUNT_ONLINE)
	_check_code("neue Anmeldung erzwungen", await r2.login("Neustart_R", PASSWORD, true), Proto.Code.OK)
	_check("Z sieht die hängende R gehen", await u.until(func(): return not u.seen_players(zp).has(me), 5.0))
	var e2 = await _enter(r2, rc)
	var pos2 = _pos(e2.get("enter", {"pos": [0, 0, 0]}))
	_check("R über die neue Sitzung an derselben Stelle (%.2f m)" % pos2.distance_to(pos), pos2.distance_to(pos) < 0.05)
	_check("Z sieht R wiederkommen", await u.until(ready, 5.0))
	u.thaw(r)
	var kicked = func(): return r.state == Session.State.OFFLINE and r.last_kick == Proto.Code.LOGGED_IN_ELSEWHERE
	_check("hängende Sitzung erfährt 'an anderer Stelle angemeldet'", await u.until(kicked, 5.0))
	await r2.logout()


# ====================================================
# HILFEN
# ====================================================
func _new_player(s: Session, acc: String, hero: String, race: int, cls: int, gender: int) -> int:
	if (await s.register(acc, PASSWORD))["code"] != Proto.Code.OK:
		return 0
	if (await s.login(acc, PASSWORD))["code"] != Proto.Code.OK:
		return 0
	var r = await s.create_char(hero, race, cls, gender, LOOK)
	return int(r["data"].get("char", {}).get("id", 0)) if r["code"] == Proto.Code.OK else 0

# char_enter + world_ready -> {enter, ready, mark (Meldungen bis dahin)} oder {}
func _enter(s: Session, char_id: int) -> Dictionary:
	var r = await s.enter_char(char_id)
	if r["code"] != Proto.Code.OK:
		return {}
	var w = await s.world_ready()
	if w["code"] != Proto.Code.OK:
		return {}
	return {"enter": r["data"], "ready": w["data"], "mark": s.get_meta("pushes").size()}

# Zustand der eigenen Figur nach world_ready und den Meldungen danach
func _state(pushes: Array, ready: Dictionary) -> Dictionary:
	var st: Dictionary = ready.get("stats", {})
	var inv: Dictionary = ready.get("inventory", {})
	var q: Dictionary = ready.get("quests", {})
	var out = {"hp": int(st.get("hp", 0)), "max_hp": int(st.get("max_hp", 0)), "mp": int(st.get("mp", 0)),
		"level": int(st.get("level", 0)), "exp": int(st.get("exp", 0)), "bag": inv.get("bag", []), "equip": inv.get("equip", []),
		"active": q.get("active", []).map(func(x): return x[0]), "done": q.get("done", [])}
	var me = int(ready.get("id", 0))
	for x in pushes:
		match x[0]:
			"stats":
				out["hp"] = int(x[1]["hp"])
				out["max_hp"] = int(x[1]["max_hp"])
				out["mp"] = int(x[1]["mp"])
				out["level"] = int(x[1]["level"])
				out["exp"] = int(x[1]["exp"])
			"hit":
				if int(x[1]["dst"]) == me:
					out["hp"] = int(x[1]["hp"])
			"inventory":
				out["bag"] = x[1].get("bag", [])
				out["equip"] = x[1].get("equip", [])
			"quests":
				out["active"] = x[1].get("active", []).map(func(y): return y[0])
				out["done"] = x[1].get("done", [])
	return out

func _active(ready: Dictionary) -> Array:
	return ready.get("quests", {}).get("active", []).map(func(x): return x[0])

static func _pos(enter: Dictionary) -> Vector3:
	var p: Array = enter.get("pos", [0, 0, 0])
	return Vector3(p[0], p[1], p[2])

func _nearest(pushes: Array, tid: int, at: Vector3) -> int:
	var nc = u.npcs(pushes)
	var best = INF
	var out = 0
	for id in nc:
		if nc[id]["tid"] == tid and nc[id]["at"].distance_to(at) < best:
			best = nc[id]["at"].distance_to(at)
			out = id
	return out

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
		print("NEUSTART-TEST FEHLER: Zeitlimit %d s überschritten (%d Prüfungen bis dahin)" % [TIMEOUT, checks])
	elif failures == 0:
		print("NEUSTART-TEST OK (%d Prüfungen)" % checks)
	else:
		print("NEUSTART-TEST FEHLER: %d von %d Prüfungen" % [failures, checks])
	quit(code if code == 2 else (0 if failures == 0 else 1))
