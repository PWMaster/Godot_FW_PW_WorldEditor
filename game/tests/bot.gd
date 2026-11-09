extends Node

# ====================================================
# Test-Bot ohne Fenster: spielt Verbindung und Konten gegen einen laufenden Server durch.
#   godot --headless --path <Projekt> res://game/main.tscn -- --bot [--host=127.0.0.1] [--port=29000]
#         [--dtls] [--dtls_cert=<dtls.crt>] [--log=user://server/bot.log] [--expect-existing]
# Prüft: falsche Version, Anfrage vor "hello", unbekannte / falsch getypte Anfragen, Konto anlegen
# (doppelt in anderer Schreibweise, ungültiger Name / Passwort), Anmelden (falsches Passwort,
# unbekanntes Konto, richtig, doppelt), zweite Anmeldung desselben Kontos (ohne "erzwingen"
# abgewiesen, erzwungen fliegt die ältere Sitzung), Abmelden, Sperre nach 5 Fehlversuchen,
# Figuren (ohne Anmeldung, ungültige / unerlaubte Namen, geschlossene Klasse, falsches Aussehen,
# anlegen, doppelter Name, Liste, auswählen mit Startmap, löschen), Welt (zwei Figuren in s9: Sicht,
# Bewegung, Teleport abgelehnt, Verlassen, Position nach Neuanmeldung; NPCs und Monster: Lady
# Vestry am Start, beide sehen dieselben an derselben Stelle, Monster laufen umher; Höchstwerte
# nach Klasse, Ziel wählen (NPC, Monster, Spieler, sich selbst, ungültig), Chat "Sagen" mit
# Wortfilter, zu lang / leer / falscher Kanal, Flutbremse; Quests: erste Menschen-Quest 5678 wird
# automatisch vergeben, Teile bei Lady Vestry / Adam / Lady Vestry abschließen (falscher NPC, zu weit,
# Folgequest zu früh), Belohnung 40 EXP + Rüstung, Folgequest 5679 annehmen, nicht aufgebbar,
# Zustand nach Neuanmeldung; "Dauerheld" schließt den ersten Teil ab, nach Server-Neustart
# (--expect-existing) steht er beim zweiten); Inventar (Schritt 10b): leer mit 24 Plätzen, Rüstung
# der Belohnung anlegen (MP / Verteidigung steigen, D sieht player_equip), bei Johnny den ersten Teil
# von 5679, am Waffenregal sammeln (zu weit, ohne Quest am Magier-Regal, doppelt), Schwert in der
# Tasche, anlegen (Angriff / HP), ablegen und verschieben, wieder anlegen, 5679 bei Johnny abschließen
# (Stufe 2), Ausrüstung nach Neuanmeldung; jede Rasse / Klasse mit Startvorlage bekommt beim Betreten
# ihre Einstiegsquest (START_QUESTS, Werwölfe 15356 "Andere Welt": automatisch laut Server-tasks.data);
# Fertigkeiten: Startfertigkeiten (neu), Schnellleisten belegen / leeren, fremde Fertigkeit / ungültige Plätze
# abgewiesen, skill_seen, Leisten und neue Fertigkeiten nach Neuanmeldung;
# Kampf (Schritt 9): NPC / Unbekanntes nicht angreifbar, Quest 5680 bei Johnny, Wildschweine angreifen
# (Treffer, Gegenangriff, Tod, kill mit 6 EXP, Beute 14533), zehnmal, 5680 bei Lady Vestry abschließen
# (Beute eingezogen, 100 EXP); D lockt drei Giftjagdhunde an, stirbt (die), kann weder angreifen noch
# laufen, steht am Wiederbelebungspunkt mit 10 % HP wieder auf.
# Fertigkeiten einsetzen (F2): Werte von Hieb (info), unbekannt / noch nicht umgesetzt / NPC / zu weit
# abgewiesen, Hieb auf ein Wildschwein (Zaubern 1 s, Treffer mit skill, Mana, Abklingzeit), während des
# Zauberns und in der Abklingzeit abgewiesen, Bewegen bricht ab. Statuseffekte (F3): ein Magier brennt mit
# Feuerball ein Wildschwein (buffs, Ziel-Info, Schaden über Zeit, Abschuss durch den Brand bzw. Ende nach 5 s).
# Dazu das feste Konto "Bot_Dauer" mit der Figur "Dauerheld" (Passwort zufällig, in user://bot.cfg):
# mit --expect-existing müssen beide schon existieren - so zeigt ein zweiter Lauf nach
# Server-Neustart, dass Konten und Figuren bleiben.
# Jede Sitzung hat ihre eigene Multiplayer-API (Zweig /root/BotSitzung<X>, darunter Game/Net).
# Ende: "BOT OK" (Exit 0) oder "BOT FEHLER" (Exit 1); nach 90 s Abbruch (Exit 2).
# ====================================================

const Proto = preload("../common/protocol.gd")
const Settings = preload("../common/settings.gd")
const Net = preload("../common/net.gd")
const Session = preload("../client/session.gd")
const KEEP_ACCOUNT = "Bot_Dauer"
const KEEP_CHAR = "Dauerheld"
const LOOK = {"face": 1, "mask": 2, "hair": 3, "skin": 4, "hair_color": 0xD25720}
const KEEP_FILE = "user://bot.cfg"
const VESTRY = 14429 # Lady Vestry (erste Menschen-Quest) steht am Start von s9
const ADAM = 14432 # Feldwebel Adam, gut 30 m nördlich
const JOHNNY = 21041 # Johnny (Folgequest 5679), gut 50 m südlich
const RACK = 13533 # Waffenregal: Krieger (Sammelpunkt für 8366)
const RACK_MAGE = 15289 # Waffenregal: Magier (braucht 8368)
# Einstiegsquest je "<Rasse>_<Klasse>" (Server/start_roles.json)
const START_QUESTS = {"1_1": 5678, "1_3": 5963, "1_5": 5964, "1_6": 5965, "2_1": 7667, "2_6": 7667, "2_8": 7667,
	"3_4": 5686, "4_2": 5768, "5_3": 6914, "5_5": 6914, "5_7": 6914, "6_3": 15356, "6_6": 15356}
const SWORD = 15612
const ARMOR = 15613
const BOAR = 14563 # Wildschwein (Quest 5680, Beute 14533)
const BOAR_LOOT = 14533
const HOUND = 14578 # Giftjagdhund, Stufe 6, gut 170 m östlich
const HOUNDS_AT = Vector3(20.0, 82.0, 84.0)
const REVIVE_AT = Vector3(-151.0, 102.0, 42.0) # town_pos der Menschen (start_roles.json)
const TOTAL_TIMEOUT = 360.0

var host = "127.0.0.1"
var port = Proto.DEFAULT_PORT
var dtls = false
var dtls_cert = ""
var expect_existing = false
var checks = 0
var failures = 0
var _log: FileAccess
var _last_stats = {} # letzte Werte von C (Kampf)


func _ready() -> void:
	var args = Settings.user_args()
	var client = Settings.new("client")
	host = args.get("host", "127.0.0.1")
	port = int(args.get("port", str(Proto.DEFAULT_PORT)))
	dtls = client.value("dtls")
	dtls_cert = client.value("dtls_cert")
	expect_existing = args.has("expect-existing")
	if args.has("log"):
		DirAccess.make_dir_recursive_absolute(str(args["log"]).get_base_dir())
		_log = FileAccess.open(args["log"], FileAccess.WRITE)
	get_tree().create_timer(TOTAL_TIMEOUT).timeout.connect(_abort)
	_run.call_deferred()

