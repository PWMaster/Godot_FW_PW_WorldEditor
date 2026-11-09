extends Node

# ====================================================
# Godot-FW-Server: läuft ohne Fenster und entscheidet alles, Clients senden nur Anfragen
# (Protokoll common/protocol.gd, Nachrichten common/net.gd).
#   godot --headless --path <Projekt> res://game/main.tscn -- --server [--port=29000]
#         [--dir=user://server] [--database=<dir>/game.db] [--maps=s9,s10] [--dtls]
# bzw. als Export mit "dedicated_server". Die Leiste SERVER des Plugins startet ihn so.
# Einstellungen: Abschnitt [server] in user://settings.cfg, Kommandozeile geht vor.
# Dateien im Ordner --dir (Standard user://server/; die Tests nehmen einen eigenen):
#   server.log, status.json   Log und Zustand (Spieler online, Last) für die Leiste SERVER
#   stop                      legt die Leiste an: Server meldet "server_closing" und endet sauber
#   game.db                   Konten, Figuren ... (db.gd, schema.gd, accounts.gd)
#   dtls.key, dtls.crt        mit --dtls: Schlüssel und selbst signiertes Zertifikat (einmal erzeugt)
# Passwort-Hashes (Anlegen, Anmelden) rechnet ein Hintergrund-Thread, der Server läuft weiter.
# Last: Dauer des Welt-Takts, längstes Bild (Anfragen, Hashes fertig, Takt) und Netz-Durchsatz je
# LOAD_WINDOW s in status.json ("load"), alle LOAD_LOG s eine Zeile im Log, solange Figuren in der Welt
# sind.
# Spawns der Maps (Plugin: Server/maps.json, npcgen.gd, npc_templates.json, Höhen heightmap.gd)
# werden beim Start erzeugt (npcs.gd). Figuren, NPCs und Monster in der Welt, Bewegung und
# Sichtbereich, Ziel und Chat "Sagen": world.gd (10 Takte / s). Höchstwerte (HP / MP) und EXP-Kurve
# der Klassen: stats.gd (Plugin Server/class_templates.json). Inventar, Ausrüstung und Sammelpunkte:
# inventory.gd (Plugin Server/item_templates.json). Kampf, Monster-KI, Tod und Wiederbeleben: combat.gd.
# Fertigkeiten: bekannte und Schnellleisten skills.gd, Einsetzen skill_cast.gd (Plugin
# Server/skill_templates.json, Formeln skill_expr.gd), Statuseffekte buffs.gd (Server/state_templates.json).
# ====================================================

const Proto = preload("../common/protocol.gd")
const Settings = preload("../common/settings.gd")
const Db = preload("db.gd")
const Schema = preload("schema.gd")
const Accounts = preload("accounts.gd")
const Characters = preload("characters.gd")
const World = preload("world.gd")
const Npcs = preload("npcs.gd")
const Stats = preload("stats.gd")
const Quests = preload("quests.gd")
const Inventory = preload("inventory.gd")
const Combat = preload("combat.gd")
const Skills = preload("skills.gd")
const SkillCast = preload("skill_cast.gd")
const Buffs = preload("buffs.gd")
const PLUGIN_SERVER = "res://addons/PWE-Manager/Server/"
const SERVER_NAME = "Godot-FW-Server"
const POLL_SECONDS = 0.5
const MAX_REQUESTS_PER_SECOND = 60
const LOAD_WINDOW = 10.0 # s je Messung der Last
const LOAD_LOG = 60.0 # s zwischen den Last-Zeilen im Log
# Anfragen, die ohne "hello" bzw. ohne Anmeldung erlaubt sind
const BEFORE_HELLO = ["hello", "ping"]
const BEFORE_LOGIN = ["hello", "ping", "register", "login"]

var settings: Settings
var net: Node
var db: Db
var accounts: Accounts
var characters: Characters
var game_world: World
var stats: Stats
var inventory: Inventory
var peer: ENetMultiplayerPeer
var port = Proto.DEFAULT_PORT
var dtls = false
var dir = "user://server"
var log_file = ""
var status_file = ""
var stop_file = ""
var peers = {} # Peer -> {address, at, hello, account_id, account, since, window, requests, busy}
var online = {} # Konto-ID -> Peer
var world = {} # Map -> Zusammenfassung der Spawns (Anzahlen)
var _handlers: Dictionary
var _async_handlers: Dictionary # antworten später selbst (Hash im Hintergrund)
var _jobs = [] # laufende Hashes: {task, peer, req, what, job}
var _ticker: Timer
var _tick_us = {"sum": 0, "n": 0, "max": 0} # Welt-Takt im laufenden Messfenster
var _frame_us = {"last": 0, "max": 0} # Abstand der Bilder im laufenden Messfenster
var _load = {} # letztes Messfenster: {in_world, tick_avg_ms, tick_max_ms, frame_max_ms, sent_kbps, recv_kbps}
var _load_at = 0
var _load_logged = 0
var _log: FileAccess
var _started = ""
var _status_dirty = true
var _stopping = false


