extends Node3D

# ====================================================
# Spielwelt des Clients (Fahrplan Schritt 6): Map laden, eigene Figur, andere Spieler.
# Laden mit dem Ladebildschirm des Spiels (LoadingGame.xml: Bild login\<1-4>.dds wie DlgLoading,
# beide Fortschrittsbalken):
#   1. Map-Szene aus dem Import des Plugins (Leiste ECM-GFX-MAP): <maps_root>/<map>/<map>.tscn;
#      fehlt ihr das Licht (Import vor dem 2.11.), kommt es aus den Spieldaten (angelica_world.gd
#      build_light), sonst ein Standardlicht - ohne Licht wären Figuren und NPCs schwarz;
#      auf dem Haupt-Thread geladen (~1 s für s9; geladen in einem Thread blockierte das Laden der
#      vielen GFX-Skripte der Szene einmal den ganzen Prozess)
#   2. Kollision: Terrain-Flächen der Szene als Dreiecksnetz, Gebäude und Hindernisse aus der
#      map.bht des Servers (Plugin Server/data/<Server-Ordner>/map.bht, brushes.gd) - in einem Thread
#   3. eigene Figur (angelica_player.gd mit Lauf-Animationen, local_player.gd) an die Position vom
#      Server, dann world_ready
# In der Welt: eigene Position 10 / s an den Server (nur bei Änderung, sonst jede Sekunde), STATE
# und player_enter / player_leave für die anderen (remote_player.gd), pos_correct setzt zurück.
# NPCs und Monster: npc_enter / npc_move / npc_leave (world_npc.gd); Namen, Farben und Modelle
# aus npc_data.gd (elements.data in der Sprache des Clients, Modelle aus dem Map-Import). Ist ein
# Modell nicht importiert (Map vor Schritt 7 importiert), baut der Client es aus den Spieldaten
# (ecm_importer.gd build_ecm, ohne angehängte Effekte; je Bild höchstens BUILD_BUDGET_US, jedes
# Modell einmal). Der Ladebildschirm bleibt, bis die NPCs im Umkreis (world_ready: npcs) da sind.
# Oberfläche (Schritt 8): hud.gd mit den Dialogen von <Skin>gameui; Werte der eigenen Figur aus
# char_enter, Ziel über "target" (Klick auf eine Figur: local_player.gd picked, Tab: nächstes Monster
# nach der Regel aus SelectTargetRule.lua, F1: eigene Figur; Ring unter dem Ziel), Chat "Sagen" (in den
# Verlauf), Minimap 10 / s mit NPCs / Monstern / Spielern. Esc schließt Chat / Ziel bzw. öffnet das
# Systemmenü: Wechseln = zurück zur Figurenauswahl (world_leave, Server speichert die Position),
# Verlassen = abmelden und das Spiel beenden, Fenster wechseln = anderer Skin (Einstellung ui_skin).
# Quests (Schritt 10): quest_data.gd (tasks.data im Index-Modus, im Ladebildschirm in einem Thread);
# Klick auf den schon gewählten NPC = ansprechen: die Figur läuft hin (bis TALK_RANGE m), dann das
# NPC-Fenster (hud.gd) mit seinen Quests; Optionen "Quest geben / abschließen / aufgeben" gehen als
# quest_accept / quest_complete / quest_abandon an den Server. quests-Meldungen aktualisieren
# Verfolgung und die Symbole über den NPCs, quest_event und stats erscheinen im Chat bzw. im Kopf.
# Autoroute (CDlgAutoMove / CECHostPlayer AutoMove): Wegekarte der Map (maps\<map>\movemaps,
# angelica_movemap.gd, beim Laden in einem Thread), Suche in einem Thread (immer nur eine, eine neue
# Anfrage wartet), local_player.gd läuft den Weg ab. Ziele: NPC ansprechen (Klick auf den gewählten
# NPC), grüne NPC-Links in Verfolgung / Quest-Fenster (sichtbarer NPC, sonst sein Ort aus
# task_npc.data), Klick auf die Minimap. Am Ziel eines NPC-Links geht sein Fenster auf; steckt die Figur
# fest, wird bis ROUTE_REPLANS mal neu gesucht. Ohne Wegekarte geht es geradeaus.
# Inventar und Ausrüstung (Schritt 10b): item_data.gd (Namen, Symbole, Modelle der Ausrüstung), Fenster
# B / C in hud.gd, Anfragen equip / unequip / move_item; die eigene Figur (char_enter equip) und
# andere (player_enter / player_equip) tragen ihre Ausrüstung (angelica_player.gd, bei Änderung neu
# gebaut). Sammelpunkte (Objekte mit MINE_ESSENCE): Klick = hinlaufen (Autoroute bis dist) und
# sammeln (gather, Fortschritt in Win_Prgs, Bewegen bricht ab), Ergebnis gather_end. Koordinaten-Links
# in Quest-Texten (&pos:...&) starten die Autoroute dorthin.
# Kampf (Schritt 9): zweiter Klick auf das gewählte Monster = hinlaufen (Autoroute bis in Reichweite)
# und Normalangriff (attack; der Server schlägt im Takt zu, solange es in Reichweite ist; läuft es weg,
# folgt die Figur); Bewegungstasten / Klick in die Welt beenden ihn (attack_stop). hit: Angriffs- und
# Treffer-Aktionen, schwebende Zahlen (weiß, Krit groß gelb, eigener Schaden rot, "Verfehlt"),
# Leben im Ziel-Fenster und im Kopf; kill: EXP im Chat; npc_leave die: Monster stirbt sichtbar; die:
# eigene Figur stirbt (Win_Message4, Wiederbeleben -> revive), andere ebenso sichtbar.
# Fertigkeiten (Fertigkeiten-Fahrplan F2): Taste 1 - 0 / Klick auf die Leiste -> use_skill: Prüfung wie
# der Client des Spiels (umgesetzt, Abklingzeit, Mana, Ziel = gewähltes Monster), zu weit -> Autoroute bis
# in die Annäherungsweite (info cast), dann skill_cast; die Figur spielt die Aktion der Fertigkeit mit
# ihren GFX / Klängen (attack_fx.gd play_events; fehlende Aktionen baut angelica_player.gd add_actions an
# das Modell), Zauberbalken (Win_Prgs), Bewegen bricht ab (skill_cancel). hit mit skill: Flug- / Treffer-
# GFX ab dem Beginn der Aktion (elapsed); skill_end beendet den Balken, danach (auto) der Normalangriff;
# cooldown startet die Uhr auf den Symbolen; skill_start zeigt das Zaubern anderer Spieler.
# Statuseffekte (F3 / F4): buffs merkt sich die Effekte je Figur / Monster (Meldung buffs, Ziel-Info, world_ready),
# die eigenen zeigt hud.gd in Win_Buff, die des Ziels im Ziel-Fenster (Art / Symbol / Text: Plugin
# Data/angelica_buffs.gd); GFX am Modell je sichtbarem Zustand (light, buff_gfx.lua) wie SetNewExtendStates;
# hit mit buff = Schaden über Zeit (nur Zahl), heal = grüne Zahl, stats speed_add = Tempo der Figur.
# Fehlt die Map, meldet der Bildschirm das und kehrt zurück.
# ====================================================

const Proto = preload("../common/protocol.gd")
const LocalPlayer = preload("local_player.gd")
const RemotePlayer = preload("remote_player.gd")
const NpcData = preload("npc_data.gd")
const WorldNpc = preload("world_npc.gd")
const Hud = preload("hud.gd")
const QuestData = preload("quest_data.gd")
const ItemData = preload("item_data.gd")
const AttackFx = preload("attack_fx.gd")
const PLAYER = "res://addons/PWE-Manager/ECM/angelica_player.gd"
const BRUSHES = "res://addons/PWE-Manager/Server/brushes.gd"
const SPAWNS = "res://addons/PWE-Manager/Server/spawn_builder.gd"
const IMPORTER = "res://addons/PWE-Manager/ECM/ecm_importer.gd"
const WORLD = "res://addons/PWE-Manager/MAP/angelica_world.gd"
const FILES = "res://addons/PWE-Manager/Data/angelica_files.gd"
const MOVEMAP = "res://addons/PWE-Manager/MAP/angelica_movemap.gd"
const SKILL_DATA = "res://addons/PWE-Manager/Data/angelica_skills.gd"
const BUFF_DATA = "res://addons/PWE-Manager/Data/angelica_buffs.gd"
const LOADING = "LoadingGame.xml"
const LOADING_IMAGE = "login\\%d.dds"
const SEND_IDLE = 1.0 # Sekunden: ohne Änderung trotzdem senden
const BUILD_BUDGET_US = 12000 # Mikrosekunden je Bild für Modelle, die zur Laufzeit gebaut werden
const NPC_WAIT_MS = 30000 # Ladebildschirm wartet höchstens so lange auf die NPCs
const RADAR_RANGE = 140.0 # m: Figuren für die Minimap
const RADAR_RATE = 10.0 # Minimap-Bilder je Sekunde
const TALK_RANGE = 4.0 # m: so nah läuft die Figur an einen NPC heran, bevor sein Fenster aufgeht
const TALK_CLOSE = 10.0 # m: weiter weg schließt das NPC-Fenster (MAX_SERVICE_DISTANCE des gs)
const ROUTE_REPLANS = 2 # neue Suchen, wenn die Figur auf der Autoroute feststeckt
const GATHER_MOVE = 0.3 # m: weiter bewegt = Sammeln abgebrochen
const CAST_MOVE = 0.3 # m: waagrecht weiter bewegt = Zaubern abbrechen (skill_cancel)
const SKILL_CHASE = 5 # so oft läuft die Figur einem weiterziehenden Ziel nach, dann fragt sie den Server
const FLOAT_TIME = 1.0 # s: schwebende Schadenszahl
const COLOR_DAMAGE = Color(1, 1, 1)
const COLOR_CRIT = Color(1.0, 0.85, 0.2)
const COLOR_HURT = Color(1.0, 0.3, 0.25)
const COLOR_HEAL = Color(0.35, 1.0, 0.35)
const BUFF_GFX_CHECK = 1.0 # s: GFX der Effekte nach neu gebauten Modellen wieder anhängen
const CHASE_FROM = 1.5 # m über der Reichweite: erst dann läuft die Figur nach (der Server schlägt bis
# Reichweite + halbe Größe + 1 m zu, combat.gd RANGE_SLACK)
const ATTACK_HOLD = 0.6 # s nach einem eigenen Treffer stehen bleiben
const RING_COLORS = {"monster": Color(1.0, 0.3, 0.2), "npc": Color(0.55, 0.95, 0.25), "player": Color(1.0, 0.95, 0.7)}
const TEXTS = {
	"Deu": {"map_missing": "Die Map %s ist nicht importiert.\nIm Editor über die Leiste ECM-GFX-MAP importieren (%s).",
		"model": "Die Figur konnte nicht gebaut werden: %s"},
	"Eng": {"map_missing": "Map %s has not been imported.\nImport it in the editor with the ECM-GFX-MAP dock (%s).",
		"model": "The character could not be built: %s"},
	"Franz": {"map_missing": "La carte %s n'est pas importée.\nL'importer dans l'éditeur avec le panneau ECM-GFX-MAP (%s).",
		"model": "Le personnage n'a pas pu être construit : %s"},
}