func _run() -> void:
	_say("Test gegen %s:%d%s" % [host, port, " (DTLS)" if dtls else ""])
	var a = _session("A")
	var r: Dictionary

	# Verbindung und Version
	a.protocol_version = Proto.VERSION + 100
	r = await a.open()
	_check("falsche Protokoll-Version abgewiesen", r, Proto.Code.VERSION_MISMATCH)
	_check_true("danach getrennt", await _until(func(): return a.state == Session.State.OFFLINE, 3.0))
	a.protocol_version = Proto.VERSION
	r = await a.open(false)
	_check("verbinden ohne hello", r, Proto.Code.OK)
	if r["code"] != Proto.Code.OK:
		_finish()
		return
	r = await a.net.request("login", {"account": "Niemand", "password": "egal123"})
	_check("Anmeldung vor hello", r, Proto.Code.NOT_READY)
	r = await a.net.request("hello", {"version": Proto.VERSION, "client": "Bot"})
	_check("hello", r, Proto.Code.OK)
	r = await a.net.request("gibt_es_nicht")
	_check("unbekannte Anfrage", r, Proto.Code.UNKNOWN_REQUEST)
	r = await a.net.request("login", {"account": 5, "password": []})
	_check("falsche Typen", r, Proto.Code.BAD_REQUEST)
	r = await a.net.request("logout")
	_check("abmelden ohne Anmeldung", r, Proto.Code.NOT_LOGGED_IN)

	# Konto anlegen
	var acc = "Bot_%06d" % (randi() % 1000000)
	var pw = _random_password()
	r = await a.register(acc, pw)
	_check("Konto %s anlegen" % acc, r, Proto.Code.OK)
	r = await a.register(acc.to_upper(), pw)
	_check("gleicher Name in Großbuchstaben", r, Proto.Code.NAME_TAKEN)
	r = await a.register("1" + acc, pw)
	_check("Name mit Ziffer vorn", r, Proto.Code.NAME_INVALID)
	r = await a.register("abc", pw)
	_check("Name zu kurz", r, Proto.Code.NAME_INVALID)
	r = await a.register(acc + "x", "12345")
	_check("Passwort zu kurz", r, Proto.Code.PASSWORD_INVALID)

	# Anmelden
	r = await a.login(acc, pw + "x")
	_check("falsches Passwort", r, Proto.Code.WRONG_LOGIN)
	r = await a.login("Niemand_%06d" % (randi() % 1000000), pw)
	_check("unbekanntes Konto", r, Proto.Code.WRONG_LOGIN)
	r = await a.login(acc.to_lower(), pw)
	_check("anmelden (Kleinschreibung)", r, Proto.Code.OK)
	_check_true("Kontoname wie angelegt", a.account == acc)
	r = await a.login(acc, pw)
	_check("zweimal anmelden", r, Proto.Code.ALREADY_LOGGED_IN)

	# Dasselbe Konto von einer zweiten Sitzung: ohne "erzwingen" abgewiesen, erzwungen fliegt die erste
	var b = _session("B")
	r = await b.login(acc, pw)
	_check("zweite Sitzung ohne erzwingen", r, Proto.Code.ACCOUNT_ONLINE)
	r = await b.login(acc, pw, true)
	_check("zweite Sitzung erzwungen", r, Proto.Code.OK)
	_check_true("erste Sitzung getrennt", await _until(func(): return a.state == Session.State.OFFLINE, 5.0))
	_check_true("Grund: anderswo angemeldet", a.last_kick == Proto.Code.LOGGED_IN_ELSEWHERE)
	await _characters(b)
	r = await b.logout()
	_check("abmelden", r, Proto.Code.OK)
	r = await b.net.request("logout")
	_check("nochmal abmelden", r, Proto.Code.NOT_LOGGED_IN)
	r = await b.list_chars()
	_check("Figurenliste ohne Anmeldung", r, Proto.Code.NOT_LOGGED_IN)

	# Sperre nach Fehlversuchen
	var locked = "Bot_Sperre_%04d" % (randi() % 10000)
	r = await b.register(locked, pw)
	_check("Konto %s anlegen" % locked, r, Proto.Code.OK)
	var wrong = 0
	for i in 5:
		r = await b.login(locked, pw + "x")
		if r["code"] == Proto.Code.WRONG_LOGIN:
			wrong += 1
	_check_true("5 Fehlversuche abgewiesen", wrong == 5)
	r = await b.login(locked, pw)
	_check("danach gesperrt (auch mit richtigem Passwort)", r, Proto.Code.TOO_MANY_ATTEMPTS)

	await _world()
	await _start_quests()
	await _burn()

	# Dauer-Konto (übersteht Server-Neustart)
	var keep_pw = _keep_password()
	r = await b.register(KEEP_ACCOUNT, keep_pw)
	if expect_existing:
		_check("%s existiert schon" % KEEP_ACCOUNT, r, Proto.Code.NAME_TAKEN)
	else:
		_check_true("%s anlegen oder vorhanden (%s)" % [KEEP_ACCOUNT, Proto.text(r["code"])],
			r["code"] in [Proto.Code.OK, Proto.Code.NAME_TAKEN])
	r = await b.login(KEEP_ACCOUNT, keep_pw)
	_check("%s anmelden" % KEEP_ACCOUNT, r, Proto.Code.OK)
	r = await b.list_chars()
	var names = r["data"].get("chars", []).map(func(c): return c["name"])
	if expect_existing:
		_check_true("Figur %s noch da" % KEEP_CHAR, KEEP_CHAR in names)
	elif not KEEP_CHAR in names:
		r = await b.create_char(KEEP_CHAR, 1, 6, 1, LOOK)
		_check("Figur %s anlegen" % KEEP_CHAR, r, Proto.Code.OK)
		r = await b.list_chars()
	for ch in r["data"].get("chars", []):
		if ch["name"] == KEEP_CHAR:
			await _keep_quest(b, ch["id"])
	r = await b.logout()
	_check("%s abmelden" % KEEP_ACCOUNT, r, Proto.Code.OK)
	b.close()
	_finish()