func _ready() -> void:
	settings = Settings.new("server")
	dir = str(settings.value("dir")).trim_suffix("/")
	log_file = dir + "/server.log"
	status_file = dir + "/status.json"
	stop_file = dir + "/stop"
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.remove_absolute(stop_file)
	_log = FileAccess.open(log_file, FileAccess.WRITE)
	_started = Time.get_datetime_string_from_system(false, true)
	port = settings.value("port")
	dtls = settings.value("dtls")
	net = get_parent().get_node("Net")
	_async_handlers = {"register": _register, "login": _login}
	_handlers = {"hello": _hello, "ping": _ping, "logout": _logout,
		"char_list": _char_list, "char_create": _char_create, "char_delete": _char_delete, "char_enter": _char_enter,
		"world_ready": _world_ready, "world_leave": _world_leave, "target": _target, "chat": _chat,
		"quest_accept": _quest_accept, "quest_complete": _quest_complete, "quest_abandon": _quest_abandon,
		"equip": _equip, "unequip": _unequip, "move_item": _move_item, "gather": _gather, "gather_cancel": _gather_cancel,
		"attack": _attack, "attack_stop": _attack_stop, "revive": _revive, "skill_seen": _skill_seen, "shortcut": _shortcut,
		"skill_cast": _skill_cast, "skill_cancel": _skill_cancel}
	log_line("%s startet (Port %d, Protokoll %d, Prozess %d)" % [SERVER_NAME, port, Proto.VERSION, OS.get_process_id()])
	var err = _open_database()
	if err == "":
		game_world = World.new(db, net, log_line)
		game_world.badwords = characters.badwords
		stats = Stats.new()
		if not stats.loaded():
			log_line("Klassenwerte fehlen (%sclass_templates.json): Höchstwerte = Werte der Figur" % PLUGIN_SERVER)
		inventory = Inventory.new(db, net, log_line, stats)
		var ierr = inventory.load_templates()
		if ierr != "":
			log_line("Gegenstände: %s - keine Ausrüstung, keine Sammelpunkte" % ierr)
		else:
			log_line("Gegenstände: %d Vorlagen, %d Sammelpunkt-Vorlagen" % [inventory.items.size(), inventory.mines.size()])
		game_world.inventory = inventory
		inventory.on_equip_changed = game_world.equip_changed
		var quests = Quests.new(db, net, log_line, stats)
		quests.inventory = inventory
		inventory.quests = quests
		var combat = Combat.new(game_world, net, log_line, stats)
		combat.quests = quests
		combat.inventory = inventory
		game_world.combat = combat
		game_world.skills = Skills.new(db, net, log_line)
		var casting = SkillCast.new(game_world, net, log_line, combat)
		casting.stats_push = combat._push_stats
		combat.casting = casting
		game_world.casting = casting
		game_world.skills.info_of = casting.info
		var buffs = Buffs.new(game_world, net, log_line)
		buffs.combat = combat
		buffs.stats_push = combat._push_stats
		combat.buffs = buffs
		casting.buffs = buffs
		game_world.buffs = buffs
		var berr = buffs.load_templates()
		if berr != "":
			log_line("Statuseffekte: %s - keine Effekte" % berr)
		else:
			log_line("Statuseffekte: %d Vorlagen" % buffs.states.size())
		var serr = casting.load_templates()
		if serr != "":
			log_line("Fertigkeiten: %s - Einsetzen nicht möglich" % serr)
		else:
			log_line("Fertigkeiten: %d Vorlagen" % casting.templates.size())
		game_world.templates = characters.templates
		var qerr = quests.load_templates()
		if qerr != "":
			log_line("Quests: %s - keine Quests" % qerr)
		else:
			log_line("Quests: %d (%d automatisch vergebbar), %d NPCs vergeben, %d nehmen ab" % [quests.tasks.size(),
				quests.auto_list.size(), quests.npc_out.size(), quests.npc_in.size()])
			game_world.quests = quests
		_load_world(settings.value("maps"))
		err = _listen()
	if err != "":
		log_line("FEHLER: " + err)
		_write_status(false)
		get_tree().quit(1)
		return
	var timer = Timer.new()
	timer.wait_time = POLL_SECONDS
	timer.autostart = true
	timer.timeout.connect(_poll)
	add_child(timer)
	_ticker = Timer.new()
	_ticker.wait_time = 1.0 / Proto.MOVE_RATE
	_ticker.autostart = true
	_ticker.timeout.connect(_tick)
	add_child(_ticker)
	_load_at = Time.get_ticks_msec()
	_load_logged = _load_at
	log_line("Bereit, warte auf Spieler ...")
	_write_status(true)

func log_line(msg: String) -> void:
	var line = "[%s] %s" % [Time.get_time_string_from_system(), msg]
	print(line)
	if _log != null:
		_log.store_line(line)
		_log.flush()

func _open_database() -> String:
	db = Db.new()
	var path = str(settings.value("database"))
	var err = db.open(path if path != "" else dir + "/game.db")
	if err != "":
		return "Datenbank: " + err
	err = Schema.migrate(db)
	if err != "":
		return "Datenbank: " + err
	accounts = Accounts.new(db)
	characters = Characters.new(db)
	if characters.templates.is_empty():
		return "Startvorlagen fehlen (%sstart_roles.json)" % Characters.PLUGIN_SERVER
	log_line("Datenbank %s (Version %d, %d Konten, %d Figuren), %d Startvorlagen, %d Wörter im Namensfilter" % [db.path,
		Schema.version(), int(db.scalar("SELECT count(*) FROM accounts")), int(db.scalar("SELECT count(*) FROM characters")),
		characters.templates.size(), characters.badwords.size()])
	return ""