signal left_world # zurück zur Figurenauswahl (auch nach Fehler)

var login # login_screen.gd
var aui
var session
var info: Dictionary # Antwort von char_enter
var map_name = ""
var map_root: Node3D
var player: LocalPlayer
var hud: Hud
var my_id = 0 # Figuren-ID (world_ready)
var target_id = 0
var target_kind = ""
var remotes = {} # Figuren-ID -> remote_player.gd
var npcs = {} # NPC-ID -> world_npc.gd
var npc_data: NpcData
var quest_data: QuestData
var item_data: ItemData
var attack_fx: AttackFx # Angriffs-Effekte: Flug- und Treffer-GFX, Wirkung beim Einschlag
var gathering = {} # laufendes Sammeln: {id, end, time, desc, pos}
var attacking = 0 # Monster des laufenden Normalangriffs
var attack_range = 4.0
var _attack_hold = 0 # ms: bis dahin nicht nachlaufen
var talk_npc = 0 # NPC des offenen NPC-Fensters
var missing_models = {} # Szene -> true (nicht importiert)
var built_models = 0 # zur Laufzeit gebaute Modelle
var light_added = "" # "" = Licht aus dem Import, sonst "Spieldaten" bzw. "Standard"
var factory # angelica_player.gd, baut alle Figuren (liest .smd / .ski einmal)
var ready_in_world = false
var warnings: Array = []
var _loading
var _send_t = 0.0
var _last_sent = []
var _thread: Thread
var _leaving = false
var _player_script = load(PLAYER)
var _scenes = {} # Szene -> PackedScene oder null
var _built = {} # .ecm -> zur Laufzeit gebaute PackedScene oder null (fehlgeschlagen)
var _build_queue: Array = [] # .ecm, die noch gebaut werden
var _waiting = {} # .ecm -> NPC-IDs, die auf das Modell warten
var _ring: MeshInstance3D
var _target_seq = 0 # nur die Antwort der letzten Auswahl zählt
var _tab_seen: Array = [] # mit Tab schon gewählte (CECHostPlayer::m_vecTabSelTarget)
var _radar_t = 0.0
var _quest_thread: Thread
var _skill_thread: Thread
var _buff_thread: Thread
var buff_data = null # Plugin Data/angelica_buffs.gd: Art, Symbol, Text, GFX der Statuseffekte
var skill_data = null # Plugin Data/angelica_skills.gd: Namen, Beschreibungen (Lua), Symbole der Fertigkeiten
var _skills_state = {} # world_ready skills (für einen neu gebauten HUD)
var skill_info = {} # "ID" -> Werte der bekannten Fertigkeiten vom Server (mp, time, cool, cast, act ...)
var cooldowns = {} # ID -> [Ende ms, Dauer ms] (gemeinsam mit hud.gd)
var casting = {} # eigenes Zaubern: {id, time, end, name, target, pos, cancel_sent}; {pending} wartet auf Antwort
var _casts = {} # Figuren-ID -> {act, start}: Aktion der letzten Fertigkeit (Treffer-Effekte)
var buffs = {} # Figuren- / Monster-ID -> [[Effekt, Stapel, Ende ms (0 = ohne Ende), Dauer ms, light]] (Statuseffekte)
var _buff_gfx = {} # Figuren- / Monster-ID -> {model: Instanz-ID des Modells, nodes: {light: Node3D}}
var _buff_gfx_t = 0.0
var _pending_talk = 0 # NPC, zu dem die Figur zum Ansprechen läuft
var _icons = {} # Name des Quest-Symbols -> AtlasTexture
var movemap # angelica_movemap.gd, null = Map ohne Wegekarte (Autoroute geradeaus)
var route = {} # laufende Autoroute: goal, label, tid, npc, stop, exact, replans
var _route_next = {} # Anfrage, die auf das Ende der laufenden Suche wartet
var _route_thread: Thread
var _movemap_thread: Thread
var _buildings: StaticBody3D # Gebäude-Kollision (für die Geländehöhe ausgenommen)


func start(p_login, p_info: Dictionary) -> void:
	login = p_login
	aui = login.aui
	session = login.session
	info = p_info
	map_name = str(info["map"])
	name = "Welt"
	_loading = aui.dialog(LOADING)
	if _loading != null:
		_loading.set_image("Img_Loading1", aui.texture(LOADING_IMAGE % randi_range(1, 4)))
		_loading.show_item("Img_Loading2", false)
		_progress(0.0)
		aui.show_dialog(_loading)
	aui.clear_background()
	var err = await _load()
	if err != "":
		_hide_loading()
		await login.message(err)
		left_world.emit()
		return
	session.net.pushed.connect(_on_pushed)
	session.net.state_received.connect(_on_state)
	player.input_enabled = false
	var r = await session.world_ready()
	if r["code"] != Proto.Code.OK:
		_hide_loading()
		await login.message(Proto.text(r["code"], login.language))
		left_world.emit()
		return
	my_id = int(r["data"].get("id", 0))
	_set_buffs(my_id, r["data"].get("buffs", []))
	if hud != null:
		hud.set_inventory(r["data"].get("inventory", {}))
		if r["data"].has("stats"):
			_set_stats(r["data"]["stats"])
	if r["data"].get("dead", false):
		_my_death.call_deferred()
	if quest_data != null:
		quest_data.set_state(r["data"].get("quests", {}))
	_skills_state = r["data"].get("skills", {})
	if skill_data != null:
		for e in _skills_state.get("skills", []):
			skill_data.skill_class[int(e[0])] = int(info["char"]["class"]) # Symbol der eigenen Klasse
	skill_info.merge(_skills_state.get("info", {}), true)
	var cool: Dictionary = _skills_state.get("cool", {})
	for k in cool:
		cooldowns[int(k)] = [Time.get_ticks_msec() + int(cool[k]), int(cool[k])]
	_add_skill_actions()
	if hud != null:
		hud.set_skills(_skills_state)
	await _wait_npcs(int(r["data"].get("npcs", 0)))
	_refresh_quests()
	_hide_loading()
	player.input_enabled = true
	ready_in_world = true
	if hud != null:
		hud.aui.visible = true
	if built_models > 0:
		print("Welt: %d NPC-Modelle aus den Spieldaten gebaut (ohne Effekte); für die importierten Modelle die Map %s im Editor neu importieren (Leiste ECM-GFX-MAP)" % [built_models, map_name])

func _hide_loading() -> void:
	if _loading != null:
		aui.hide_dialog(_loading)

# Ladebildschirm bis die gemeldeten NPCs da und ihre Modelle gebaut sind
func _wait_npcs(expected: int) -> void:
	var end = Time.get_ticks_msec() + NPC_WAIT_MS
	while Time.get_ticks_msec() < end and (npcs.size() < expected or not _build_queue.is_empty()):
		var todo = _build_queue.size()
		_progress(1.0 if todo == 0 else 0.9 + 0.1 * float(built_models) / float(built_models + todo))
		await get_tree().process_frame

func _texts() -> Dictionary:
	return TEXTS.get(login.language, TEXTS["Deu"])

func _progress(f: float) -> void:
	if _loading != null:
		for bar in ["Prgs_Loading1", "Prgs_loading2"]:
			_loading.set_progress(bar, f * 100.0)