# Zwei Figuren in derselben Map: C läuft, D sieht sie; Teleport abgelehnt; Position bleibt
func _world() -> void:
	var c = _session("C")
	var d = _session("D")
	var pw = _random_password()
	var ids = []
	for s in [[c, 1, 1, 0], [d, 1, 6, 1]]:
		var sess: Session = s[0]
		var acc = "Wb_%06d" % (randi() % 1000000)
		await sess.register(acc, pw)
		await sess.login(acc, pw)
		var r = await sess.create_char("Wl%06d" % (randi() % 1000000), s[1], s[2], s[3], LOOK)
		ids.append(r["data"].get("char", {}).get("id", 0))
	var r = await c.world_ready()
	_check("Welt ohne gewählte Figur", r, Proto.Code.NOT_IN_WORLD)
	var pushes_d = []
	var states_d = []
	var pushes_c = []
	d.net.pushed.connect(func(what, data): pushes_d.append([what, data]))
	d.net.state_received.connect(func(entries): states_d.append(entries))
	c.net.pushed.connect(func(what, data): pushes_c.append([what, data]))
	r = await c.enter_char(ids[0])
	var start: Array = r["data"].get("pos", [0, 0, 0])
	var v: Dictionary = r["data"]
	_check_true("Krieger Stufe 1: 1500 / 1500 HP, 500 / 500 MP, 70 EXP bis Stufe 2 (%s / %s, %s / %s, %s)" % [v.get("hp"),
		v.get("max_hp"), v.get("mp"), v.get("max_mp"), v.get("exp_next")], v.get("max_hp") == 1500 and v.get("hp") == 1500
		and v.get("max_mp") == 500 and v.get("mp") == 500 and v.get("exp_next") == 70)
	r = await c.world_ready()
	_check("C betritt s9", r, Proto.Code.OK)
	await _skills(c, r["data"])
	var quests_c: Dictionary = r["data"].get("quests", {})
	var inv: Dictionary = r["data"].get("inventory", {})
	_check_true("Inventar: 24 Plätze, leer, keine Ausrüstung (%s)" % str(inv), inv.get("size") == 24 and inv.get("bag", [1]).is_empty()
		and inv.get("equip", [1]).is_empty() and r["data"].get("stats", {}).get("attr", {}).get("def") == 60)
	var rd = await d.enter_char(ids[1])
	var start_d: Array = rd["data"].get("pos", [0, 0, 0])
	r = await d.world_ready()
	_check("D betritt s9", r, Proto.Code.OK)
	_check_true("D sieht C (player_enter)", await _until(func(): return pushes_d.any(func(e): return e[0] == "player_enter" and e[1]["id"] == ids[0]), 3.0))
	# NPCs und Monster
	var vestry = func(): return _npcs(pushes_c).values().any(func(n): return n["tid"] == VESTRY)
	_check_true("C sieht NPCs und Monster, Lady Vestry dabei (npc_enter)", await _until(vestry, 3.0))
	await _until(func(): return _npcs(pushes_d).size() > 20, 3.0)
	var nc = _npcs(pushes_c)
	var nd = _npcs(pushes_d)
	var common = nc.keys().filter(func(id): return nd.has(id))
	var differ = common.filter(func(id): return nc[id]["tid"] != nd[id]["tid"] or nc[id]["level"] != nd[id]["level"] or not nc[id]["at"].is_equal_approx(nd[id]["at"]))
	_say("C sieht %d, D %d NPCs / Monster, %d gemeinsam" % [nc.size(), nd.size(), common.size()])
	_check_true("C und D sehen dieselben NPCs an derselben Stelle", common.size() > 20 and differ.is_empty())
	var pos = Vector3(start[0], start[1], start[2])
	var walking = func(): return pushes_c.any(func(e): return e[0] == "npc_move" and nc.has(e[1]["id"]))
	_check_true("Monster laufen umher (npc_move)", await _until(walking, 10.0))
	await _target_and_chat(c, d, ids, _npcs(pushes_c), pushes_c, pushes_d)
	pos = await _quests(c, quests_c, pushes_c, Vector3(start[0], start[1], start[2]))
	_check_true("D sieht Cs Rüstung und Schwert (player_equip)", pushes_d.any(_full_equip.bind(ids[0])))
	pos = await _combat(c, pushes_c, ids[0], pos)
	await _death(d, pushes_d, ids[1], Vector3(start_d[0], start_d[1], start_d[2]))
	# C läuft 1 s mit 3,5 m/s nach +x (von dort, wo die Quests geendet haben)
	start = [pos.x, pos.y, pos.z]
	for i in 10:
		pos.x += 0.35
		c.send_move(pos, 0.0, Proto.MOVE_RUN)
		await get_tree().create_timer(0.1).timeout
	c.send_move(pos, 0.0, Proto.MOVE_STAND)
	var seen_x = func():
		for entries in states_d:
			for e in entries:
				if e[0] == ids[0] and absf(e[1] - pos.x) < 0.01 and e[5] == Proto.MOVE_STAND:
					return true
		return false
	_check_true("D empfängt Cs neue Position (+3,5 m)", await _until(seen_x, 3.0))
	c.send_move(pos + Vector3(100, 0, 0), 0.0, Proto.MOVE_RUN)
	var corrected = func(): return pushes_c.any(func(e): return e[0] == "pos_correct" and absf(e[1]["pos"][0] - pos.x) < 0.01)
	_check_true("Teleport abgelehnt (pos_correct)", await _until(corrected, 3.0))
	r = await c.world_leave()
	_check("C verlässt die Welt", r, Proto.Code.OK)
	_check_true("D sieht C gehen (player_leave)", await _until(func(): return pushes_d.any(func(e): return e[0] == "player_leave" and e[1]["id"] == ids[0]), 3.0))
	var acc_c = c.account
	await c.logout()
	await c.login(acc_c, pw)
	r = await c.enter_char(ids[0])
	var back: Array = r["data"].get("pos", [0, 0, 0])
	_check_true("Position nach Neuanmeldung gespeichert", absf(back[0] - pos.x) < 0.01 and absf(back[2] - pos.z) < 0.01)
	_check_true("Stufe und EXP nach Neuanmeldung gespeichert (%s, %s / %s)" % [r["data"]["char"].get("level"), r["data"].get("exp"),
		_last_stats.get("exp")], r["data"]["char"].get("level") == _last_stats.get("level") and r["data"].get("exp") == _last_stats.get("exp"))
	_check_true("Ausrüstung nach Neuanmeldung (char_enter equip %s)" % str(r["data"].get("equip")),
		r["data"].get("equip", []).has([0, SWORD]) and r["data"].get("equip", []).has([3, ARMOR]))
	r = await c.world_ready()
	var qa = r["data"].get("quests", {})
	_check_true("Quests nach Neuanmeldung: 5678, 5679 und 5680 erledigt (%s)" % str(qa.get("done")),
		5678 in qa.get("done", []) and 5679 in qa.get("done", []) and 5680 in qa.get("done", []))
	var sk: Dictionary = r["data"].get("skills", {})
	_check_true("Schnellleisten und neue Fertigkeiten nach Neuanmeldung (%s, neu %s)" % [str(sk.get("shortcuts")), str(sk.get("new"))],
		sk.get("shortcuts", []).has([0, 0, 122]) and sk.get("shortcuts", []).has([1, 9, 1581]) and sk.get("shortcuts", []).size() == 2
		and sk.get("new", []) == [1581])
	await c.world_leave()
	c.close()
	d.close()

# Fertigkeiten des neuen Kriegers: Startfertigkeiten aus der Startvorlage (neu), Stadtportal, Schnellleisten
func _skills(c: Session, data: Dictionary) -> void:
	var st: Dictionary = data.get("skills", {})
	var known = st.get("skills", []).map(func(e): return int(e[0]))
	var fresh: Array = st.get("new", [])
	_check_true("Fertigkeiten: Hieb 122, Überfall 1581, Stadtportal 120; neu 122 und 1581, Leisten leer (%s, neu %s)" % [str(known), str(fresh)],
		known.has(122) and known.has(1581) and known.has(120) and fresh.has(122) and fresh.has(1581) and not fresh.has(120)
		and st.get("shortcuts", [1]).is_empty())
	_check("Hieb auf die Leiste unten, Platz 1", await c.shortcut(0, 0, 122), Proto.Code.OK)
	_check("Überfall auf die Leiste rechts, Platz 10", await c.shortcut(1, 9, 1581), Proto.Code.OK)
	_check("Stadtportal auf Platz 6", await c.shortcut(0, 5, 120), Proto.Code.OK)
	_check("Platz 6 wieder leeren", await c.shortcut(0, 5, 0), Proto.Code.OK)
	_check("fremde Fertigkeit (Feuerball 154)", await c.shortcut(0, 1, 154), Proto.Code.SKILL_UNKNOWN)
	_check("Leiste 3 gibt es nicht", await c.shortcut(2, 0, 122), Proto.Code.SHORTCUT_INVALID)
	_check("Platz 11 gibt es nicht", await c.shortcut(0, 10, 122), Proto.Code.SHORTCUT_INVALID)
	var r = await c.skill_seen([122])
	_check_true("Hieb aus 'Neue Fertigkeiten' weggelegt, Überfall bleibt neu (%s)" % str(r["data"].get("new")),
		r["code"] == Proto.Code.OK and r["data"].get("new", []) == [1581])
	var info: Dictionary = st.get("info", {})
	var hieb: Dictionary = info.get("122", {})
	_check_true("Werte von Hieb: 18 Mana, 1 s Zauberzeit, 3 s Abklingzeit, Aktion 战士_斩击, einsetzbar (%s)" % str(hieb),
		hieb.get("mp") == 18 and hieb.get("time") == 1000 and hieb.get("cool") == 3000 and hieb.get("act") == "战士_斩击"
		and hieb.get("usable") == true and hieb.get("type") == 1)
	_check_true("Überfall und Stadtportal noch nicht einsetzbar (%s, %s)" % [str(info.get("1581", {}).get("usable")),
		str(info.get("120", {}).get("usable"))], info.get("1581", {}).get("usable") == false and info.get("120", {}).get("usable") == false)