func _listen() -> String:
	peer = ENetMultiplayerPeer.new()
	peer.set_bind_ip(settings.value("bind"))
	var err = peer.create_server(port, settings.value("max_clients"))
	if err != OK:
		return "Port %d nicht verfügbar (%s)" % [port, error_string(err)]
	if dtls:
		var tls = _tls_options()
		if tls == null:
			return "DTLS-Schlüssel nicht lesbar oder erzeugbar (%s/dtls.key)" % dir
		err = peer.host.dtls_server_setup(tls)
		if err != OK:
			return "DTLS nicht einrichtbar (%s)" % error_string(err)
		log_line("Verbindungen verschlüsselt (DTLS, Zertifikat %s)" % ProjectSettings.globalize_path(dir + "/dtls.crt"))
	var mp := multiplayer as SceneMultiplayer
	mp.server_relay = false
	mp.multiplayer_peer = peer
	mp.peer_connected.connect(_on_peer_connected)
	mp.peer_disconnected.connect(_on_peer_disconnected)
	net.request_received.connect(_on_request)
	net.move_received.connect(game_world.move)
	return ""

# Schlüssel und selbst signiertes Zertifikat laden oder beim ersten Start erzeugen
func _tls_options() -> TLSOptions:
	var key = CryptoKey.new()
	var cert = X509Certificate.new()
	var key_file = dir + "/dtls.key"
	var cert_file = dir + "/dtls.crt"
	if not (FileAccess.file_exists(key_file) and key.load(key_file) == OK and cert.load(cert_file) == OK):
		var crypto = Crypto.new()
		key = crypto.generate_rsa(2048)
		cert = crypto.generate_self_signed_certificate(key, "CN=godot-fw-server,O=Godot-FW,C=DE")
		if key.save(key_file) != OK or cert.save(cert_file) != OK:
			return null
		log_line("DTLS-Schlüssel und Zertifikat erzeugt")
	return TLSOptions.server(key, cert)


# ====================================================
# WELT (Spawns aus dem Plugin: NPCs und Monster je Map, npcs.gd)
# ====================================================
func _load_world(only: String) -> void:
	if not ResourceLoader.exists(PLUGIN_SERVER + "spawn_builder.gd"):
		log_line("Spawns: Plugin PWE-Manager fehlt, Welt leer")
		return
	var spawn_builder = load(PLUGIN_SERVER + "spawn_builder.gd")
	var npcgen = load(PLUGIN_SERVER + "npcgen.gd")
	var heightmap = load(PLUGIN_SERVER + "heightmap.gd") if ResourceLoader.exists(PLUGIN_SERVER + "heightmap.gd") else null
	var templates = _templates()
	var wanted = only.split(",", false)
	var sources: Dictionary = spawn_builder.map_sources()
	var maps = sources.keys()
	maps.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	var totals = {"monsters": 0, "npcs": 0, "res": 0, "mines": 0, "unknown": 0}
	var heights = []
	var t0 = Time.get_ticks_msec()
	for map_name in maps:
		if not wanted.is_empty() and not map_name in wanted:
			continue
		var main: Dictionary = sources[map_name][0]
		var data = npcgen.new().read(spawn_builder.npcgen_path(main["folder"]))
		if data.has("error"):
			log_line("Map %s: %s" % [map_name, data["error"]])
			continue
		var terrain = null
		var dir = spawn_builder.server_dir().path_join("data").path_join(main["folder"])
		if heightmap != null and FileAccess.file_exists(dir.path_join("terrain.cfg")):
			terrain = heightmap.new()
			var err = terrain.load_dir(dir)
			if err != "":
				log_line("Map %s: Höhen %s" % [map_name, err])
				terrain = null
			else:
				heights.append(map_name)
		var s = _summary(data)
		s["folder"] = main["folder"]
		s["tag"] = main["tag"]
		if not templates.is_empty():
			var nm = Npcs.new(map_name, templates, game_world.npc_ids)
			nm.mine_templates = inventory.mines
			nm.load_spawns(data, main["folder"], terrain, Time.get_ticks_msec() / 1000.0)
			game_world.npc_maps[map_name] = nm
			s["monsters"] = nm.counts["monsters"]
			s["npcs"] = nm.counts["npcs"]
			s["mines"] = nm.counts["mines"]
			s["unknown"] = nm.counts["unknown"]
		world[map_name] = s
		for k in totals:
			totals[k] += s.get(k, 0)
	log_line("Welt geladen in %.1f s: %d Maps, %d Monster, %d NPCs, %d Sammelpunkte (%d erzeugt); %d Vorlagen unbekannt; Höhen für %s" % [
		(Time.get_ticks_msec() - t0) / 1000.0, world.size(), totals["monsters"], totals["npcs"], totals["res"], totals["mines"],
		totals["unknown"], ", ".join(heights) if not heights.is_empty() else "keine Map"])