# ====================================================
# LADEN
# ====================================================
func _load() -> String:
	var root_dir = str(login.settings.value("maps_root"))
	var path = root_dir.path_join(map_name).path_join(map_name + ".tscn")
	if not ResourceLoader.exists(path):
		return _texts()["map_missing"] % [map_name, path]
	_progress(0.05)
	await get_tree().process_frame # Ladebildschirm zeigen
	await get_tree().process_frame
	var scene = load(path) as PackedScene
	if scene == null:
		return _texts()["map_missing"] % [map_name, path]
	_progress(0.55)
	# Quests im Hintergrund indizieren (tasks.data, gut 1 s)
	quest_data = QuestData.new()
	_quest_thread = Thread.new()
	_quest_thread.start(quest_data.open.bind(str(login.settings.value("data_root")), login.language))
	# Fertigkeiten: Beschreibungs-Skripte der Spieldaten (Lua, gut 1 s) ebenso
	if ResourceLoader.exists(SKILL_DATA):
		skill_data = load(SKILL_DATA).new(load(FILES).new(str(login.settings.value("data_root"))), login.language)
		skill_data.host_level = int(info["char"].get("level", 1))
		_skill_thread = Thread.new()
		_skill_thread.start(skill_data.open)
	# Statuseffekte: Art, Symbol, Text (configs), GFX (buff_gfx.lua) ebenso (~0,1 s)
	if ResourceLoader.exists(BUFF_DATA):
		buff_data = load(BUFF_DATA).new(load(FILES).new(str(login.settings.value("data_root"))), login.language)
		_buff_thread = Thread.new()
		_buff_thread.start(buff_data.open)
	# Wegekarte der Autoroute ebenso (~0,2 s)
	movemap = load(MOVEMAP).new()
	_movemap_thread = Thread.new()
	_movemap_thread.start(_load_movemap.bind(load(FILES), str(login.settings.value("data_root"))))
	map_root = scene.instantiate()
	add_child(map_root)
	_ensure_light()
	_progress(0.65)
	await get_tree().process_frame
	_add_terrain_collision()
	_progress(0.7)
	# Gebäude-Kollision im Thread (Lesen und Zerlegen der Brushes dauert ~1,5 s)
	var bht = _bht_path()
	if bht != "":
		_thread = Thread.new()
		_thread.start(_brush_faces.bind(bht, load(BRUSHES)))
		while _thread.is_alive():
			await get_tree().process_frame
		var faces: PackedVector3Array = _thread.wait_to_finish()
		_thread = null
		if not faces.is_empty():
			var shape = ConcavePolygonShape3D.new()
			shape.backface_collision = true
			shape.set_faces(faces)
			_buildings = _add_static("Gebaeude-Kollision", shape)
	else:
		warnings.append("keine map.bht für " + map_name)
	_progress(0.8)
	await get_tree().process_frame
	npc_data = NpcData.new()
	npc_data.my_level = int(info["char"].get("level", 1))
	var npc_err = npc_data.open(str(login.settings.value("data_root")), login.language, map_root)
	if npc_err != "":
		warnings.append("NPCs ohne Namen: " + npc_err)
	item_data = ItemData.new()
	item_data.elements = npc_data.elements
	item_data.files = load(FILES).new(str(login.settings.value("data_root")))
	item_data.language = login.language
	_progress(0.85)
	await get_tree().process_frame
	factory = _player_script.new(str(login.settings.value("data_root")))
	var c: Dictionary = info["char"]
	var own_equip = _equip_dict(info.get("equip", []))
	var err = factory.build(int(c["race"]), int(c["gender"]), int(c["class"]), c.get("appearance", {}), _actions(own_equip),
		equip_models(own_equip, int(c["race"]), int(c["class"]), int(c["gender"])))
	if err != "":
		return _texts()["model"] % err
	var height = maxf(1.0, factory.bounds().size.y)
	player = LocalPlayer.new()
	player.name = "Spieler"
	add_child(player)
	player.setup(factory.detach(), height)
	player.suffix = _suffix(own_equip)
	attack_fx = AttackFx.new()
	attack_fx.name = "Angriffe"
	add_child(attack_fx)
	var aerr = attack_fx.setup(str(login.settings.value("data_root")))
	if aerr != "":
		warnings.append(aerr)
	else:
		attack_fx.prewarm(player.model, _actions(own_equip)) # GFX der eigenen Angriffe (sonst ruckelt der erste)
	player.manual_move.connect(_on_manual_move)
	var pos: Array = info["pos"]
	player.place(Vector3(pos[0], pos[1] + 0.05, pos[2]), float(info.get("dir", 0.0)))
	player.picked.connect(select_target)
	player.route_finished.connect(_on_route_finished)
	player.route_stuck.connect(_on_route_stuck)
	while _movemap_thread.is_alive():
		await get_tree().process_frame
	var merr = _movemap_thread.wait_to_finish()
	_movemap_thread = null
	if merr != "":
		warnings.append("Autoroute ohne Wegekarte: " + merr)
		movemap = null
	while _quest_thread.is_alive():
		await get_tree().process_frame
	var qerr = _quest_thread.wait_to_finish()
	_quest_thread = null
	if qerr != "":
		warnings.append("Quests: " + qerr)
	if _skill_thread != null:
		while _skill_thread.is_alive():
			await get_tree().process_frame
		var serr = _skill_thread.wait_to_finish()
		_skill_thread = null
		if serr != "":
			warnings.append("Fertigkeiten: " + serr)
			skill_data = null
	if _buff_thread != null:
		while _buff_thread.is_alive():
			await get_tree().process_frame
		var berr = _buff_thread.wait_to_finish()
		_buff_thread = null
		if berr != "":
			warnings.append("Statuseffekte: " + berr)
			buff_data = null
		else:
			for e in buff_data.errors:
				warnings.append("Statuseffekte: " + e)
	quest_data.elements = npc_data.elements
	quest_data.player = {"name": c["name"], "level": int(c.get("level", 1)), "race": int(c["race"]),
		"class": int(c["class"]), "gender": int(c["gender"])}
	_make_hud()
	_progress(0.9)
	await get_tree().process_frame
	return ""

# HUD (bis zum Ende des Ladens unsichtbar: es liegt über dem Ladebildschirm)
func _make_hud() -> void:
	hud = Hud.new()
	add_child(hud)
	var err = hud.setup(str(login.settings.value("data_root")), login.language, int(login.settings.value("ui_skin")),
		map_name, int(info.get("world", 0)))
	if err != "":
		warnings.append("HUD: " + err)
	for w in hud.warnings:
		warnings.append("HUD: " + w)
	if hud.aui != null:
		hud.aui.visible = ready_in_world
	var c: Dictionary = info["char"]
	hud.set_stats({"name": c["name"], "level": c["level"], "class": c["class"], "hp": info.get("hp", 0),
		"max_hp": info.get("max_hp", info.get("hp", 1)), "mp": info.get("mp", 0), "max_mp": info.get("max_mp", info.get("mp", 1)),
		"exp": info.get("exp", 0), "exp_next": info.get("exp_next", 0)})
	hud.target_requested.connect(select_target)
	hud.npc_option.connect(_on_npc_option)
	hud.quest_abandon_requested.connect(_abandon)
	hud.quest_entries = func(): return quest_data.log_entries(func(tid): return npc_data.info(tid)["name"], hud.texts()) if quest_data != null and quest_data.tasks != null else []
	hud.npc_closed.connect(func(): talk_npc = 0)
	hud.items = item_data
	hud.me = {"name": c["name"], "level": int(c.get("level", 1)), "race": int(c["race"]), "class": int(c["class"]),
		"gender": int(c["gender"]), "appearance": c.get("appearance", {})}
	hud.equip_models = func(e: Dictionary): return equip_models(e, int(c["race"]), int(c["class"]), int(c["gender"]))
	hud.equip_requested.connect(_equip)
	hud.unequip_requested.connect(_unequip)
	hud.move_item_requested.connect(_move_item)
	hud.pos_route_requested.connect(_route_pos)
	hud.revive_requested.connect(_revive)
	hud.skills = skill_data
	hud.buffs = buff_data
	hud.set_buffs(buffs.get(my_id, []))
	hud.shortcut_requested.connect(_set_shortcut)
	hud.skills_seen_requested.connect(_skills_seen)
	hud.skill_info = skill_info
	hud.cooldowns = cooldowns
	hud.skill_use_requested.connect(use_skill)
	if not _skills_state.is_empty():
		hud.set_skills(_skills_state)
	hud.route_npc_requested.connect(route_npc)
	hud.map_route_requested.connect(func(xz: Vector2): route_to(Vector3(xz.x, player.global_position.y, xz.y), hud.texts()["map_point"]))
	hud.set_route_target(route.get("goal"))
	if quest_data != null:
		quest_data.set_ui(hud.aui)
		quest_data.item_count = _bag_count
		hud.quest_text = quest_data.format_text
		for w in quest_data.warnings:
			warnings.append("Quests: " + w)
		_icons = {}
		_refresh_quests()
	hud.say_requested.connect(_say)
	hud.leave_requested.connect(leave)
	hud.quit_requested.connect(quit_game)
	hud.skin_requested.connect(_switch_skin)

# "Fenster wechseln": HUD im anderen Skin neu bauen (Chat und Ziel bleiben)
func _switch_skin(skin: int) -> void:
	login.settings.set_value("ui_skin", skin)
	login.settings.save()
	var lines: Array = hud.chat_lines
	remove_child(hud)
	hud.queue_free()
	_make_hud()
	hud.set_chat_lines(lines)
	if target_id != 0:
		select_target(target_id)

# Ältere Map-Importe haben kein Licht ("Sun" / "Environment"): Licht aus den Spieldaten, sonst
# ein einfaches Standardlicht
func _ensure_light() -> void:
	if map_root.get_node_or_null("Sun") != null:
		return
	var imp = load(IMPORTER).new(str(login.settings.value("data_root")))
	var trn2: String = imp.find_game_file("maps/%s/%s.trn2" % [map_name, map_name])
	light_added = "Spieldaten" if trn2 != "" and load(WORLD).new(imp).build_light(trn2, map_root) else "Standard"
	if light_added == "Standard":
		_default_light()
	var objects = map_root.get_node_or_null("Objects")
	if objects != null and objects.has_method("apply_time"):
		objects.set("_light_night", null) # Tag / Nacht auf das neue Licht anwenden
		objects.apply_time()
	print("Welt: Map %s ohne Licht importiert, Licht (%s) ergänzt; für Licht, Spawns und NPC-Modelle die Map im Editor neu importieren (Leiste ECM-GFX-MAP)" % [map_name, light_added])

func _default_light() -> void:
	var sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(30.0), 0.0)
	map_root.add_child(sun)
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.65, 0.8)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.55)
	var we = WorldEnvironment.new()
	we.name = "Environment"
	we.environment = env
	map_root.add_child(we)

func _add_terrain_collision() -> void:
	var terrain = map_root.get_node_or_null("Terrain")
	if terrain == null:
		warnings.append("Map ohne Terrain")
		return
	for mi in terrain.get_children():
		if mi is MeshInstance3D and mi.mesh != null:
			var shape = mi.mesh.create_trimesh_shape()
			if shape != null:
				_add_static("Boden_" + String(mi.name), shape, mi.global_transform)

func _add_static(node_name: String, shape: Shape3D, xform: Transform3D = Transform3D.IDENTITY) -> StaticBody3D:
	var body = StaticBody3D.new()
	body.name = node_name
	body.transform = xform
	var cs = CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
	return body

# map.bht des Server-Ordners der Map (Hauptwelt in Server/maps.json)
func _bht_path() -> String:
	if not ResourceLoader.exists(SPAWNS):
		return ""
	var spawns = load(SPAWNS)
	var src: Array = spawns.sources(map_name)
	if src.is_empty():
		return ""
	var p = spawns.server_dir().path_join("data").path_join(src[0]["folder"]).path_join("map.bht")
	return p if FileAccess.file_exists(p) else ""

# im Thread: Brushes lesen und als Dreiecke
func _brush_faces(path: String, brushes_script: Script) -> PackedVector3Array:
	var br = brushes_script.new()
	if br.read(path) != "":
		return PackedVector3Array()
	var faces = PackedVector3Array()
	for b in br.brushes:
		faces.append_array(br.triangles(b))
	return faces