# Statuseffekte (Fertigkeiten-Fahrplan F3): ein Magier setzt Feuerball auf Wildschweine, bis Brennen (583, 50 %)
# liegt: Meldung buffs mit 583 am Wildschwein, Ziel-Info mit dem Effekt, Schaden über Zeit (hit mit buff 583, 30 je
# Tick vom Magier); der Feuerball lässt dem Wildschwein nur wenige HP, tötet der Brand, bekommt der Magier den
# Abschuss (kill), sonst endet der Effekt nach 5 s (leere Liste)
func _burn() -> void:
	var m = _session("M")
	var pw = _random_password()
	var acc = "Mb_%06d" % (randi() % 1000000)
	await m.register(acc, pw)
	await m.login(acc, pw)
	var r = await m.create_char("Mg%06d" % (randi() % 1000000), 1, 5, 0, LOOK)
	var cid = int(r["data"].get("char", {}).get("id", 0))
	var pushes = []
	m.net.pushed.connect(func(what, data): pushes.append([what, data]))
	r = await m.enter_char(cid)
	var start: Array = r["data"].get("pos", [0, 0, 0])
	var at = Vector3(start[0], start[1], start[2])
	r = await m.world_ready()
	_check("Magier betritt s9", r, Proto.Code.OK)
	var me = int(r["data"].get("id", 0))
	_check_true("Feuerball (154) einsetzbar (%s)" % str(r["data"].get("skills", {}).get("info", {}).get("154", {}).get("usable")),
		r["data"].get("skills", {}).get("info", {}).get("154", {}).get("usable") == true)
	await _until(func(): return _npcs(pushes).values().any(func(n): return n["tid"] == BOAR), 5.0)
	var burned = 0
	var tries = 0
	var has_burn = func(d: Dictionary) -> bool: return d.get("list", []).any(func(e): return int(e[0]) == 583 and e.size() > 4 and int(e[4]) == 8)
	while burned == 0 and tries < 14: # Erfolg je Versuch knapp 50 % (Brennen, und der Feuerball tötet nicht)
		var nc = _npcs(pushes)
		var boar = 0
		var best = INF
		for id in nc:
			if nc[id]["tid"] == BOAR and nc[id]["at"].distance_to(at) < best:
				best = nc[id]["at"].distance_to(at)
				boar = id
		if boar == 0:
			break
		tries += 1
		at = await _walk(m, at, _npc_at(pushes, boar))
		var n0 = pushes.size()
		r = await m.skill_cast(154, boar)
		if r["code"] != Proto.Code.OK:
			_say("Feuerball %d: %s" % [tries, Proto.text(r["code"])])
			await get_tree().create_timer(1.0).timeout
			continue
		await _until(func(): return pushes.slice(n0).any(func(e): return e[0] == "skill_end" and e[1]["src"] == me), 3.0)
		await get_tree().create_timer(0.3).timeout
		var died = pushes.slice(n0).any(func(e): return e[0] == "npc_leave" and e[1]["die"] and boar in e[1]["ids"])
		if pushes.slice(n0).any(func(e): return e[0] == "buffs" and int(e[1]["id"]) == boar and has_burn.call(e[1])) and not died:
			burned = boar # (tötet schon der Feuerball - Krit -, zählt es nicht: kein Brand-Tick mehr)
		else:
			await get_tree().create_timer(4.0).timeout # Abklingzeit
	_check_true("Brennen (583, Sichtbar-Index 8) liegt nach %d Feuerbällen an einem Wildschwein" % tries, burned != 0)
	if burned != 0:
		var t = await m.select_target(burned)
		var dead_now = func(): return pushes.any(func(e): return e[0] == "npc_leave" and e[1]["die"] and burned in e[1]["ids"])
		_check_true("Ziel-Info enthält Brennen (%s)" % str(t["data"].get("buffs")), dead_now.call()
			or (t["code"] == Proto.Code.OK and t["data"].get("buffs", []).any(func(e): return int(e[0]) == 583)))
		var dot = func(): return pushes.any(func(e): return e[0] == "hit" and int(e[1].get("buff", 0)) == 583 and e[1]["dst"] == burned)
		await _until(dot, 2.5)
		var h = {}
		for e in pushes:
			if e[0] == "hit" and int(e[1].get("buff", 0)) == 583 and e[1]["dst"] == burned:
				h = e[1]
				break
		_check_true("Schaden über Zeit: %s je Tick vom Magier (hit mit buff 583)" % str(h.get("dmg")), int(h.get("dmg", 0)) == 30
			and int(h.get("src", 0)) == me)
		await get_tree().create_timer(0.5).timeout
		if dead_now.call():
			await _until(func(): return pushes.any(func(e): return e[0] == "kill" and e[1]["id"] == burned), 2.0)
			_check_true("der Brand tötet das Wildschwein (Tick vor dem Tod), Abschuss für den Magier (kill)", not h.is_empty()
				and pushes.any(func(e): return e[0] == "kill" and e[1]["id"] == burned))
		else:
			var ended = func(): return pushes.any(func(e): return e[0] == "buffs" and int(e[1]["id"]) == burned and e[1]["list"].is_empty())
			await _until(ended, 6.0)
			_check_true("Brennen endet nach 5 s (leere Liste)", ended.call())
	await m.world_leave()
	await m.logout()
	m.close()

# Für jede Rasse / Klasse eine Figur anlegen, betreten: läuft ihre Einstiegsquest? (danach gelöscht)
func _start_quests() -> void:
	var s = _session("E")
	var pw = _random_password()
	var acc = "Sq_%06d" % (randi() % 1000000)
	await s.register(acc, pw)
	await s.login(acc, pw)
	var wrong = []
	var wolves = []
	for key in START_QUESTS:
		var rc = key.split("_")
		var char_name = "Sq%06d" % (randi() % 1000000)
		var r = await s.create_char(char_name, int(rc[0]), int(rc[1]), 0, LOOK)
		if r["code"] == Proto.Code.CLASS_CLOSED:
			r = await s.create_char(char_name, int(rc[0]), int(rc[1]), 1, LOOK)
		if r["code"] != Proto.Code.OK:
			wrong.append("%s: anlegen %d" % [key, r["code"]])
			continue
		var id = int(r["data"]["char"]["id"])
		await s.enter_char(id)
		r = await s.world_ready()
		var active = r["data"].get("quests", {}).get("active", []).map(func(e): return int(e[0]))
		if not START_QUESTS[key] in active:
			wrong.append("%s: %s" % [key, str(active)])
		if rc[0] == "6":
			wolves.append("%s %s" % [key, str(active)])
		await s.world_leave()
		await s.delete_char(id)
	_check_true("Werwolf-Assassine und -Priester bekommen 15356 'Andere Welt' (%s)" % ", ".join(wolves), wolves.size() == 2
		and wolves.all(func(w): return w.contains("15356")))
	_check_true("jede der %d Rassen / Klassen bekommt ihre Startquest%s" % [START_QUESTS.size(), (" - FEHLT: " + "; ".join(wrong)) if not wrong.is_empty() else ""],
		wrong.is_empty())
	await s.logout()
	s.close()