# Werte der Monster- / NPC-Vorlagen (Plugin Server/npc_templates.json), {} wenn sie fehlen
func _templates() -> Dictionary:
	var path = PLUGIN_SERVER + "npc_templates.json"
	var d = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not d is Dictionary or not d.has("monsters") or not d.has("npcs"):
		log_line("Spawns: %s fehlt oder ist unlesbar, keine NPCs und Monster" % path)
		return {}
	return d

# Anzahlen der von Anfang an aktiven Spawns (Gebiete mit nicht aktiver Steuerung = Ereignisse)
func _summary(data: Dictionary) -> Dictionary:
	var active = {}
	for c in data["controllers"]:
		active[c["id"]] = c["active"]
	var s = {"monsters": 0, "npcs": 0, "res": 0}
	for a in data["areas"]:
		if a["ctrl"] != 0 and not active.get(a["ctrl"], true):
			continue
		for g in a["gens"]:
			s["npcs" if a["npc_type"] == 1 else "monsters"] += g["num"]
	for r in data["res_areas"]:
		if r["ctrl"] == 0 or active.get(r["ctrl"], true):
			for x in r["res"]:
				s["res"] += x["num"]
	return s


# ====================================================
# VERBINDUNGEN
# ====================================================
func _on_peer_connected(id: int) -> void:
	var pp = peer.get_peer(id)
	var address = pp.get_remote_address() if pp != null else "?"
	peers[id] = {"address": address, "at": Time.get_ticks_msec(), "hello": false, "account_id": 0, "account": "",
		"since": "", "window": 0, "requests": 0, "char_id": 0, "char_info": {}, "busy": false}
	log_line("Verbindung von %s (Peer %d)" % [address, id])

func _on_peer_disconnected(id: int) -> void:
	var p = peers.get(id)
	if p == null:
		return
	game_world.leave(id)
	peers.erase(id)
	if p["account_id"] != 0:
		if online.get(p["account_id"]) == id:
			online.erase(p["account_id"])
		log_line("Abgemeldet: %s (Peer %d, Verbindung getrennt) - %d online" % [p["account"], id, online.size()])
		_status_dirty = true
	else:
		log_line("Verbindung getrennt (Peer %d)" % id)

# Meldung senden und die Verbindung trennen, sobald alles Ausstehende gesendet ist
func kick(id: int, code: int) -> void:
	var p = peers.get(id)
	if p == null:
		return
	net.push(id, "kicked", {"code": code})
	game_world.leave(id)
	if p["account_id"] != 0 and online.get(p["account_id"]) == id:
		online.erase(p["account_id"])
		_status_dirty = true
	log_line("Getrennt: Peer %d %s(%s)" % [id, (p["account"] + " ") if p["account"] != "" else "", Proto.text(code)])
	p["account_id"] = 0
	p["kicked"] = true # eine noch laufende Anmeldung (Hash) meldet ihn nicht mehr an
	var pp = peer.get_peer(id)
	if pp != null:
		pp.peer_disconnect_later()


# ====================================================
# ANFRAGEN
# ====================================================
func _on_request(id: int, req: int, what: String, args: Dictionary) -> void:
	var p = peers.get(id)
	if p == null or _stopping:
		return
	# einfache Flutbremse je Verbindung
	var second = int(Time.get_ticks_msec() / 1000.0)
	if second != p["window"]:
		p["window"] = second
		p["requests"] = 0
	p["requests"] += 1
	if p["requests"] > MAX_REQUESTS_PER_SECOND:
		kick(id, Proto.Code.TOO_MANY_REQUESTS)
		return
	var r: Array
	if not _handlers.has(what) and not _async_handlers.has(what):
		r = [Proto.Code.UNKNOWN_REQUEST, {}]
	elif not p["hello"] and not what in BEFORE_HELLO:
		r = [Proto.Code.NOT_READY, {}]
	elif p["account_id"] == 0 and not what in BEFORE_LOGIN:
		r = [Proto.Code.NOT_LOGGED_IN, {}]
	elif _async_handlers.has(what):
		r = [Proto.Code.TOO_MANY_REQUESTS, {}] if p["busy"] else _async_handlers[what].call(id, req, p, args)
	else:
		r = _handlers[what].call(id, p, args)
	if not r.is_empty(): # leer: Antwort kommt nach dem Hash (_job_done)
		net.respond(id, req, r[0], r[1])

func _hello(id: int, p: Dictionary, args: Dictionary) -> Array:
	var version = args.get("version")
	if not version is int:
		return [Proto.Code.BAD_REQUEST, {}]
	if version != Proto.VERSION:
		log_line("Peer %d: Protokoll %d statt %d" % [id, version, Proto.VERSION])
		_kick_after_reply.call_deferred(id, Proto.Code.VERSION_MISMATCH)
		return [Proto.Code.VERSION_MISMATCH, {"version": Proto.VERSION}]
	p["hello"] = true
	return [Proto.Code.OK, {"server": SERVER_NAME, "version": Proto.VERSION, "started": _started}]