# ====================================================
# NETZ
# ====================================================
func _physics_process(delta: float) -> void:
	if not ready_in_world or player == null:
		return
	player.input_enabled = not _leaving and not player.dead and (hud == null or not hud.chat_focused())
	_check_talk()
	_send_t += delta
	if _send_t < 1.0 / Proto.MOVE_RATE:
		return
	var p = player.global_position
	var now = [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01), snappedf(player.direction(), 0.01), player.state]
	if now != _last_sent or _send_t >= SEND_IDLE:
		session.send_move(p, player.direction(), player.state)
		_last_sent = now
		_send_t = 0.0

func _on_pushed(what: String, data: Dictionary) -> void:
	match what:
		"player_enter":
			_add_remote(data)
		"player_leave":
			var r = remotes.get(int(data.get("id", 0)))
			_forget_buffs(int(data.get("id", 0)))
			if r != null:
				r.queue_free()
				remotes.erase(int(data["id"]))
			if int(data.get("id", 0)) == target_id:
				_clear_target()
		"npc_enter":
			for e in data.get("list", []):
				_add_npc(e)
		"npc_leave":
			for id in data.get("ids", []):
				var n = npcs.get(int(id))
				_forget_buffs(int(id)) # auch beim Tod: die Effekte enden (der Server vergisst sie ohne Meldung)
				if n != null:
					if data.get("die", false) and attack_fx != null:
						attack_fx.after_impacts(n, n.die) # stirbt sichtbar erst nach dem Einschlag
					elif data.get("die", false):
						n.die()
					else:
						n.queue_free()
					npcs.erase(int(id))
				if int(id) == target_id:
					_clear_target()
				if int(id) == attacking:
					attacking = 0
		"chat":
			if hud != null:
				hud.add_chat(str(data.get("name", "?")), str(data.get("text", "")))
		"quests":
			if quest_data != null:
				quest_data.set_state(data)
				_refresh_quests()
		"quest_event":
			_quest_event(data)
		"inventory":
			_set_inventory(data)
		"gather_end":
			_gather_end(data)
		"player_equip":
			var re = remotes.get(int(data.get("id", 0)))
			if re != null:
				re.equip = data.get("equip", [])
				re.replace_model(_remote_model(re))
				re.suffix = _suffix(_equip_dict(re.equip))
		"hit":
			_on_hit(data)
		"heal":
			_on_heal(data)
		"buffs":
			_set_buffs(int(data.get("id", 0)), data.get("list", []))
		"kill":
			if hud != null and int(data.get("exp", 0)) > 0:
				hud.add_info(hud.texts()["gain_exp"] % int(data["exp"]))
		"die":
			var who = int(data.get("id", 0))
			if who == my_id:
				if attack_fx != null:
					attack_fx.after_impacts(player, _my_death)
				else:
					_my_death()
			elif remotes.has(who):
				if attack_fx != null:
					attack_fx.after_impacts(remotes[who], remotes[who].die)
				else:
					remotes[who].die()
		"revive":
			var rv = remotes.get(int(data.get("id", 0)))
			var rp: Array = data.get("pos", [])
			if rv != null and rp.size() == 3:
				rv.revive(Vector3(rp[0], rp[1], rp[2]))
		"stats":
			_set_stats(data)
		"skill_start":
			_other_skill(data)
		"skill_end":
			_skill_end(data)
		"cooldown":
			if hud != null:
				hud.set_cooldown(int(data.get("id", 0)), int(data.get("ms", 0)))
		"skill_info":
			skill_info[str(int(data.get("id", 0)))] = data.get("info", {})
			_add_skill_actions()
		"skill_new", "skill_level":
			if skill_data != null:
				skill_data.skill_class[int(data.get("id", 0))] = int(info["char"]["class"])
			if hud != null:
				hud.add_skill(int(data.get("id", 0)), int(data.get("level", 1)), what == "skill_new")
				_skills_state = _skills_export()
		"npc_move":
			var n = npcs.get(int(data.get("id", 0)))
			var from: Array = data.get("pos", [])
			var to: Array = data.get("to", [])
			if n != null and from.size() == 3 and to.size() == 3:
				n.move_to(Vector3(from[0], from[1], from[2]), Vector3(to[0], to[1], to[2]), float(data.get("speed", 1.0)))
		"pos_correct":
			var pos: Array = data.get("pos", [])
			if pos.size() == 3 and player != null:
				player.place(Vector3(pos[0], pos[1], pos[2]), float(data.get("dir", 0.0)))

func _on_state(entries: Array) -> void:
	for e in entries:
		if not e is Array or e.size() != 6:
			continue
		var r = remotes.get(int(e[0]))
		if r != null:
			r.update_state(Vector3(e[1], e[2], e[3]), float(e[4]), int(e[5]))

func _add_remote(data: Dictionary) -> void:
	var id = int(data.get("id", 0))
	if remotes.has(id) or factory == null:
		return
	var r = RemotePlayer.new()
	r.level = int(data.get("level", 1))
	r.cls = int(data.get("class", 0))
	r.race = int(data.get("race", 0))
	r.gender = int(data.get("gender", 0))
	r.appearance = data.get("appearance", {})
	r.equip = data.get("equip", [])
	r.suffix = _suffix(_equip_dict(r.equip))
	var built = _build_remote(r)
	var model = built[0]
	var height: float = built[1]
	var pos: Array = data.get("pos", [0, 0, 0])
	add_child(r)
	r.setup(id, str(data.get("name", "?")), model, height, Vector3(pos[0], pos[1], pos[2]), float(data.get("dir", 0.0)))
	if data.get("dead", false):
		r.die()
	remotes[id] = r


func _add_npc(e) -> void:
	if not e is Array or e.size() != 8 or npcs.has(int(e[0])):
		return
	var id = int(e[0])
	var i: Dictionary = npc_data.info(int(e[1]))
	var scene = _scene(i["scene"])
	var pending = false
	if scene == null:
		var ecm = npc_data.ecm_of(int(e[1]))
		if _built.has(ecm):
			scene = _built[ecm]
		elif ecm != "":
			pending = true
			if not _waiting.has(ecm):
				_waiting[ecm] = []
				_build_queue.append(ecm)
			_waiting[ecm].append(id)
	var n = WorldNpc.new()
	n.setup(e, i, scene, npc_data.display_name(i, int(e[6])), npc_data.name_color(i, int(e[6])), pending)
	add_child(n)
	npcs[id] = n
	if quest_data != null and quest_data.tasks != null and i["npc"]:
		n.set_quest_icon(_icon(quest_data.head_icon(n.tid)))

# Modelle der Warteschlange bauen (je Bild höchstens BUILD_BUDGET_US, mindestens eins); Ring
# unter dem Ziel und Minimap nachführen
func _process(delta: float) -> void:
	_update_ring()
	if _route_thread != null and not _route_thread.is_alive():
		var res: Array = _route_thread.wait_to_finish()
		_route_thread = null
		_on_path(res[0], res[1])
	_radar_t += delta
	if ready_in_world and hud != null and player != null:
		_update_gather()
		_update_attack()
		_update_cast()
	if ready_in_world and hud != null and player != null and _radar_t >= 1.0 / RADAR_RATE:
		_radar_t = 0.0
		_update_radar()
	_buff_gfx_t += delta
	if _buff_gfx_t >= BUFF_GFX_CHECK:
		_buff_gfx_t = 0.0
		for id in buffs.keys() + _buff_gfx.keys().filter(func(k): return not buffs.has(k)):
			_update_buff_gfx(id)
	var t0 = Time.get_ticks_usec()
	while not _build_queue.is_empty() and (Time.get_ticks_usec() - t0 < BUILD_BUDGET_US):
		var ecm: String = _build_queue.pop_front()
		var scene = _build_model(ecm)
		_built[ecm] = scene
		for id in _waiting.get(ecm, []):
			var n = npcs.get(id)
			if n != null and is_instance_valid(n):
				n.set_model(scene, float(npc_data.info(n.tid)["scale"]))
		_waiting.erase(ecm)

func _build_model(ecm: String) -> PackedScene:
	var r: Dictionary = npc_data.importer().build_ecm(ecm)
	if r.has("error"):
		warnings.append(r["error"])
		return null
	var packed = PackedScene.new()
	var err = packed.pack(r["root"])
	r["root"].free()
	if err != OK:
		warnings.append("%s: %s" % [ecm.get_file(), error_string(err)])
		return null
	built_models += 1
	return packed

# Importierte Modell-Szene (einmal geladen), null wenn nicht importiert
func _scene(path: String) -> PackedScene:
	if path == "":
		return null
	if not _scenes.has(path):
		var ok = ResourceLoader.exists(path)
		_scenes[path] = load(path) as PackedScene if ok else null
		if not ok:
			missing_models[path] = true
	return _scenes[path]


# ====================================================
# ZIEL, CHAT, MINIMAP
# ====================================================
# Ziel wählen (0 = abwählen): Server fragen, dann Ziel-Fenster und Ring; der schon gewählte NPC
# wird angesprochen
func select_target(id: int) -> void:
	if id != 0 and id == target_id and target_kind == "npc":
		talk_to(id)
		return
	if id != 0 and id == target_id and target_kind == "monster":
		attack_target(id)
		return
	var mine = npcs.get(id)
	if mine != null and npc_data.info(mine.tid).get("mine", false):
		gather_at(id)
		return
	_target_seq += 1
	var seq = _target_seq
	if id == 0:
		_clear_target()
		await session.select_target(0)
		return
	var r = await session.select_target(id)
	if seq != _target_seq or not ready_in_world or hud == null:
		return
	if r["code"] != Proto.Code.OK:
		if r["code"] != Proto.Code.TARGET_INVALID:
			hud.add_system(Proto.text(r["code"], login.language))
		return
	var t: Dictionary = r["data"]
	target_id = id
	target_kind = str(t.get("kind", ""))
	_set_buffs(id, t.get("buffs", []))
	var shown_name = str(t.get("name", ""))
	var color = RING_COLORS["player"]
	if target_kind == "monster" or target_kind == "npc":
		var i = npc_data.info(int(t.get("tid", 0)))
		shown_name = npc_data.display_name(i, int(t.get("level", 1)))
		color = npc_data.name_color(i, int(t.get("level", 1)))
	hud.show_target(t, shown_name, color)
	hud.set_target_buffs(buffs.get(id, []))