# Kampf: Quest 5680 (zehn Wildschweine, Beute), Treffer, Gegenangriff, Tod, EXP, Abschluss
func _combat(c: Session, pushes: Array, me: int, at: Vector3) -> Vector3:
	var nc = _npcs(pushes)
	var vestry = 0
	var johnny = 0
	for id in nc:
		if nc[id]["tid"] == VESTRY:
			vestry = id
		elif nc[id]["tid"] == JOHNNY:
			johnny = id
	var r = await c.attack(vestry)
	_check("NPC angreifen", r, Proto.Code.ATTACK_INVALID)
	r = await c.attack(123)
	_check("Unbekanntes angreifen", r, Proto.Code.ATTACK_INVALID)
	r = await c.revive()
	_check("lebend wiederbeleben", r, Proto.Code.NOT_DEAD)
	await get_tree().create_timer(0.5).timeout # 5893 (Warten) endet im nächsten Takt
	r = await c.quest_accept(johnny, 5680)
	_check("Quest 5680 'Wetzt Eure Knochen' bei Johnny", r, Proto.Code.OK)
	var bag = func(id: int) -> int:
		for i in range(pushes.size() - 1, -1, -1):
			if pushes[i][0] == "inventory":
				var n = 0
				for e in pushes[i][1].get("bag", []):
					if e[1] == id:
						n += e[2]
				return n
		return 0
	var first = true # erster Treffer geprüft? (stirbt das Wildschwein am ersten Schlag - Krit -, ...
	var back_checked = false # ... prüft das nächste den Gegenangriff)
	var kills = 0
	var exp_ok = true
	for k in 10:
		var boar = 0
		var best = INF
		nc = _npcs(pushes)
		for id in nc:
			if nc[id]["tid"] == BOAR and nc[id]["at"].distance_to(at) < best:
				best = nc[id]["at"].distance_to(at)
				boar = id
		if boar == 0:
			break
		at = await _walk(c, at, _npc_at(pushes, boar))
		r = await c.attack(boar)
		if first:
			_check_true("Wildschwein angreifen (Takt %s s, Reichweite %s m)" % [r["data"].get("interval"), r["data"].get("range")],
				r["code"] == Proto.Code.OK and r["data"].get("range") == 4.5)
			var hit = func(): return pushes.any(func(e): return e[0] == "hit" and e[1]["src"] == me and e[1]["dst"] == boar)
			await _until(hit, 5.0)
			var h = {}
			for e in pushes:
				if e[0] == "hit" and e[1]["src"] == me and e[1]["dst"] == boar:
					h = e[1]
			_check_true("Treffer: %s Schaden, Wildschwein %s / %s HP" % [h.get("dmg"), h.get("hp"), h.get("max_hp")], hit.call()
				and int(h.get("max_hp", 0)) == 426 and int(h.get("hp", -1)) == maxi(0, 426 - int(h.get("dmg", 0))) and int(h.get("dmg", 0)) >= 1)
			first = false
		if not back_checked and pushes.any(func(e): return e[0] == "hit" and e[1]["src"] == me and e[1]["dst"] == boar and e[1]["hp"] > 0):
			await c.attack_stop()
			var back = func(): return pushes.any(func(e): return e[0] == "hit" and e[1]["src"] == boar and e[1]["dst"] == me)
			_check_true("das Wildschwein schlägt zurück", await _until(back, 6.0))
			back_checked = true
			r = await c.attack(boar)
		var died = func(): return pushes.any(func(e): return e[0] == "npc_leave" and e[1]["die"] and boar in e[1]["ids"])
		await _until(died, 12.0)
		if not died.call():
			break
		kills += 1
		var kp = func(): return pushes.any(func(e): return e[0] == "kill" and e[1]["id"] == boar)
		await _until(kp, 2.0)
		for e in pushes:
			if e[0] == "kill" and e[1]["id"] == boar and e[1]["exp"] != 6:
				exp_ok = false
	_check_true("zehn Wildschweine besiegt (%d), je 6 EXP, Beute 14533 x%d" % [kills, bag.call(BOAR_LOOT)], kills == 10 and exp_ok
		and bag.call(BOAR_LOOT) == 10)
	at = await _walk(c, at, _npc_at(pushes, vestry))
	r = await c.quest_complete(vestry, 5680)
	_check("5680 bei Lady Vestry abschließen", r, Proto.Code.OK)
	var done = func(): return pushes.any(func(e): return e[0] == "quest_event" and e[1]["id"] == 5680 and e[1]["kind"] == "done")
	await _until(done, 3.0)
	var ev = {}
	for e in pushes:
		if e[0] == "quest_event" and e[1]["id"] == 5680 and e[1]["kind"] == "done":
			ev = e[1]
	await get_tree().create_timer(0.3).timeout
	_check_true("5680 erfüllt: 100 EXP, vier Gegenstände, Beute eingezogen (%s, Beute %d)" % [str(ev), bag.call(BOAR_LOOT)],
		ev.get("exp") == 100 and ev.get("items", []).size() == 4 and bag.call(BOAR_LOOT) == 0)
	at = await _cast(c, pushes, me, at)
	for e in pushes:
		if e[0] == "stats":
			_last_stats = e[1]
	return at

# Fertigkeiten einsetzen (Fertigkeiten-Fahrplan F2): fremde / noch nicht umgesetzte Fertigkeit, Ziel NPC, zu
# weit; Hieb auf ein Wildschwein: erst durch Bewegen abgebrochen (keine Wirkung), dann Zauberzeit 1 s,
# Treffer mit skill nach dem Zaubern, 18 Mana weg, Abklingzeit 3 s (gleich danach abgewiesen)
func _cast(c: Session, pushes: Array, me: int, at: Vector3) -> Vector3:
	var nc = _npcs(pushes)
	var boar = 0
	var vestry = 0
	var best = INF
	for id in nc:
		if nc[id]["tid"] == VESTRY:
			vestry = id
		elif nc[id]["tid"] == BOAR and nc[id]["at"].distance_to(at) < best:
			best = nc[id]["at"].distance_to(at)
			boar = id
	_check_true("Wildschwein für die Fertigkeit gefunden", boar != 0)
	if boar == 0:
		return at
	_check("Feuerball (unbekannt) einsetzen", await c.skill_cast(154, boar), Proto.Code.SKILL_UNKNOWN)
	_check("Überfall (noch nicht umgesetzt) einsetzen", await c.skill_cast(1581, boar), Proto.Code.SKILL_NOT_YET)
	_check("Hieb auf Lady Vestry", await c.skill_cast(122, vestry), Proto.Code.NO_TARGET)
	if _npc_at(pushes, boar).distance_to(at) > 8.0:
		_check("Hieb aus %d m" % int(_npc_at(pushes, boar).distance_to(at)), await c.skill_cast(122, boar), Proto.Code.OUT_OF_RANGE)
	at = await _walk(c, at, _npc_at(pushes, boar))
	var since = func(from: int, what: String, cond: Callable) -> Dictionary:
		for i in range(from, pushes.size()):
			if pushes[i][0] == what and cond.call(pushes[i][1]):
				return pushes[i][1]
		return {}
	var is_end = func(d): return d["src"] == me and d["id"] == 122
	# Abbruch: zaubern, gleich weglaufen
	var n0 = pushes.size()
	var t_cast = Time.get_ticks_msec()
	var r = await c.skill_cast(122, boar)
	var t_reply = Time.get_ticks_msec()
	var away = at + Vector3(0.6, 0, 0)
	c.send_move(away, 0.0, Proto.MOVE_RUN)
	await _until(func(): return not since.call(n0, "skill_end", is_end).is_empty(), 3.0)
	var t_end = Time.get_ticks_msec()
	await get_tree().create_timer(0.3).timeout
	c.send_move(away, 0.0, Proto.MOVE_STAND)
	at = away
	var end: Dictionary = since.call(n0, "skill_end", is_end)
	var seen = pushes.slice(n0).map(func(e): return e[0] if e[0] != "skill_end" else "skill_end %s" % str(e[1]))
	_check_true("Bewegen bricht das Zaubern ab (skill_end ok = %s, kein Treffer, keine Abklingzeit)%s" % [str(end.get("ok")),
		"" if end.get("ok") == false else " - Antwort %d nach %d ms, gewartet %d ms, Meldungen %s" % [r["code"], t_reply - t_cast,
		t_end - t_reply, str(seen)]],
		r["code"] == Proto.Code.OK and end.get("ok") == false
		and since.call(n0, "hit", func(d): return d["src"] == me and int(d.get("skill", 0)) == 122).is_empty()
		and since.call(n0, "cooldown", func(d): return d["id"] == 122).is_empty())
	# Wirkung (das Wildschwein kann inzwischen weitergewandert sein: noch einmal hin)
	at = await _walk(c, at, _npc_at(pushes, boar))
	var mp0 = _stat_of(pushes, "mp", -1)
	n0 = pushes.size()
	var t0 = Time.get_ticks_msec()
	r = await c.skill_cast(122, boar)
	_check_true("Hieb einsetzen (Zauberzeit %s ms)" % str(r["data"].get("time")), r["code"] == Proto.Code.OK and r["data"].get("time") == 1000)
	_check("während des Zauberns noch einmal", await c.skill_cast(122, boar), Proto.Code.SKILL_BUSY)
	await _until(func(): return not since.call(n0, "skill_end", is_end).is_empty(), 3.0)
	var took = Time.get_ticks_msec() - t0
	end = since.call(n0, "skill_end", is_end)
	var hit: Dictionary = since.call(n0, "hit", func(d): return d["src"] == me and d["dst"] == boar and int(d.get("skill", 0)) == 122)
	_check_true("Zaubern fertig nach %d ms (skill_end ok)" % took, end.get("ok") == true and took >= 900 and took < 2500)
	_check_true("Treffer mit Hieb nach %s ms: %s Schaden (100 %% Angriff + 242)%s" % [str(hit.get("elapsed")), str(hit.get("dmg")),
		" (verfehlt)" if hit.get("miss", false) else ""], not hit.is_empty() and int(hit.get("elapsed", 0)) >= 800
		and int(hit.get("elapsed", 0)) <= 1100 and (hit.get("miss", false) or int(hit.get("dmg", 0)) >= 200))
	var cool: Dictionary = since.call(n0, "cooldown", func(d): return d["id"] == 122)
	var mp1 = -1 # stats direkt nach der Abklingzeit (Wirkung), davor ggf. Regeneration
	for i in range(n0, pushes.size()):
		if pushes[i][0] == "cooldown" and pushes[i][1]["id"] == 122:
			for j in range(i + 1, pushes.size()):
				if pushes[j][0] == "stats" and pushes[j][1].has("mp"):
					mp1 = int(pushes[j][1]["mp"])
					break
			break
		if pushes[i][0] == "stats" and pushes[i][1].has("mp"):
			mp0 = int(pushes[i][1]["mp"])
	_check_true("Abklingzeit 3000 ms, Mana %d -> %d" % [mp0, mp1], cool.get("ms") == 3000 and mp0 >= 18 and mp1 == mp0 - 18)
	_check("Hieb gleich wieder (Abklingzeit)", await c.skill_cast(122, boar), Proto.Code.SKILL_COOLDOWN)
	await c.attack_stop()
	return at