func _ping(_id: int, _p: Dictionary, _args: Dictionary) -> Array:
	return [Proto.Code.OK, {"time": Time.get_unix_time_from_system()}]

func _register(id: int, req: int, p: Dictionary, args: Dictionary) -> Array:
	var account = _arg_string(args, "account", Proto.ACCOUNT_MAX)
	var password = _arg_string(args, "password", Proto.PASSWORD_MAX)
	if account == null or password == null:
		return [Proto.Code.BAD_REQUEST, {}]
	return _start_job(id, req, p, "register", accounts.register_begin(account, password, p["address"]))

func _login(id: int, req: int, p: Dictionary, args: Dictionary) -> Array:
	if p["account_id"] != 0:
		return [Proto.Code.ALREADY_LOGGED_IN, {}]
	var account = _arg_string(args, "account", 64)
	var password = _arg_string(args, "password", 256)
	if account == null or password == null:
		return [Proto.Code.BAD_REQUEST, {}]
	var job = accounts.login_begin(account, password, p["address"])
	job["name"] = account
	job["force"] = args.get("force", false) == true
	return _start_job(id, req, p, "login", job)

# Hash im Hintergrund starten -> [] (Antwort später) oder sofort das Ergebnis der Vorprüfung
func _start_job(id: int, req: int, p: Dictionary, what: String, job: Dictionary) -> Array:
	if job.has("result"):
		return _job_result(id, p, what, job, job["result"])
	p["busy"] = true
	_jobs.append({"task": WorkerThreadPool.add_task(func(): Accounts.run_job(job)), "peer": id, "req": req, "what": what, "job": job})
	return []

func _process(_delta: float) -> void:
	var now = Time.get_ticks_usec()
	if _frame_us["last"] > 0:
		_frame_us["max"] = maxi(_frame_us["max"], now - _frame_us["last"])
	_frame_us["last"] = now
	if _jobs.is_empty():
		return
	for j in _jobs.duplicate():
		if not WorkerThreadPool.is_task_completed(j["task"]):
			continue
		WorkerThreadPool.wait_for_task_completion(j["task"])
		_jobs.erase(j)
		_job_done(j)

func _job_done(j: Dictionary) -> void:
	var r = accounts.register_finish(j["job"]) if j["what"] == "register" else accounts.login_finish(j["job"])
	var p = peers.get(j["peer"])
	if p == null or p.get("kicked", false): # inzwischen getrennt
		return
	p["busy"] = false
	r = _job_result(j["peer"], p, j["what"], j["job"], r)
	if not _stopping:
		net.respond(j["peer"], j["req"], r[0], r[1])

# Ergebnis von Anlegen / Anmelden ins Log und (Anmelden) die Sitzung eintragen
func _job_result(id: int, p: Dictionary, what: String, job: Dictionary, r: Array) -> Array:
	if r[0] == Proto.Code.SERVER_ERROR:
		log_line("FEHLER Datenbank: " + db.last_error)
	if what == "register":
		if r[0] == Proto.Code.OK:
			log_line("Konto angelegt: %s (Peer %d, %s)" % [r[1]["account"], id, p["address"]])
		return r
	if r[0] != Proto.Code.OK:
		log_line("Anmeldung abgewiesen: %s (Peer %d, %s): %s" % [_printable(job["name"]), id, p["address"], Proto.text(r[0])])
		return r
	if p["account_id"] != 0:
		return [Proto.Code.ALREADY_LOGGED_IN, {}]
	var account_id: int = r[1]["account_id"]
	if online.has(account_id): # nur einmal gleichzeitig: erzwungen fliegt die ältere Sitzung
		if not job["force"]:
			log_line("Anmeldung abgewiesen: %s (Peer %d): schon angemeldet" % [r[1]["account"], id])
			return [Proto.Code.ACCOUNT_ONLINE, {}]
		kick(online[account_id], Proto.Code.LOGGED_IN_ELSEWHERE)
	p["account_id"] = account_id
	p["account"] = r[1]["account"]
	p["since"] = Time.get_time_string_from_system()
	online[account_id] = id
	_status_dirty = true
	log_line("Angemeldet: %s (Peer %d, %s) - %d online" % [p["account"], id, p["address"], online.size()])
	return r

func _logout(id: int, p: Dictionary, _args: Dictionary) -> Array:
	if online.get(p["account_id"]) == id:
		online.erase(p["account_id"])
	game_world.leave(id)
	p["char_info"] = {}
	log_line("Abgemeldet: %s (Peer %d) - %d online" % [p["account"], id, online.size()])
	p["account_id"] = 0
	p["account"] = ""
	p["char_id"] = 0
	p["at"] = Time.get_ticks_msec()
	_status_dirty = true
	return [Proto.Code.OK, {}]

# ====================================================
# FIGUREN
# ====================================================
func _char_list(_id: int, p: Dictionary, _args: Dictionary) -> Array:
	return _db_result(characters.list(p["account_id"]))

func _char_create(id: int, p: Dictionary, args: Dictionary) -> Array:
	var r = _db_result(characters.create(p["account_id"], args))
	if r[0] == Proto.Code.OK:
		var c = r[1]["char"]
		log_line("Figur angelegt: %s (Konto %s, Rasse %d, Klasse %d, Peer %d)" % [c["name"], p["account"], c["race"], c["class"], id])
	return r