func _clear_target() -> void:
	target_id = 0
	target_kind = ""
	if hud != null:
		hud.clear_target()

func _target_node() -> Node3D:
	if target_id == 0:
		return null
	if target_id == my_id:
		return player
	return npcs.get(target_id, remotes.get(target_id))

# Tab wie CECHostPlayer::OnMsgHstAutoSelect: das nächste Monster, das noch nicht mit Tab gewählt
# war (sind alle durch, beginnt die Runde neu); ohne Ziel beginnt sie ebenfalls neu
func tab_target() -> void:
	if target_id == 0 or target_id == my_id:
		_tab_seen.clear()
	var cam_dir = -player.camera.global_basis.z if player.camera != null else Vector3.FORWARD
	var list = tab_candidates(player.global_position, cam_dir)
	list = list.filter(func(id): return id != target_id)
	var fresh = list.filter(func(id): return not id in _tab_seen)
	if fresh.is_empty():
		_tab_seen.clear()
		fresh = list
	if fresh.is_empty():
		return
	_tab_seen.append(fresh[0])
	select_target(fresh[0])

# Monster, die von pos aus mit Tab wählbar sind (nächstes zuerst): can_select_by_tab, höchstens R m,
# ab r m nur im Kegel angle um die Blickrichtung cam_dir (SelectTargetRule.lua)
func tab_candidates(pos: Vector3, cam_dir: Vector3) -> Array:
	var rule: Dictionary = hud.tab_rule if hud != null else {"r": 5.0, "R": 20.0, "angle": 120.0}
	var min_cos = cos(deg_to_rad(float(rule["angle"])))
	var list = []
	for id in npcs:
		var n = npcs[id]
		var i = npc_data.info(n.tid)
		if i["npc"] or not i.get("tab", true):
			continue
		var d: Vector3 = n.global_position - pos
		var dist = d.length()
		if dist > float(rule["R"]):
			continue
		if dist > float(rule["r"]) and d.normalized().dot(cam_dir.normalized()) < min_cos:
			continue
		list.append([dist, id])
	list.sort_custom(func(a, b): return a[0] < b[0])
	return list.map(func(e): return e[1])

func _update_ring() -> void:
	var node = _target_node()
	if node == null or not is_instance_valid(node):
		if _ring != null:
			_ring.visible = false
		return
	if _ring == null:
		_ring = MeshInstance3D.new()
		_ring.name = "Zielring"
		var torus = TorusMesh.new()
		torus.inner_radius = 0.55
		torus.outer_radius = 0.68
		torus.rings = 48
		torus.ring_segments = 6
		_ring.mesh = torus
		_ring.scale = Vector3(1.0, 0.08, 1.0)
		var mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ring.material_override = mat
		_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_ring)
	var c: Color = RING_COLORS.get(target_kind, RING_COLORS["player"])
	(_ring.material_override as StandardMaterial3D).albedo_color = Color(c.r, c.g, c.b, 0.85)
	_ring.global_position = node.global_position + Vector3(0, 0.06, 0)
	_ring.visible = true

func _update_radar() -> void:
	var p = player.global_position
	var others = []
	var r2 = RADAR_RANGE * RADAR_RANGE
	for id in npcs:
		var n = npcs[id]
		var ni: Dictionary = npc_data.info(n.tid)
		if n.global_position.distance_squared_to(p) <= r2 and ni.get("minimap", true) and not ni.get("mine", false):
			others.append([n.global_position, "npc" if ni["npc"] else "monster"])
	for id in remotes:
		if remotes[id].global_position.distance_squared_to(p) <= r2:
			others.append([remotes[id].global_position, "player"])
	var t = _target_node()
	if t != null and t != player and is_instance_valid(t):
		others.append([t.global_position, "target"])
	hud.update_minimap(p, player.direction(), others)

# ====================================================
# NPC ANSPRECHEN, QUESTS
# ====================================================
func talk_to(id: int) -> void:
	var n = npcs.get(id)
	if n == null or quest_data == null:
		return
	if player.global_position.distance_to(n.global_position) > TALK_RANGE:
		route_to(n.global_position, npc_data.info(n.tid)["name"], n.tid, TALK_RANGE - 0.5, id)
		return
	_open_npc(id)

func _open_npc(id: int) -> void:
	_pending_talk = 0
	var n = npcs.get(id)
	if n == null:
		return
	cancel_route()
	player.target = null
	talk_npc = id
	var entries: Array = quest_data.npc_entries(n.tid)
	for e in entries:
		e["icon"] = _icon(quest_data.icons.get([e["kind"], e["topic"]], ""))
	var r: Dictionary = npc_data.elements.get_record(n.tid) if npc_data.elements != null else {}
	hud.open_npc(npc_data.info(n.tid)["name"], quest_data.format_text(str(r.get("hello_msg", ""))), entries)

# Jedes Physikbild: angekommen beim NPC? zu weit weg vom offenen Fenster?
func _check_talk() -> void:
	if _pending_talk != 0:
		var n = npcs.get(_pending_talk)
		if n == null or player.target == null:
			_pending_talk = 0 # weg oder die Figur wurde anders gesteuert
		elif player.global_position.distance_to(n.global_position) <= TALK_RANGE:
			_open_npc(_pending_talk)
	if talk_npc != 0 and hud != null:
		var t = npcs.get(talk_npc)
		if t == null or player.global_position.distance_to(t.global_position) > TALK_CLOSE:
			hud.close_npc()

# ====================================================
# AUTOROUTE
# ====================================================
# Im Lade-Thread: Wegekarte der Map -> "" oder Fehlertext
func _load_movemap(files_script: Script, data_root: String) -> String:
	var files = files_script.new(data_root)
	var dir: String = files.resolve("maps/%s/movemaps" % map_name)
	return movemap.load(files, dir) if dir != "" else "maps/%s/movemaps fehlt" % map_name

# Autoroute nach goal (y zählt nur mit exact: Ziel auf der Ebene in dieser Höhe, sonst die unterste
# begehbare); label für die Meldung; tid / npc: NPC, dessen Fenster am Ziel aufgeht; stop: so viele m
# vor dem Ziel anhalten
func route_to(goal: Vector3, label: String, tid: int = 0, stop: float = 0.0, npc: int = 0, exact: bool = false) -> void:
	if player == null:
		return
	var req = {"goal": goal, "label": label, "tid": tid, "npc": npc, "stop": stop, "exact": exact or npc != 0, "replans": 0}
	if _route_thread != null:
		_route_next = req
		return
	_search(req)

func _search(req: Dictionary) -> void:
	route = req
	_pending_talk = 0
	if hud != null:
		hud.set_route_target(req["goal"])
	var from = player.global_position
	var goal: Vector3 = req["goal"]
	if movemap == null:
		_on_path(PackedVector3Array([from, goal]), "")
		return
	var gy_from = _ground_y(from)
	var gy_to = _ground_y(goal) if req["exact"] else NAN
	var dh_from = maxf(0.0, from.y - gy_from) if not is_nan(gy_from) else 0.0
	var any = is_nan(gy_to)
	var dh_to = 0.0 if any else maxf(0.0, goal.y - gy_to)
	_route_thread = Thread.new()
	_route_thread.start(func(): return [movemap.find_path(from, goal, dh_from, any, dh_to), movemap.state])

# Ergebnis der Suche (Wegpunkte: x, Höhe über Gelände, z)
func _on_path(points: PackedVector3Array, state: String) -> void:
	if not _route_next.is_empty(): # inzwischen ein neues Ziel
		var req = _route_next
		_route_next = {}
		_search(req)
		return
	if route.is_empty() or player == null:
		return
	var tx: Dictionary = hud.texts() if hud != null else {}
	if points.is_empty():
		if hud != null:
			hud.add_system(tx["route_failed"] % state)
		_end_route()
		return
	var length = 0.0
	for i in range(1, points.size()):
		length += Vector2(points[i].x - points[i - 1].x, points[i].z - points[i - 1].z).length()
	if route["replans"] == 0 and hud != null:
		hud.add_info(tx["route_start"] % [Hud._plain(str(route["label"])), roundi(length)])
	player.follow_path(points, float(route["stop"]))

# Geländehöhe unter p (Strahl nach unten durch die Gebäude), NAN = kein Gelände
func _ground_y(p: Vector3) -> float:
	var q = PhysicsRayQueryParameters3D.create(p + Vector3(0, 3, 0), p - Vector3(0, 400, 0), 1)
	q.exclude = [player.get_rid()] + ([_buildings.get_rid()] if _buildings != null else [])
	var hit = get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"].y if not hit.is_empty() else NAN

func routing() -> bool:
	return not route.is_empty()

# Autoroute abbrechen (ohne Meldung)
func cancel_route() -> void:
	_route_next = {}
	_end_route()
	if player != null:
		player.stop_route(false)

func _end_route() -> void:
	route = {}
	if hud != null:
		hud.set_route_target(null)

# Ende des Weges (arrived) oder abgebrochen (Taste, Klick, Rücksetzung)
func _on_route_finished(arrived: bool) -> void:
	var r = route
	_end_route()
	if arrived and int(r.get("gather", 0)) != 0:
		_start_gather(int(r["gather"]))
		return
	if arrived and int(r.get("attack", 0)) != 0:
		_start_attack(int(r["attack"]))
		return
	if arrived and int(r.get("skill", 0)) != 0:
		# das Ziel kann inzwischen weitergelaufen sein: noch einmal prüfen, notfalls nachlaufen
		if npcs.has(int(r["skill_target"])) and target_id == int(r["skill_target"]):
			use_skill(int(r["skill"]), int(r.get("skill_tries", 0)) + 1)
		return
	if not arrived or r.is_empty() or int(r["tid"]) == 0:
		return
	var id = int(r["npc"]) if npcs.has(int(r["npc"])) else _nearest_npc(int(r["tid"]))
	var n = npcs.get(id)
	if n == null:
		return
	var d = player.global_position.distance_to(n.global_position)
	if d <= TALK_RANGE:
		_open_npc(id)
	elif d <= TALK_CLOSE: # letztes Stück geradeaus (Ziel war nur ungefähr bekannt)
		_pending_talk = id
		player.target = n.global_position