# Letzter Wert aus den stats-Meldungen
func _stat_of(pushes: Array, key: String, default):
	for i in range(pushes.size() - 1, -1, -1):
		if pushes[i][0] == "stats" and pushes[i][1].has(key):
			return pushes[i][1][key]
	return default

# Tod und Wiederbeleben: D lockt drei Giftjagdhunde an
func _death(d: Session, pushes: Array, me: int, start: Vector3) -> void:
	var at = await _walk(d, start, HOUNDS_AT)
	await get_tree().create_timer(0.5).timeout
	var hounds = []
	var nc = _npcs(pushes)
	var ids = nc.keys().filter(func(id): return nc[id]["tid"] == HOUND)
	ids.sort_custom(func(a, b): return nc[a]["at"].distance_to(at) < nc[b]["at"].distance_to(at))
	for id in ids.slice(0, 3):
		at = await _walk(d, at, _npc_at(pushes, id))
		await d.attack(id)
		var hit = func(): return pushes.any(func(e): return e[0] == "hit" and e[1]["src"] == me and e[1]["dst"] == id)
		await _until(hit, 5.0)
		await d.attack_stop()
		hounds.append(id)
	var dead = func(): return pushes.any(func(e): return e[0] == "die" and e[1]["id"] == me)
	_check_true("D lockt %d Giftjagdhunde an und stirbt (die)" % hounds.size(), await _until(dead, 60.0))
	var r = await d.attack(hounds[0] if not hounds.is_empty() else 0)
	_check("tot angreifen", r, Proto.Code.YOU_ARE_DEAD)
	d.send_move(at + Vector3(3, 0, 0), 0.0, Proto.MOVE_RUN)
	var corrected = func(): return pushes.any(func(e): return e[0] == "pos_correct")
	_check_true("tot laufen (pos_correct)", await _until(corrected, 3.0))
	r = await d.revive()
	var pos: Array = r["data"].get("pos", [0, 0, 0])
	await get_tree().create_timer(0.3).timeout
	var st = {}
	for e in pushes:
		if e[0] == "stats":
			st = e[1]
	_check_true("wiederbelebt am Wiederbelebungspunkt mit 10 %% HP (%s, %s / %s)" % [str(pos), st.get("hp"), st.get("max_hp")],
		r["code"] == Proto.Code.OK and Vector3(pos[0], pos[1], pos[2]).distance_to(REVIVE_AT) < 0.1
		and absi(int(st.get("hp", 0)) - int(int(st.get("max_hp", 0)) * 0.1 + 0.5)) <= 5) # Regeneration (1 / s im Kampf)
	r = await d.revive()
	_check("nochmal wiederbeleben", r, Proto.Code.NOT_DEAD)

# Meldung player_equip der Figur id mit Schwert und Rüstung?
func _full_equip(e: Array, id: int) -> bool:
	return e[0] == "player_equip" and e[1]["id"] == id and e[1]["equip"].has([0, SWORD]) and e[1]["equip"].has([3, ARMOR])

# Ziel wählen und Chat "Sagen" (C und D stehen beide am Start von s9)
func _target_and_chat(c: Session, d: Session, ids: Array, nc: Dictionary, pushes_c: Array, pushes_d: Array) -> void:
	var vestry_id = 0
	for id in nc:
		if nc[id]["tid"] == VESTRY:
			vestry_id = id
	var r = await c.select_target(vestry_id)
	var t: Dictionary = r["data"]
	_check("Ziel Lady Vestry", r, Proto.Code.OK)
	_check_true("Ziel-Info NPC: Vorlage, Stufe, volle HP (%s, Stufe %s, %s / %s)" % [t.get("kind"), t.get("level"), t.get("hp"), t.get("max_hp")],
		t.get("kind") == "npc" and t.get("tid") == VESTRY and int(t.get("level", 0)) > 0 and int(t.get("max_hp", 0)) > 0
		and t.get("hp") == t.get("max_hp"))
	var monster = {}
	for id in nc:
		if nc[id]["tid"] != VESTRY:
			r = await c.select_target(id)
			if r["data"].get("kind") == "monster":
				monster = r["data"]
				break
	_check_true("Ziel Monster (%s, Stufe %s, %s HP)" % [monster.get("tid"), monster.get("level"), monster.get("max_hp")],
		int(monster.get("max_hp", 0)) > 0 and monster.get("hp") == monster.get("max_hp"))
	r = await c.select_target(ids[1])
	t = r["data"]
	_check_true("Ziel Spieler D: Name, Priesterin Stufe 1 mit 920 HP (%s, %s)" % [t.get("name"), t.get("max_hp")],
		r["code"] == Proto.Code.OK and t.get("kind") == "player" and t.get("class") == 6 and t.get("max_hp") == 920)
	r = await c.select_target(ids[0])
	_check("Ziel: sich selbst", r, Proto.Code.OK)
	r = await c.select_target(123456789)
	_check("Ziel: unbekannte Figur", r, Proto.Code.TARGET_INVALID)
	r = await c.select_target(Proto.NPC_ID_BASE + 99999999)
	_check("Ziel: unbekannter NPC", r, Proto.Code.TARGET_INVALID)
	r = await c.select_target(0)
	_check_true("Ziel abwählen", r["code"] == Proto.Code.OK and r["data"].get("id") == 0)
	# Chat
	var heard = func(list: Array, text: String): return list.any(func(e): return e[0] == "chat" and e[1]["text"] == text and e[1]["id"] == ids[0])
	r = await c.say("Hallo D, hier ist C!")
	_check("C sagt etwas", r, Proto.Code.OK)
	_check_true("D hört C (chat)", await _until(func(): return heard.call(pushes_d, "Hallo D, hier ist C!"), 3.0))
	_check_true("C hört sich selbst", await _until(func(): return heard.call(pushes_c, "Hallo D, hier ist C!"), 3.0))
	r = await c.say("du Arschloch")
	_check_true("Wortfilter ersetzt durch *", r["code"] == Proto.Code.OK and await _until(func(): return heard.call(pushes_d, "du *********"), 3.0))
	r = await c.say("x".repeat(Proto.CHAT_MAX + 1))
	_check("Nachricht zu lang", r, Proto.Code.CHAT_INVALID)
	r = await c.say("   ")
	_check("Nachricht leer", r, Proto.Code.CHAT_INVALID)
	r = await c.say("Gilde?", 3)
	_check("anderer Kanal", r, Proto.Code.CHAT_INVALID)
	var codes = []
	for i in Proto.CHAT_BURST:
		codes.append((await c.say("Nr. %d" % i))["code"])
	_check_true("Flutbremse (%s)" % str(codes), Proto.Code.CHAT_TOO_FAST in codes)