func _char_delete(id: int, p: Dictionary, args: Dictionary) -> Array:
	var r = _db_result(characters.delete(p["account_id"], args))
	if r[0] == Proto.Code.OK:
		log_line("Figur gelöscht: Nr. %d (Konto %s, Peer %d)" % [args["id"], p["account"], id])
	return r

func _char_enter(id: int, p: Dictionary, args: Dictionary) -> Array:
	game_world.leave(id)
	var r = _db_result(characters.enter(p["account_id"], args))
	if r[0] == Proto.Code.OK:
		# Höchstwerte nach Klasse und Stufe (stats.gd); ohne Klassenwerte gilt der gespeicherte Wert
		var c: Dictionary = r[1]["char"]
		var equip = inventory.equip_of(c["id"])
		var b = inventory.bonus(equip)
		r[1]["equip"] = inventory.equip_list(equip)
		r[1]["max_hp"] = stats.max_hp(c["class"], c["level"], r[1]["hp"]) + b["hp"]
		r[1]["max_mp"] = stats.max_mp(c["class"], c["level"], r[1]["mp"]) + b["mp"]
		r[1]["hp"] = clampi(int(r[1]["hp"]), 0, r[1]["max_hp"])
		r[1]["mp"] = clampi(int(r[1]["mp"]), 0, r[1]["max_mp"])
		r[1]["exp_next"] = stats.exp_next(c["level"])
		p["char_id"] = r[1]["char"]["id"]
		p["char_info"] = r[1]
		log_line("Figur gewählt: %s (Konto %s, Map %s, Peer %d)" % [r[1]["char"]["name"], p["account"], r[1]["map"], id])
	return r

# Map geladen: die mit char_enter gewählte Figur kommt in die Welt
func _world_ready(id: int, p: Dictionary, _args: Dictionary) -> Array:
	if p.get("char_info", {}).is_empty():
		return [Proto.Code.NOT_IN_WORLD, {}]
	game_world.enter(id, p["char_info"])
	var pl: Dictionary = game_world.players[id]
	var data = {"id": p["char_id"], "npcs": game_world.npcs_in_view(id)}
	if game_world.quests != null:
		game_world.quests.auto_deliver(id, pl)
		data["quests"] = game_world.quests.state_of(pl)
		data["stats"] = game_world.quests.stats_of(pl)
	data["inventory"] = inventory.state_of(pl)
	data["dead"] = pl.get("dead", false)
	data["skills"] = game_world.skills.state_of(pl)
	data["skills"]["info"] = game_world.casting.infos(pl)
	data["skills"]["cool"] = game_world.casting.cooldowns(pl)
	data["buffs"] = game_world.buffs.list_of(pl) if game_world.buffs != null else []
	return [Proto.Code.OK, data]

func _world_leave(id: int, p: Dictionary, _args: Dictionary) -> Array:
	if not game_world.has(id):
		return [Proto.Code.NOT_IN_WORLD, {}]
	game_world.leave(id)
	p["char_info"] = {}
	return [Proto.Code.OK, {}]

func _target(_id: int, p: Dictionary, args: Dictionary) -> Array:
	var target = args.get("id")
	if not target is int:
		return [Proto.Code.BAD_REQUEST, {}]
	return game_world.select_target(_id, target) if game_world.has(_id) else [Proto.Code.NOT_IN_WORLD, {}]

func _chat(id: int, _p: Dictionary, args: Dictionary) -> Array:
	return game_world.say(id, args.get("channel"), args.get("text"))

# Quest beim NPC annehmen / abschließen ({npc: Objekt-ID, id: Quest}), aufgeben ({id})
func _quest_accept(id: int, _p: Dictionary, args: Dictionary) -> Array:
	return _quest_at_npc(id, args, true)

func _quest_complete(id: int, _p: Dictionary, args: Dictionary) -> Array:
	return _quest_at_npc(id, args, false)

func _quest_at_npc(id: int, args: Dictionary, accept: bool) -> Array:
	var task = args.get("id")
	var npc = args.get("npc")
	if not task is int or not npc is int:
		return [Proto.Code.BAD_REQUEST, {}]
	if not game_world.has(id) or game_world.quests == null:
		return [Proto.Code.NOT_IN_WORLD, {}]
	var pl: Dictionary = game_world.players[id]
	var info = game_world.npc_info(pl, npc)
	return game_world.quests.accept(id, pl, info, task) if accept else game_world.quests.complete(id, pl, info, task)

func _quest_abandon(id: int, _p: Dictionary, args: Dictionary) -> Array:
	var task = args.get("id")
	if not task is int:
		return [Proto.Code.BAD_REQUEST, {}]
	if not game_world.has(id) or game_world.quests == null:
		return [Proto.Code.NOT_IN_WORLD, {}]
	return game_world.quests.abandon(id, game_world.players[id], task)

# Inventar: anlegen {pos}, ablegen {slot, pos (optional)}, verschieben {from, to}
func _equip(id: int, _p: Dictionary, args: Dictionary) -> Array:
	var pos = args.get("pos")
	if not pos is int:
		return [Proto.Code.BAD_REQUEST, {}]
	return inventory.equip(id, game_world.players[id], pos) if game_world.has(id) else [Proto.Code.NOT_IN_WORLD, {}]