func _on_route_stuck() -> void:
	if route.is_empty() or _route_thread != null:
		return
	if int(route["replans"]) >= ROUTE_REPLANS:
		if hud != null:
			hud.add_system(hud.texts()["route_stuck"])
		cancel_route()
		return
	var req = route.duplicate()
	req["replans"] = int(req["replans"]) + 1
	_search(req)

# NPC-Link (Vorlage tid): sichtbarer NPC -> hin und ansprechen; sonst sein Ort aus task_npc.data
func route_npc(tid: int) -> void:
	if player == null or npc_data == null:
		return
	var label = str(npc_data.info(tid)["name"])
	var id = _nearest_npc(tid)
	if id != 0:
		talk_to(id)
		return
	var where: Array = quest_data.npc_pos.get(tid, []) if quest_data != null else []
	if where.is_empty():
		hud.add_system(hud.texts()["route_unknown"] % Hud._plain(label))
	elif int(where[0]) != int(info.get("world", 0)):
		hud.add_system(hud.texts()["route_far"] % Hud._plain(label))
	else:
		route_to(where[1], label, tid, TALK_RANGE - 0.5, 0, true)

func _nearest_npc(tid: int) -> int:
	var best = 0
	var best_d = INF
	for id in npcs:
		var n = npcs[id]
		if n.tid == tid:
			var d = n.global_position.distance_squared_to(player.global_position)
			if d < best_d:
				best = id
				best_d = d
	return best

# Koordinaten-Link (&pos:(x,y,z,Welt)Name&): Autoroute, wenn der Ort in dieser Welt liegt
func _route_pos(goal: Vector3, world_id: int, label: String) -> void:
	if world_id != 0 and world_id != int(info.get("world", 0)):
		hud.add_system(hud.texts()["route_far"] % label)
		return
	route_to(goal, label if label != "" else hud.texts()["map_point"], 0, 1.0, 0, true)


# ====================================================
# INVENTAR, AUSRÜSTUNG, SAMMELN
# ====================================================
static func _equip_dict(list: Array) -> Dictionary:
	var out = {}
	for e in list:
		out[int(e[0])] = int(e[1])
	return out

# {Platz: ID} -> {Platz: Modellpfad} für Rasse / Klasse / Geschlecht
# {Platz: ID} -> {Platz: Modellpfad}, die Waffe (0) als {model, left, type} (angelica_player.gd)
func equip_models(equip: Dictionary, race: int, cls: int, gender: int) -> Dictionary:
	var out = {}
	if item_data == null:
		return out
	for slot in equip:
		var id = int(equip[slot])
		var path = item_data.model(id, race, cls, gender)
		if path == "":
			continue
		if int(slot) == 0:
			out[0] = {"model": path, "left": item_data.model(id, race, cls, gender, true),
				"type": int(item_data.info(id).get("action_type", 0))}
		else:
			out[int(slot)] = path
	return out

func _bag_count(id: int) -> int:
	var n = 0
	if hud != null:
		for pos in hud.inventory["bag"]:
			if hud.inventory["bag"][pos][0] == id:
				n += hud.inventory["bag"][pos][1]
	return n

func _set_inventory(data: Dictionary) -> void:
	if hud == null:
		return
	var old: Dictionary = hud.inventory["equip"].duplicate()
	hud.set_inventory(data)
	if hud.inventory["equip"] != old:
		_rebuild_own_model()
	_refresh_quests()

# Eigene Figur mit der aktuellen Ausrüstung neu bauen
func _rebuild_own_model() -> void:
	var c: Dictionary = info["char"]
	var err = factory.build(int(c["race"]), int(c["gender"]), int(c["class"]), c.get("appearance", {}), _actions(hud.inventory["equip"]),
		equip_models(hud.inventory["equip"], int(c["race"]), int(c["class"]), int(c["gender"])))
	if err != "":
		warnings.append(err)
		return
	player.replace_model(factory.detach())
	player.suffix = _suffix(hud.inventory["equip"])
	if attack_fx != null:
		attack_fx.prewarm(player.model, _actions(hud.inventory["equip"]))
	_add_skill_actions()

# Aktionen der Figuren (mit Kampf-Aktionen der Waffenart) und Endung des Normalangriffs
func _actions(equip: Dictionary) -> Array:
	return _player_script.combat_actions(_action_type(equip))

func _suffix(equip: Dictionary) -> String:
	return _player_script.suffix_of(_action_type(equip))

func _action_type(equip: Dictionary) -> int:
	var w = int(equip.get(0, 0))
	return int(item_data.info(w).get("action_type", 0)) if w != 0 and item_data != null else 0

func _remote_model(r) -> Node3D:
	return _build_remote(r)[0]

# Modell einer anderen Figur mit Ausrüstung -> [Modell oder null, Höhe]
func _build_remote(r) -> Array:
	var err = factory.build(r.race, r.gender, r.cls, r.appearance, _actions(_equip_dict(r.equip)),
		equip_models(_equip_dict(r.equip), r.race, r.cls, r.gender))
	if err != "":
		warnings.append(err)
		return [null, 1.8]
	var height = maxf(1.0, factory.bounds().size.y)
	return [factory.detach(), height]

func _equip(pos: int) -> void:
	var r = await session.equip(pos)
	if hud != null and r["code"] != Proto.Code.OK:
		hud.add_system(Proto.text(r["code"], login.language))

func _unequip(slot: int, pos: int) -> void:
	var r = await session.unequip(slot, pos)
	if hud != null and r["code"] != Proto.Code.OK:
		hud.add_system(Proto.text(r["code"], login.language))

func _move_item(from: int, to: int) -> void:
	var r = await session.move_item(from, to)
	if hud != null and r["code"] != Proto.Code.OK:
		hud.add_system(Proto.text(r["code"], login.language))

# Sammelpunkt angeklickt: hinlaufen (bis zu seinem Abstand), dann sammeln
func gather_at(id: int) -> void:
	var n = npcs.get(id)
	if n == null or not gathering.is_empty():
		return
	var i: Dictionary = npc_data.info(n.tid)
	var dist = maxf(1.0, float(i.get("dist", 3.0)))
	if player.global_position.distance_to(n.global_position) <= dist:
		_start_gather(id)
		return
	route_to(n.global_position, str(i["name"]), 0, dist - 0.7, 0, true)
	route["gather"] = id

func _start_gather(id: int) -> void:
	var n = npcs.get(id)
	if n == null:
		return
	var r = await session.gather(id)
	if hud == null:
		return
	if r["code"] != Proto.Code.OK:
		hud.add_system(Proto.text(r["code"], login.language))
		return
	var i: Dictionary = npc_data.info(n.tid)
	var secs = maxf(0.1, float(r["data"].get("time", 1)))
	gathering = {"id": id, "time": secs, "end": Time.get_ticks_msec() + int(secs * 1000.0),
		"desc": str(i.get("desc", "")) if str(i.get("desc", "")) != "" else hud.texts()["gather"], "pos": player.global_position}
	player.face(n.global_position)
	hud.set_progress(gathering["desc"], 0.0)

# Jedes Bild: Fortschritt; bewegt sich die Figur, bricht das Sammeln ab
func _update_gather() -> void:
	if gathering.is_empty():
		return
	if player.global_position.distance_to(gathering["pos"]) > GATHER_MOVE:
		gathering = {}
		hud.set_progress("", 0.0)
		session.gather_cancel()
		return
	var left = float(gathering["end"] - Time.get_ticks_msec()) / 1000.0
	hud.set_progress(gathering["desc"], 1.0 - clampf(left / float(gathering["time"]), 0.0, 1.0))

func _gather_end(d: Dictionary) -> void:
	if hud == null:
		return
	var was = not gathering.is_empty()
	gathering = {}
	hud.set_progress("", 0.0)
	if not d.get("ok", false):
		return
	var got: Array = d.get("items", [])
	for it in got:
		hud.add_info(hud.texts()["gain_item"] % [Hud._plain(item_data.info(int(it[0]))["name"]), int(it[1])])
	if got.is_empty() and was:
		hud.add_info(hud.texts()["gather_none"])

# ====================================================
# KAMPF
# ====================================================
# Monster angreifen: in Reichweite gleich, sonst hinlaufen
func attack_target(id: int) -> void:
	var n = npcs.get(id)
	if n == null or player.dead:
		return
	var reach = _my_range()
	if _flat_dist(n.global_position) <= reach:
		_start_attack(id)
		return
	route_to(n.global_position, npc_data.display_name(npc_data.info(n.tid), n.level), 0, reach - 1.0, 0, true)
	route["attack"] = id

func _start_attack(id: int) -> void:
	var r = await session.attack(id)
	if hud == null:
		return
	if r["code"] != Proto.Code.OK:
		hud.add_system(Proto.text(r["code"], login.language))
		return
	attacking = id
	attack_range = float(r["data"].get("range", 4.0))
	player.mark_fight() # Waffe ziehen (CECHPWorkTrace: SetIsFighting(true, 6000))

func stop_attack() -> void:
	if attacking != 0:
		attacking = 0
		session.attack_stop()

func _on_manual_move() -> void:
	stop_attack()

# Reichweite des Normalangriffs (Waffe, sonst 4 m wie CHARRACTER_CLASS_CONFIG)
func _my_range() -> float:
	var w = int(hud.inventory["equip"].get(0, 0)) if hud != null else 0
	var r = float(item_data.info(w).get("range", 0.0)) if w != 0 else 0.0
	return r if r > 0.0 else 4.0

func _flat_dist(p: Vector3) -> float:
	return Vector2(p.x - player.global_position.x, p.z - player.global_position.z).length()

# Jedes Bild: läuft das Ziel aus der Reichweite, folgt die Figur
func _update_attack() -> void:
	if attacking == 0 or player.dead:
		return
	var n = npcs.get(attacking)
	if n == null:
		attacking = 0
		return
	if not player.following() and route.is_empty() and Time.get_ticks_msec() >= _attack_hold:
		var d = _flat_dist(n.global_position)
		if d > attack_range + CHASE_FROM:
			player.target = n.global_position
		elif player.target != null and d <= attack_range + 0.5:
			player.target = null
			player.face(n.global_position)