# Erste Menschen-Quest mit C (Krieger) -> Position am Ende
func _quests(c: Session, q: Dictionary, pushes: Array, start: Vector3) -> Vector3:
	var active = func(st: Dictionary): return st.get("active", []).map(func(e): return e[0])
	_check_true("5678 automatisch vergeben, Teil 5699 läuft (%s)" % str(active.call(q)), 5678 in active.call(q) and 5699 in active.call(q))
	_check_true("Meldung: neue Quest 5678", pushes.any(func(e): return e[0] == "quest_event" and e[1]["id"] == 5678 and e[1]["kind"] == "new"))
	var nc = _npcs(pushes)
	var vestry = 0
	var adam = 0
	for id in nc:
		if nc[id]["tid"] == VESTRY:
			vestry = id
		elif nc[id]["tid"] == ADAM:
			adam = id
	_check_true("Lady Vestry und Adam in Sicht", vestry != 0 and adam != 0)
	var last_state = func():
		for i in range(pushes.size() - 1, -1, -1):
			if pushes[i][0] == "quests":
				return pushes[i][1]
		return q
	var r = await c.quest_complete(adam, 5699)
	_check("5699 bei Adam (falscher NPC, zu weit)", r, Proto.Code.QUEST_NOT_HERE)
	r = await c.quest_accept(vestry, 5679)
	_check("Folgequest 5679 zu früh", r, Proto.Code.QUEST_CONDITIONS)
	r = await c.quest_complete(vestry, 5700)
	_check("5700 noch nicht dran", r, Proto.Code.QUEST_NOT_ACTIVE)
	r = await c.quest_complete(vestry, 99999)
	_check("unbekannte Quest", r, Proto.Code.QUEST_INVALID)
	r = await c.quest_complete(vestry, 5699)
	_check("Teil 1 'Aufwachen' bei Lady Vestry", r, Proto.Code.OK)
	await _until(func(): return 5700 in active.call(last_state.call()), 3.0)
	_check_true("Teil 2 'Was ist passiert?' läuft", 5700 in active.call(last_state.call()) and not 5699 in active.call(last_state.call()))
	r = await c.quest_complete(vestry, 5700)
	_check("Teil 2 bei Lady Vestry (gehört zu Adam)", r, Proto.Code.QUEST_NOT_HERE)
	var at = await _walk(c, start, _npc_at(pushes, adam))
	r = await c.quest_complete(adam, 5700)
	_check("Teil 2 bei Adam", r, Proto.Code.OK)
	at = await _walk(c, at, _npc_at(pushes, vestry))
	r = await c.quest_complete(vestry, 5701)
	_check("Teil 3 'Kleiner Trost' bei Lady Vestry", r, Proto.Code.OK)
	var done = func(): return pushes.any(func(e): return e[0] == "quest_event" and e[1]["id"] == 5678 and e[1]["kind"] == "done")
	await _until(done, 3.0)
	var ev = {}
	for e in pushes:
		if e[0] == "quest_event" and e[1]["id"] == 5678 and e[1]["kind"] == "done":
			ev = e[1]
	_check_true("5678 erfüllt: 40 EXP und Rüstung 15613 (%s)" % str(ev), ev.get("exp") == 40 and not ev.get("items", []).is_empty()
		and ev["items"][0][0] == 15613)
	var st = {}
	for e in pushes:
		if e[0] == "stats":
			st = e[1]
	_check_true("Werte: Stufe 1, 40 / 70 EXP (%s)" % str(st), st.get("level") == 1 and st.get("exp") == 40 and st.get("exp_next") == 70)
	r = await c.quest_accept(vestry, 5679)
	_check("Folgequest 5679 'Greift zu den Waffen!' bei Lady Vestry", r, Proto.Code.OK)
	await _until(func(): return 7994 in active.call(last_state.call()), 3.0)
	_check_true("5679 mit erstem Teil 7994 läuft, 5678 erledigt", 7994 in active.call(last_state.call())
		and 5678 in last_state.call().get("done", []))
	r = await c.quest_accept(vestry, 5679)
	_check("5679 nicht doppelt", r, Proto.Code.QUEST_CONDITIONS)
	r = await c.quest_abandon(5679)
	_check("5679 nicht aufgebbar", r, Proto.Code.QUEST_NO_GIVEUP)
	return await _weapon(c, pushes, at)

# Inventar und Waffen-Quest: Rüstung anlegen, Johnny, Waffenregal, Schwert anlegen, 5679 abschließen
func _weapon(c: Session, pushes: Array, at: Vector3) -> Vector3:
	var active = func():
		for i in range(pushes.size() - 1, -1, -1):
			if pushes[i][0] == "quests":
				return pushes[i][1].get("active", []).map(func(e): return e[0])
		return []
	var inv = func():
		for i in range(pushes.size() - 1, -1, -1):
			if pushes[i][0] == "inventory":
				return pushes[i][1]
		return {}
	var stats = func():
		for i in range(pushes.size() - 1, -1, -1):
			if pushes[i][0] == "stats":
				return pushes[i][1]
		return {}
	var bag_pos = func(id: int) -> int:
		for e in inv.call().get("bag", []):
			if e[1] == id:
				return e[0]
		return -1
	_check_true("Rüstung 15613 in der Tasche (%s)" % str(inv.call()), bag_pos.call(ARMOR) >= 0)
	var r = await c.equip(23)
	_check("leeren Platz anlegen", r, Proto.Code.ITEM_INVALID)
	r = await c.equip(bag_pos.call(ARMOR))
	_check("Rüstung anlegen (Platz 3)", r, Proto.Code.OK)
	await _until(func(): return inv.call().get("equip", []).has([3, ARMOR]), 3.0)
	var st: Dictionary = stats.call()
	_check_true("mit Rüstung: 561 MP, Verteidigung 94 (%s / %s)" % [st.get("max_mp"), st.get("attr", {}).get("def")],
		st.get("max_mp") == 561 and st.get("attr", {}).get("def") == 94 and inv.call().get("bag", [1]).is_empty())
	var nc = _npcs(pushes)
	var johnny = 0
	var rack = 0
	var rack_mage = 0
	for id in nc:
		match nc[id]["tid"]:
			JOHNNY:
				johnny = id
			RACK:
				rack = id
			RACK_MAGE:
				rack_mage = id
	_check_true("Johnny und die Waffenregale in Sicht (npc_enter)", johnny != 0 and rack != 0 and rack_mage != 0)
	r = await c.gather(rack)
	_check("Waffenregal von weitem", r, Proto.Code.GATHER_TOO_FAR)
	at = await _walk(c, at, _npc_at(pushes, johnny))
	r = await c.quest_complete(johnny, 7994)
	_check("5679 Teil 7994 bei Johnny", r, Proto.Code.OK)
	await _until(func(): return 8366 in active.call(), 3.0)
	_check_true("Teil 8366 'Zweihandschwert' läuft", 8366 in active.call())
	at = await _walk(c, at, _npc_at(pushes, rack_mage))
	r = await c.gather(rack_mage)
	_check("Magier-Regal ohne seine Quest", r, Proto.Code.GATHER_NO_TASK)
	at = await _walk(c, at, _npc_at(pushes, rack))
	r = await c.gather(rack)
	_check_true("Waffenregal: sammeln %s s" % str(r["data"].get("time")), r["code"] == Proto.Code.OK and r["data"].get("time", 0) >= 3)
	var r2 = await c.gather(rack)
	_check("zweimal zugleich sammeln", r2, Proto.Code.GATHER_BUSY)
	var ended = func(): return pushes.any(func(e): return e[0] == "gather_end" and e[1]["id"] == rack)
	await _until(ended, 8.0)
	var ge = {}
	for e in pushes:
		if e[0] == "gather_end" and e[1]["id"] == rack:
			ge = e[1]
	_check_true("gesammelt: Schwert 15612 (%s)" % str(ge), ge.get("ok", false) and ge.get("items", []).has([SWORD, 1]))
	await _until(func(): return 7997 in active.call(), 3.0)
	_check_true("Schwert in der Tasche, 8366 erfüllt, 7997 läuft", bag_pos.call(SWORD) >= 0 and 7997 in active.call() and not 8366 in active.call())
	r = await c.equip(bag_pos.call(SWORD))
	_check("Schwert anlegen (Platz 0)", r, Proto.Code.OK)
	await _until(func(): return inv.call().get("equip", []).has([0, SWORD]), 3.0)
	st = stats.call()
	_check_true("mit Schwert: 1674 HP, Angriff 296 - 316 (%s / %s)" % [st.get("max_hp"), st.get("attr", {}).get("dmg")],
		st.get("max_hp") == 1674 and st.get("attr", {}).get("dmg") == [296, 316])
	r = await c.unequip(0, 5)
	_check_true("Schwert ablegen an Taschenplatz 5 (%s)" % str(r["data"]), r["code"] == Proto.Code.OK and r["data"].get("pos") == 5)
	await _until(func(): return bag_pos.call(SWORD) == 5, 3.0)
	r = await c.move_item(5, 9)
	_check("Schwert auf Platz 9 verschieben", r, Proto.Code.OK)
	await _until(func(): return bag_pos.call(SWORD) == 9, 3.0)
	r = await c.move_item(5, 9)
	_check("leeren Platz verschieben", r, Proto.Code.ITEM_INVALID)
	r = await c.unequip(0)
	_check("leeren Platz ablegen", r, Proto.Code.ITEM_INVALID)
	r = await c.equip(9)
	_check("Schwert wieder anlegen", r, Proto.Code.OK)
	at = await _walk(c, at, _npc_at(pushes, johnny))
	r = await c.quest_complete(johnny, 7997)
	_check("7997 'Eine passende Waffe' bei Johnny", r, Proto.Code.OK)
	var done = func(): return pushes.any(func(e): return e[0] == "quest_event" and e[1]["id"] == 5679 and e[1]["kind"] == "done")
	await _until(done, 3.0)
	st = stats.call()
	_check_true("5679 erfüllt: Stufe 2, 10 / %s EXP, volle HP %s" % [st.get("exp_next"), st.get("max_hp")], done.call()
		and st.get("level") == 2 and st.get("exp") == 10 and st.get("hp") == st.get("max_hp") and st.get("max_hp") > 1674)
	return at