func _unequip(id: int, _p: Dictionary, args: Dictionary) -> Array:
	var slot = args.get("slot")
	var to = args.get("pos", -1)
	if not slot is int or not to is int:
		return [Proto.Code.BAD_REQUEST, {}]
	return inventory.unequip(id, game_world.players[id], slot, to) if game_world.has(id) else [Proto.Code.NOT_IN_WORLD, {}]

func _move_item(id: int, _p: Dictionary, args: Dictionary) -> Array:
	var from = args.get("from")
	var to = args.get("to")
	if not from is int or not to is int:
		return [Proto.Code.BAD_REQUEST, {}]
	return inventory.move(id, game_world.players[id], from, to) if game_world.has(id) else [Proto.Code.NOT_IN_WORLD, {}]

# Kampf: Normalangriff auf ein Monster {id}, beenden {}, wiederbeleben {}
func _attack(id: int, _p: Dictionary, args: Dictionary) -> Array:
	var target = args.get("id")
	if not target is int:
		return [Proto.Code.BAD_REQUEST, {}]
	return game_world.combat.attack(id, game_world.players[id], target) if game_world.has(id) else [Proto.Code.NOT_IN_WORLD, {}]

func _attack_stop(id: int, _p: Dictionary, _args: Dictionary) -> Array:
	if not game_world.has(id):
		return [Proto.Code.NOT_IN_WORLD, {}]
	game_world.combat.stop(game_world.players[id])
	return [Proto.Code.OK, {}]

func _revive(id: int, _p: Dictionary, _args: Dictionary) -> Array:
	return game_world.combat.revive(id, game_world.players[id]) if game_world.has(id) else [Proto.Code.NOT_IN_WORLD, {}]

# Fertigkeiten: aus "Neue Fertigkeiten" weggelegt {ids}; Schnellleiste {bar, slot, id}
func _skill_seen(id: int, _p: Dictionary, args: Dictionary) -> Array:
	return game_world.skills.seen(game_world.players[id], args.get("ids")) if game_world.has(id) else [Proto.Code.NOT_IN_WORLD, {}]

func _shortcut(id: int, _p: Dictionary, args: Dictionary) -> Array:
	if not game_world.has(id):
		return [Proto.Code.NOT_IN_WORLD, {}]
	return game_world.skills.set_shortcut(game_world.players[id], args.get("bar"), args.get("slot"), args.get("id"))

# Fertigkeit einsetzen {id, target} -> {id, time}; Zaubern abbrechen {}
func _skill_cast(id: int, _p: Dictionary, args: Dictionary) -> Array:
	if not game_world.has(id):
		return [Proto.Code.NOT_IN_WORLD, {}]
	var pl: Dictionary = game_world.players[id]
	var pos = args.get("pos")
	if pos is Array and pos.size() == 3 and pos.all(func(v): return v is float or v is int):
		game_world.move(id, Vector3(pos[0], pos[1], pos[2]), pl["dir"], Proto.MOVE_STAND) # wie MOVE geprüft
	return game_world.casting.cast(id, pl, args.get("id"), args.get("target"))

func _skill_cancel(id: int, _p: Dictionary, _args: Dictionary) -> Array:
	return game_world.casting.cancel_request(id, game_world.players[id]) if game_world.has(id) else [Proto.Code.NOT_IN_WORLD, {}]

# Sammeln an einem Sammelpunkt {id} -> {id, time}; abbrechen {}
func _gather(id: int, _p: Dictionary, args: Dictionary) -> Array:
	var target = args.get("id")
	if not target is int:
		return [Proto.Code.BAD_REQUEST, {}]
	if not game_world.has(id):
		return [Proto.Code.NOT_IN_WORLD, {}]
	var pl: Dictionary = game_world.players[id]
	return inventory.gather(id, pl, game_world.npc_maps.get(pl["map"]), target)

func _gather_cancel(id: int, _p: Dictionary, _args: Dictionary) -> Array:
	if not game_world.has(id):
		return [Proto.Code.NOT_IN_WORLD, {}]
	var pl: Dictionary = game_world.players[id]
	inventory.cancel_gather(id, pl, game_world.npc_maps.get(pl["map"]), false)
	return [Proto.Code.OK, {}]

func _db_result(r: Array) -> Array:
	if r[0] == Proto.Code.SERVER_ERROR:
		log_line("FEHLER Datenbank: " + db.last_error)
	return r

func _kick_after_reply(id: int, code: int) -> void:
	kick(id, code)

# Text-Argument prüfen: String und nicht zu lang, sonst null
static func _arg_string(args: Dictionary, key: String, max_len: int) -> Variant:
	var v = args.get(key)
	if not v is String or v.length() > max_len:
		return null
	return v

# Für das Log: ohne Steuerzeichen, gekürzt
static func _printable(s: String) -> String:
	var out = ""
	for c in s.left(32):
		out += c if c.unicode_at(0) >= 32 else "?"
	return out