# ====================================================
# FERTIGKEITEN
# ====================================================
# Fertigkeit einsetzen (Taste 1 - 0, Klick auf die Leiste); tries = wie oft schon nachgelaufen
func use_skill(id: int, tries: int = 0) -> void:
	if player == null or player.dead or hud == null:
		return
	var i: Dictionary = skill_info.get(str(id), {})
	var code = Proto.Code.OK
	if i.is_empty() or not i.get("usable", false):
		code = Proto.Code.SKILL_NOT_YET
	elif not casting.is_empty() or not gathering.is_empty():
		code = Proto.Code.SKILL_BUSY
	elif hud.cool_fraction(id) > 0.0:
		code = Proto.Code.SKILL_COOLDOWN
	elif not hud.mana_ok(id):
		code = Proto.Code.NO_MANA
	elif target_kind != "monster" or not npcs.has(target_id) or npcs[target_id].dead:
		code = Proto.Code.NO_TARGET
	if code != Proto.Code.OK:
		hud.add_system(Proto.text(code, login.language))
		return
	var n = npcs[target_id]
	var reach = maxf(1.0, float(i.get("cast", i.get("range", 4.0))))
	if _flat_dist(n.global_position) > reach and tries < SKILL_CHASE:
		route_to(n.global_position, npc_data.display_name(npc_data.info(n.tid), n.level), 0, maxf(0.5, reach - 0.5), 0, true)
		route["skill"] = id
		route["skill_target"] = target_id
		route["skill_tries"] = tries
		return
	_start_skill(id, target_id)

func _start_skill(id: int, tid: int) -> void:
	var n = npcs.get(tid)
	if n == null or player.dead or not casting.is_empty():
		return
	player.target = null
	player.face(n.global_position)
	casting = {"pending": id}
	var r = await session.skill_cast(id, tid, player.global_position)
	if hud == null:
		return
	if r["code"] != Proto.Code.OK:
		casting = {}
		hud.add_system(Proto.text(r["code"], login.language))
		return
	var i: Dictionary = skill_info.get(str(id), {})
	var t = int(r["data"].get("time", i.get("time", 0)))
	var act = str(i.get("act", ""))
	casting = {"id": id, "time": t, "end": Time.get_ticks_msec() + t, "target": tid, "pos": player.global_position,
		"name": Hud._plain(skill_data.skill_name(id)) if skill_data != null else str(id)}
	_casts[my_id] = {"act": act, "start": Time.get_ticks_msec()}
	player.mark_fight()
	var length = player.play_skill(act)
	if attack_fx != null and attack_fx.importer != null:
		attack_fx.play_events(player, player.model, act, length)
	if t > 0:
		hud.set_progress(casting["name"], 0.0)

# Jedes Bild: Zauberbalken; bewegt sich die Figur, bricht das Zaubern ab (der Server entscheidet)
func _update_cast() -> void:
	if not casting.has("end"):
		return
	if not casting.get("cancel_sent", false) and _flat_dist(casting["pos"]) > CAST_MOVE:
		casting["cancel_sent"] = true
		session.skill_cancel()
	if int(casting["time"]) > 0:
		var left = int(casting["end"]) - Time.get_ticks_msec()
		hud.set_progress(casting["name"], 1.0 - clampf(float(left) / int(casting["time"]), 0.0, 1.0))

# Zaubern fertig (ok) bzw. abgebrochen
func _skill_end(d: Dictionary) -> void:
	if int(d.get("src", 0)) != my_id:
		var r = remotes.get(int(d.get("src", 0)))
		if r != null and not d.get("ok", false):
			r._once = ""
		return
	var was = casting
	casting = {}
	if hud == null:
		return
	hud.set_progress("", 0.0)
	if not d.get("ok", false):
		player.stop_once()
		hud.add_system(hud.texts()["skill_stopped"])
		return
	var tid = int(was.get("target", 0))
	if skill_info.get(str(was.get("id", 0)), {}).get("auto", false) and attacking == 0 and npcs.has(tid) and not npcs[tid].dead:
		_start_attack(tid) # AUTOATTACK_ACTIVATE: danach Normalangriff

# Eine andere Figur zaubert (skill_start)
func _other_skill(d: Dictionary) -> void:
	var src = int(d.get("src", 0))
	var act = str(d.get("act", ""))
	_casts[src] = {"act": act, "start": Time.get_ticks_msec()}
	var r = remotes.get(src)
	if r == null or r.model == null:
		return
	var dst = _node_of(int(d.get("dst", 0)))
	if dst != null:
		r.face(dst.global_position)
	r.mark_fight()
	if factory != null and r.anim != null and not r.anim.has_animation(act):
		factory.add_actions(r.model, [act])
	var length = r.play_skill(act)
	if attack_fx != null and attack_fx.importer != null:
		attack_fx.play_events(r, r.model, act, length)

# Aktionen der bekannten Fertigkeiten an die eigene Figur (fehlen nach jedem Neubau)
func _add_skill_actions() -> void:
	if player == null or player.model == null or factory == null:
		return
	var acts = []
	for k in skill_info:
		var a = str(skill_info[k].get("act", ""))
		if a != "" and not a in acts:
			acts.append(a)
	if factory.add_actions(player.model, acts) > 0 and attack_fx != null and attack_fx.importer != null:
		attack_fx.prewarm(player.model, acts)

func _node_of(id: int) -> Node3D:
	if id == my_id:
		return player
	return npcs.get(id, remotes.get(id))

func _on_hit(d: Dictionary) -> void:
	if hud == null:
		return
	var src = _node_of(int(d.get("src", 0)))
	var dst = _node_of(int(d.get("dst", 0)))
	if d.has("buff"): # Schaden über Zeit (Statuseffekt): nur Zahl und Leben, keine Aktion
		if dst != null:
			_hit_result(d, dst)
		return
	for n in [src, dst]: # Spieler: Waffen in die Hand (Kampfzustand)
		if n != null and n.has_method("mark_fight"):
			n.mark_fight()
	var action = ""
	var skill = int(d.get("skill", 0))
	if src != null and dst != null and skill != 0: # Fertigkeit: Aktion läuft seit dem Zaubern
		action = str(_casts.get(int(d.get("src", 0)), {}).get("act", ""))
		if src.has_method("face"):
			src.face(dst.global_position)
	elif src != null and dst != null:
		if src == player:
			if not player.following():
				player.target = null # der Server schlägt zu: in Reichweite, stehen bleiben
				_attack_hold = Time.get_ticks_msec() + int(ATTACK_HOLD * 1000.0)
			player.face(dst.global_position)
			action = player.play_attack()
		elif src.has_method("play_attack"):
			if src.has_method("face"):
				src.face(dst.global_position)
			action = src.play_attack()
	if dst == null:
		return
	if src != null and attack_fx != null and attack_fx.importer != null:
		attack_fx.play(src, src.get("model"), action, dst, _hit_result.bind(d, dst), int(d.get("elapsed", 0)) if skill != 0 else 0)
	else:
		_hit_result(d, dst)

# Heilung durch einen Statuseffekt: grüne Zahl, Leben
func _on_heal(d: Dictionary) -> void:
	var dst = _node_of(int(d.get("dst", 0)))
	if hud == null or dst == null:
		return
	_float_text(dst, "+%d" % int(d.get("amount", 0)), COLOR_HEAL, false)
	if dst == player:
		hud.set_stats({"hp": int(d.get("hp", 0)), "max_hp": int(d.get("max_hp", 1))})
		info["hp"] = int(d.get("hp", 0))
	elif int(d.get("dst", 0)) == target_id:
		hud.update_target(int(d.get("hp", 0)), int(d.get("max_hp", 1)))

# Statuseffekte einer Figur / eines Monsters (Meldung buffs, Ziel-Info): Restzeit -> Ende auf der eigenen Uhr
func _set_buffs(id: int, list: Array) -> void:
	var now = Time.get_ticks_msec()
	var out = []
	for e in list:
		if e is Array and e.size() >= 4:
			out.append([int(e[0]), int(e[1]), now + int(e[2]) if int(e[2]) > 0 else 0, int(e[3]), int(e[4]) if e.size() > 4 else -1])
	if out.is_empty():
		buffs.erase(id)
	else:
		buffs[id] = out
	if hud != null:
		if id == my_id:
			hud.set_buffs(out)
		if id == target_id and hud.target_id == id:
			hud.set_target_buffs(out)
	_update_buff_gfx(id)

# Figur / Monster aus der Sicht (oder tot): Effekte und ihre GFX weg
func _forget_buffs(id: int) -> void:
	buffs.erase(id)
	for n in _buff_gfx.get(id, {}).get("nodes", {}).values():
		if is_instance_valid(n):
			n.queue_free()
	_buff_gfx.erase(id)

# GFX der Effekte am Modell wie CECPlayer / CECNPC::SetNewExtendStates: je sichtbarem Zustand (light der Vorlage) das
# GFX aus buff_gfx.lua (angelica_buffs.gd gfx) am Haken bzw. an der Figur, solange ein Effekt mit ihm liegt; Spieler
# nach Rasse / Klasse, NPCs und Monster mit dem Eintrag 0. Neues Modell (Ausrüstung, nachgebautes NPC) -> neu anhängen
func _update_buff_gfx(id: int) -> void:
	var node = _node_of(id)
	var model = node.get("model") if node != null else null
	var mid = model.get_instance_id() if is_instance_valid(model) else 0
	var g: Dictionary = _buff_gfx.get(id, {"model": mid, "nodes": {}})
	var nodes: Dictionary = g["nodes"]
	var want = {}
	if node != null and buff_data != null and attack_fx != null and attack_fx.importer != null:
		for e in buffs.get(id, []):
			if int(e[4]) >= 0:
				want[int(e[4])] = true
	for light in nodes.keys():
		if not want.has(light) or not is_instance_valid(nodes[light]) or int(g["model"]) != mid:
			if is_instance_valid(nodes[light]):
				nodes[light].queue_free()
			nodes.erase(light)
	g["model"] = mid
	var rp = Vector2i.ZERO
	if node == player:
		rp = Vector2i(int(info["char"]["race"]), int(info["char"]["class"]))
	elif node is RemotePlayer:
		rp = Vector2i(node.race, node.cls)
	for light in want:
		if not nodes.has(light):
			var f: Array = buff_data.gfx(rp.x, rp.y, light)
			var n = attack_fx.attach(node, model, f[0], f[1]) if not f.is_empty() else null
			if n != null:
				nodes[light] = n
	if nodes.is_empty():
		_buff_gfx.erase(id)
	else:
		_buff_gfx[id] = g