# Ort eines NPCs nach den Meldungen (Ziel, wenn er läuft)
func _npc_at(pushes: Array, id: int) -> Vector3:
	var n = _npcs(pushes).get(id, {})
	return n.get("at", Vector3.ZERO)

# In Schritten von 1,5 m je 0,1 s bis 2 m vor das Ziel laufen (der Server prüft das Tempo) -> Ende
func _walk(s: Session, from: Vector3, to: Vector3) -> Vector3:
	var d = to - from
	var flat = Vector2(d.x, d.z)
	var goal = to - Vector3(flat.normalized().x, 0, flat.normalized().y) * 2.0 if flat.length() > 2.0 else from
	var steps = maxi(1, ceili(from.distance_to(goal) / 1.5))
	var p = from
	for i in steps:
		p = from.lerp(goal, float(i + 1) / steps)
		s.send_move(p, atan2(d.x, d.z), Proto.MOVE_RUN)
		await get_tree().create_timer(0.1).timeout
	s.send_move(p, atan2(d.x, d.z), Proto.MOVE_STAND)
	await get_tree().create_timer(0.2).timeout
	return p

# "Dauerheld" (Priesterin, Quest 5965): erster Lauf schließt Teil 5972 ab, nach Neustart läuft 5973
func _keep_quest(b: Session, char_id: int) -> void:
	var pushes = []
	b.net.pushed.connect(func(what, data): pushes.append([what, data]))
	var r = await b.enter_char(char_id)
	r = await b.world_ready()
	_check("%s betritt die Welt" % KEEP_CHAR, r, Proto.Code.OK)
	var q: Dictionary = r["data"].get("quests", {})
	var active = q.get("active", []).map(func(e): return e[0])
	if expect_existing:
		_check_true("nach Neustart: 5965 läuft, Teil 5973 dran (%s)" % str(active), 5965 in active and 5973 in active and not 5972 in active)
	else:
		await _until(func(): return _npcs(pushes).values().any(func(n): return n["tid"] == VESTRY), 3.0)
		var vestry = 0
		for id in _npcs(pushes):
			if _npcs(pushes)[id]["tid"] == VESTRY:
				vestry = id
		if 5972 in active:
			r = await b.quest_complete(vestry, 5972)
			_check("%s: Teil 5972 bei Lady Vestry" % KEEP_CHAR, r, Proto.Code.OK)
		else:
			_check_true("%s: 5965 schon weiter (%s)" % [KEEP_CHAR, str(active)], 5965 in active and 5973 in active)
	await b.world_leave()

# NPC-Meldungen einer Sitzung nachspielen -> {ID: {tid, level, at}} (at = Ziel, wenn sie läuft)
func _npcs(pushes: Array) -> Dictionary:
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

# Figuren eines frisch angelegten Kontos
func _characters(s: Session) -> void:
	var r = await s.list_chars()
	_check("Figurenliste leer", r, Proto.Code.OK)
	_check_true("8 Plätze, keine Figur", r["data"].get("max") == 8 and r["data"].get("chars", [1]).is_empty())
	var hero = "Held%04d" % (randi() % 10000)
	r = await s.create_char("x", 1, 1, 0, LOOK)
	_check("Name zu kurz", r, Proto.Code.CHAR_NAME_INVALID)
	r = await s.create_char("1" + hero, 1, 1, 0, LOOK)
	_check("Name mit Ziffer vorn", r, Proto.Code.CHAR_NAME_INVALID)
	r = await s.create_char("Arschloch", 1, 1, 0, LOOK)
	_check("Name aus der Wortliste", r, Proto.Code.CHAR_NAME_INVALID)
	r = await s.create_char(hero, 3, 1, 0, LOOK)
	_check("Zwerg-Krieger (keine Vorlage)", r, Proto.Code.CLASS_CLOSED)
	r = await s.create_char(hero, 4, 2, 1, LOOK)
	_check("Steinmensch weiblich (keine Vorlage)", r, Proto.Code.CLASS_CLOSED)
	r = await s.create_char(hero, 1, 1, 0, {"face": 99})
	_check("Aussehen ungültig", r, Proto.Code.BAD_REQUEST)
	r = await s.create_char(hero, 1, 1, 0, LOOK)
	_check("Figur %s anlegen (Mensch, Krieger)" % hero, r, Proto.Code.OK)
	var c = r["data"].get("char", {})
	_check_true("Figur: Stufe 1, Map s9, Aussehen gespeichert", c.get("level") == 1 and c.get("map") == "s9"
		and c.get("appearance", {}).get("hair_color") == LOOK["hair_color"])
	r = await s.create_char(hero.to_upper(), 2, 1, 1, LOOK)
	_check("gleicher Name in Großbuchstaben", r, Proto.Code.CHAR_NAME_TAKEN)
	r = await s.list_chars()
	_check_true("Liste hat %s" % hero, r["code"] == Proto.Code.OK and r["data"]["chars"].size() == 1
		and r["data"]["chars"][0]["name"] == hero)
	r = await s.enter_char(c.get("id", 0))
	_check("Figur auswählen", r, Proto.Code.OK)
	var pos: Array = r["data"].get("pos", [])
	_check_true("Startmap s9 neben Lady Vestry", r["data"].get("map") == "s9" and pos.size() == 3
		and absf(pos[0] + 144.556) < 0.01)
	r = await s.delete_char(c.get("id", 0))
	_check("Figur löschen", r, Proto.Code.OK)
	r = await s.delete_char(c.get("id", 0))
	_check("nochmal löschen", r, Proto.Code.CHAR_NOT_FOUND)
	r = await s.list_chars()
	_check_true("Liste wieder leer", r["code"] == Proto.Code.OK and r["data"]["chars"].is_empty())


# ====================================================
# HILFEN
# ====================================================
func _session(tag: String) -> Session:
	var branch = Node.new()
	branch.name = "BotSitzung" + tag
	get_tree().root.add_child(branch)
	get_tree().set_multiplayer(SceneMultiplayer.new(), branch.get_path())
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
	s.dtls = dtls
	s.dtls_cert = dtls_cert
	game.add_child(s)
	return s

func _until(cond: Callable, seconds: float) -> bool:
	var end = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not cond.call():
		if Time.get_ticks_msec() > end:
			return false
		await get_tree().process_frame
	return true

func _check(what: String, r: Dictionary, expected: int) -> void:
	var code = int(r["code"])
	_check_true("%s -> %s" % [what, Proto.text(code)] if code == expected else
		"%s -> %s, erwartet: %s" % [what, Proto.text(code), Proto.text(expected)], code == expected)

func _check_true(what: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	_say(("ok      " if ok else "FEHLER  ") + what)

func _say(text: String) -> void:
	print("BOT: ", text)
	if _log != null:
		_log.store_line(text)
		_log.flush()

func _finish() -> void:
	if failures == 0:
		_say("BOT OK (%d Prüfungen)" % checks)
	else:
		_say("BOT FEHLER: %d von %d Prüfungen" % [failures, checks])
	get_tree().quit(0 if failures == 0 else 1)

func _abort() -> void:
	_say("BOT FEHLER: Zeitlimit %d s überschritten (%d Prüfungen bis dahin)" % [TOTAL_TIMEOUT, checks])
	get_tree().quit(2)

func _random_password() -> String:
	return "pw-" + Crypto.new().generate_random_bytes(6).hex_encode()

# Passwort des Dauer-Kontos: einmal zufällig erzeugt, in user://bot.cfg gemerkt
func _keep_password() -> String:
	var cfg = ConfigFile.new()
	cfg.load(KEEP_FILE)
	var pw = str(cfg.get_value("bot", "password", ""))
	if pw == "":
		pw = _random_password()
		cfg.set_value("bot", "password", pw)
		cfg.save(KEEP_FILE)
	return pw