# ====================================================
# ZEITGEBER, STATUS, ENDE
# ====================================================
func _poll() -> void:
	if FileAccess.file_exists(stop_file) and not _stopping:
		stop()
		return
	var now = Time.get_ticks_msec()
	if now - _load_at >= LOAD_WINDOW * 1000.0:
		_measure_load(now)
	for id in peers.keys():
		var p = peers[id]
		if p["account_id"] != 0:
			continue
		var limit = Proto.LOGIN_TIMEOUT if p["hello"] else Proto.HELLO_TIMEOUT
		if now - p["at"] > limit * 1000.0:
			p["at"] = now # nur einmal trennen
			kick(id, Proto.Code.NOT_READY if not p["hello"] else Proto.Code.NOT_LOGGED_IN)
	if _status_dirty:
		_write_status(true)

# Welt-Takt (10 / s) mit Zeitmessung
func _tick() -> void:
	var t0 = Time.get_ticks_usec()
	game_world.tick()
	var us = Time.get_ticks_usec() - t0
	_tick_us["sum"] += us
	_tick_us["n"] += 1
	_tick_us["max"] = maxi(_tick_us["max"], us)

func _measure_load(now: int) -> void:
	var seconds = maxf(0.001, (now - _load_at) / 1000.0)
	_load_at = now
	var n = maxi(1, _tick_us["n"])
	var host: ENetConnection = peer.host if peer != null else null
	var sent = host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA) if host != null else 0.0
	var recv = host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA) if host != null else 0.0
	var last = _load
	_load = {"in_world": game_world.players.size(), "tick_avg_ms": snappedf(_tick_us["sum"] / 1000.0 / n, 0.01),
		"tick_max_ms": snappedf(_tick_us["max"] / 1000.0, 0.01), "frame_max_ms": snappedf(_frame_us["max"] / 1000.0, 0.1),
		"sent_kbps": snappedf(sent / 1024.0 / seconds, 0.1), "recv_kbps": snappedf(recv / 1024.0 / seconds, 0.1)}
	_tick_us = {"sum": 0, "n": 0, "max": 0}
	_frame_us["max"] = 0
	if _load["in_world"] > 0 or last.get("in_world", 0) > 0:
		_status_dirty = true
		if now - _load_logged >= LOAD_LOG * 1000.0:
			_load_logged = now
			log_line("Last: %d in der Welt, Takt Ø %.2f ms (max %.2f ms), längstes Bild %.1f ms, Netz %.1f kB/s raus, %.1f kB/s rein" % [
				_load["in_world"], _load["tick_avg_ms"], _load["tick_max_ms"], _load["frame_max_ms"], _load["sent_kbps"], _load["recv_kbps"]])

func stop() -> void:
	_stopping = true
	_ticker.stop() # nach dem Speichern ändert sich nichts mehr
	DirAccess.remove_absolute(stop_file)
	log_line("Server wird beendet (%d Verbindungen, %d angemeldet)" % [peers.size(), online.size()])
	for j in _jobs:
		WorkerThreadPool.wait_for_task_completion(j["task"])
	_jobs.clear()
	game_world.save_all()
	for id in peers:
		net.push(id, "server_closing")
	# Meldungen noch senden, dann schließen
	for i in 5:
		peer.poll()
		await get_tree().process_frame
	peer.close()
	db.close()
	_write_status(false)
	log_line("Server beendet")
	get_tree().quit()

# Ringverweise lösen (Welt <-> Kampf, Quests <-> Inventar, Inventar -> Welt), sonst bleiben die Teile
# beim Beenden im Speicher ("resources still in use")
func _exit_tree() -> void:
	if inventory != null:
		if inventory.quests != null:
			inventory.quests.inventory = null
		inventory.quests = null
		inventory.on_equip_changed = Callable()
	if game_world != null:
		if game_world.combat != null:
			game_world.combat.world = null
			game_world.combat.quests = null
			game_world.combat.inventory = null
			game_world.combat.casting = null
		if game_world.casting != null:
			game_world.casting.world = null
			game_world.casting.combat = null
			game_world.casting.stats_push = Callable()
		if game_world.skills != null:
			game_world.skills.info_of = Callable()
		if game_world.buffs != null:
			game_world.buffs.world = null
			game_world.buffs.combat = null
			game_world.buffs.stats_push = Callable()
			game_world.buffs._holders.clear()
		if game_world.combat != null:
			game_world.combat.buffs = null
		if game_world.casting != null:
			game_world.casting.buffs = null
		game_world.buffs = null
		game_world.combat = null
		game_world.casting = null
		game_world.quests = null
		game_world.inventory = null

func _write_status(running: bool) -> void:
	_status_dirty = false
	var players_out = []
	for id in peers:
		var p = peers[id]
		if p["account_id"] != 0:
			players_out.append({"peer": id, "name": p["account"], "address": p["address"], "since": p["since"]})
	var f = FileAccess.open(status_file, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"running": running, "pid": OS.get_process_id(), "port": port, "started": _started,
		"protocol": Proto.VERSION, "dtls": dtls, "connections": peers.size(),
		"players": players_out, "maps": world.size(),
		"in_world": game_world.players.size() if game_world != null else 0, "load": _load,
	}, "\t"))