# Wirkung eines Treffers beim Einschlag (attack_fx.gd): Zahl, Treffer-Aktion, Leben
func _hit_result(d: Dictionary, dst) -> void:
	if hud == null or not is_instance_valid(dst):
		return
	var text = hud.texts()["miss"] if d.get("miss", false) else str(int(d.get("dmg", 0)))
	var color = COLOR_HURT if dst == player else (COLOR_CRIT if d.get("crit", false) else COLOR_DAMAGE)
	_float_text(dst, text + ("!" if d.get("crit", false) else ""), color, d.get("crit", false))
	if dst == player:
		hud.set_stats({"hp": int(d.get("hp", 0)), "max_hp": int(d.get("max_hp", 1))})
		info["hp"] = int(d.get("hp", 0))
		player.play_hurt()
	else:
		if dst.has_method("play_hurt") and not d.get("miss", false):
			dst.play_hurt()
		if int(d.get("dst", 0)) == target_id:
			hud.update_target(int(d.get("hp", 0)), int(d.get("max_hp", 1)))

# Schwebende Zahl über einer Figur
func _float_text(node: Node3D, text: String, color: Color, big: bool) -> void:
	var l = Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0009 if big else 0.0007
	l.font_size = 40
	l.outline_size = 10
	l.modulate = color
	l.render_priority = 2
	add_child(l)
	var h = float(node.get("height")) if node.get("height") != null else 1.8
	var from = node.global_position + Vector3(randf_range(-0.3, 0.3), h + 0.3, 0)
	l.global_position = from
	var tw = create_tween()
	tw.tween_property(l, "global_position", from + Vector3(0, 1.2, 0), FLOAT_TIME)
	tw.parallel().tween_property(l, "modulate:a", 0.0, FLOAT_TIME * 0.6).set_delay(FLOAT_TIME * 0.4)
	tw.tween_callback(l.queue_free)

func _my_death() -> void:
	stop_attack()
	cancel_route()
	attacking = 0
	if not gathering.is_empty():
		gathering = {}
		hud.set_progress("", 0.0)
	player.die()
	if hud != null:
		hud.close_npc()
		hud.show_revive(true)

func _revive() -> void:
	var r = await session.revive()
	if hud == null:
		return
	if r["code"] != Proto.Code.OK:
		hud.add_system(Proto.text(r["code"], login.language))
		hud.d_revive_enable(true)
		return
	player.revive()
	hud.show_revive(false)

func _on_npc_option(command: int, task: int) -> void:
	var npc = talk_npc
	var r = {}
	match command:
		QuestData.NPC_GIVE_TASK:
			r = await session.quest_accept(npc, task)
		QuestData.NPC_COMPLETE_TASK:
			r = await session.quest_complete(npc, task)
		QuestData.TALK_GIVEUP_TASK:
			r = await session.quest_abandon(int(quest_data.top_of(quest_data.task(task)).get("id", task)))
	if hud == null:
		return
	if r.get("code", Proto.Code.OK) != Proto.Code.OK:
		hud.add_system(Proto.text(r["code"], login.language))

# "Aufgeben" im Quest-Fenster
func _abandon(id: int) -> void:
	var r = await session.quest_abandon(id)
	if hud != null and r["code"] != Proto.Code.OK:
		hud.add_system(Proto.text(r["code"], login.language))

# Verfolgung und Symbole über den NPCs nach dem Quest-Zustand
func _refresh_quests() -> void:
	if quest_data == null or quest_data.tasks == null or hud == null:
		return
	hud.set_trace(quest_data.trace(func(tid): return npc_data.info(tid)["name"]))
	hud.refresh_quests()
	for n in npcs.values():
		if npc_data.info(n.tid)["npc"]:
			n.set_quest_icon(_icon(quest_data.head_icon(n.tid)))

func _icon(icon_name: String) -> Texture2D:
	if icon_name == "":
		return null
	if not _icons.has(icon_name):
		_icons[icon_name] = quest_data.icon_atlas(icon_name)
	return _icons[icon_name]

# quest_event: Meldung im Chat (neu, erfüllt mit Belohnung, gescheitert)
func _quest_event(d: Dictionary) -> void:
	if hud == null or quest_data == null:
		return
	var t: Dictionary = quest_data.task(int(d.get("id", 0)))
	var tx: Dictionary = hud.texts()
	var shown = not t.is_empty() and not quest_data.hidden(t) and t["parent"] == 0
	match str(d.get("kind", "")):
		"new":
			if shown:
				hud.add_info(tx["quest_new"] % Hud._plain(str(t["name"])))
		"done":
			if shown:
				hud.add_info(tx["quest_done"] % Hud._plain(str(t["name"])))
		"failed":
			if shown:
				hud.add_info(tx["quest_failed"] % Hud._plain(str(t["name"])))
	if int(d.get("exp", 0)) != 0:
		hud.add_info(tx["gain_exp"] % int(d["exp"]))
	if int(d.get("gold", 0)) != 0:
		hud.add_info(tx["gain_gold"] % int(d["gold"]))
	for it in d.get("items", []):
		var item_name = npc_data.elements.name_of(int(it[0])) if npc_data.elements != null else str(it[0])
		hud.add_info(tx["gain_item"] % [Hud._plain(item_name), int(it[1])])
	if str(d.get("kind", "")) == "bag_full":
		hud.add_system(tx["bag_full_quest"])

# stats: Stufe, EXP, Leben, Mana, Geld
# Schnellleiste: Platz belegen / leeren (Server prüft, dann der HUD)
func _set_shortcut(bar: int, slot: int, id: int) -> void:
	var r = await session.shortcut(bar, slot, id)
	if hud == null:
		return
	if r["code"] == Proto.Code.OK:
		hud.set_shortcut(bar, slot, id)
		_skills_state = _skills_export()
	else:
		hud.add_system(Proto.text(r["code"], login.language))

func _skills_seen(ids: Array) -> void:
	await session.skill_seen(ids)
	_skills_state = _skills_export()

# Zustand des HUD im Format von world_ready (Skin-Wechsel baut den HUD neu)
func _skills_export() -> Dictionary:
	if hud == null:
		return _skills_state
	var st: Dictionary = hud.skill_state
	var sc = []
	for k in st["shortcuts"]:
		sc.append([k.x, k.y, st["shortcuts"][k]])
	var sk = []
	for id in st["skills"]:
		sk.append([id, st["skills"][id]])
	return {"skills": sk, "new": st["new"].duplicate(), "shortcuts": sc}

func _set_stats(d: Dictionary) -> void:
	var old_level = int(info["char"].get("level", 1))
	for k in ["exp", "exp_next", "hp", "max_hp", "mp", "max_mp", "money"]:
		if d.has(k):
			info[k] = d[k]
	if d.has("level"):
		info["char"]["level"] = int(d["level"])
		if skill_data != null:
			skill_data.host_level = int(d["level"])
		if quest_data != null:
			quest_data.player["level"] = int(d["level"])
		if hud != null:
			hud.me["level"] = int(d["level"])
	if d.has("speed_add") and player != null:
		player.speed_add = float(d["speed_add"])
	if hud != null:
		hud.set_stats(d)
		if int(d.get("level", old_level)) > old_level:
			hud.add_info(hud.texts()["level_up"] % int(d["level"]))

func _say(text: String) -> void:
	var r = await session.say(text)
	if r["code"] != Proto.Code.OK and hud != null:
		hud.add_system(Proto.text(r["code"], login.language))


# ====================================================
# TASTEN, VERLASSEN
# ====================================================
# Tab vor der GUI (sonst wandert der Fokus in die Chat-Eingabe)
func _input(event: InputEvent) -> void:
	var k = event as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == KEY_TAB and ready_in_world and not aui.has_message_box() \
			and (hud == null or not hud.chat_focused()):
		get_viewport().set_input_as_handled()
		tab_target()

func _unhandled_key_input(event: InputEvent) -> void:
	var k = event as InputEventKey
	if k == null or not k.pressed or k.echo or not ready_in_world or aui.has_message_box():
		return
	if hud != null and hud.handle_key(k):
		get_viewport().set_input_as_handled()
		return
	match k.keycode:
		KEY_F1:
			select_target(my_id)
			get_viewport().set_input_as_handled()

# "Wechseln" im Systemmenü: zurück zur Figurenauswahl
func leave() -> void:
	if _leaving:
		return
	_leaving = true
	ready_in_world = false
	if player != null:
		player.input_enabled = false
		session.send_move(player.global_position, player.direction(), Proto.MOVE_STAND)
	await session.world_leave()
	left_world.emit()

# "Verlassen" im Systemmenü: Welt verlassen, abmelden, Spiel beenden
func quit_game() -> void:
	if _leaving:
		return
	_leaving = true
	ready_in_world = false
	if player != null:
		player.input_enabled = false
		session.send_move(player.global_position, player.direction(), Proto.MOVE_STAND)
	await session.world_leave()
	await session.logout()
	session.close()
	get_tree().quit()

# Klänge der Map anhalten (laufen sie beim Beenden noch, hält der Audio-Server sie fest: Lecks)
func stop_sounds() -> void:
	if map_root == null:
		return
	for n in map_root.find_children("*", "AudioStreamPlayer3D", true, false) + map_root.find_children("*", "AudioStreamPlayer", true, false):
		n.stop()

func _exit_tree() -> void:
	stop_sounds()
	if _quest_thread != null and _quest_thread.is_started():
		_quest_thread.wait_to_finish()
	if _skill_thread != null and _skill_thread.is_started():
		_skill_thread.wait_to_finish()
	if _buff_thread != null and _buff_thread.is_started():
		_buff_thread.wait_to_finish()
	if skill_data != null:
		skill_data.close() # Lua-Tabellen und -Funktionen halten sich sonst gegenseitig fest
	for t in [_movemap_thread, _route_thread]:
		if t != null and t.is_started():
			t.wait_to_finish()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	if factory != null:
		factory.free_model()
