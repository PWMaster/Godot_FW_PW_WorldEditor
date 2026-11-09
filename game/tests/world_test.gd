extends SceneTree

# ====================================================
# Test der Spielwelt (client/world_screen.gd) gegen einen laufenden Server; die Startmap s9 muss
# importiert sein (maps_root, Standard res://ECM_Import/maps):
#   godot [--headless | --rendering-driver vulkan | --rendering-method gl_compatibility] --path <Projekt>
#         -s res://game/tests/world_test.gd -- --port=29000 [--shots=<Ordner>]
# Legt ein Konto mit einem Menschen-Krieger an, betritt s9 und prüft: Figur steht auf dem Boden am
# Start, "W" läuft nach vorn, ein zweiter Spieler (eigene Sitzung im selben Prozess) erscheint mit
# Namen und läuft sichtbar mit, der zweite sieht die eigene Figur an ihrer Position, Esc öffnet das
# Systemmenü, "Wechseln" führt zur Figurenauswahl, erneutes "Start" setzt die Figur an die gelaufene
# Stelle.
# Fertigkeiten: das Fenster "Neue Fertigkeiten" zeigt Hieb und Überfall (Tooltip), Ziehen in die Leiste unten, K
# zeigt sie (Tooltip mit Beschreibung), Ziehen in die Leiste rechts, Verschieben, Herausziehen leert,
# Schließen legt den Rest weg, Esc; nach dem Wiedereintritt liegt Hieb noch in der Leiste.
# HUD (Schritt 8): eigener Kopf mit 1500/1500 HP und 500/500 MP, Name der Map auf der Minimap, Tab
# wählt ein Monster (Ziel-Fenster, Ring), Klick auf Lady Vestry wählt sie, F1 die eigene Figur, Esc
# wählt ab; Chat: Enter öffnet die Eingabe, "W" läuft dabei nicht, Enter sendet, beide Seiten sehen
# die Nachricht; Systemmenü: "Fenster wechseln" baut das HUD im anderen Skin und zurück.
# Quests (Schritt 10): Verfolgung zeigt "Zerrüttete Zuflucht" mit "Sprecht mit Lady Vestry", Symbol
# über Lady Vestry, zweiter Klick öffnet ihr Fenster, Gespräch bis "abschließen" durchklicken,
# Belohnung (40 EXP, Rüstung) im Chat und im EXP-Balken, Folgequest "Greift zu den Waffen!" bei Lady
# Vestry annehmen.
# Autoroute: Klick auf den Quest-Titel der Verfolgung öffnet Win_QuestMinionDes mit Beschreibung und
# NPC-Link, "-" klappt ein, der grüne Link "Adam" führt die Figur über die Wegfindung um die Plattform
# zu Adam, dort geht sein Fenster auf, der Link "Lady Vestry" zurück; NPC in einem anderen Gebiet ->
# Meldung; Klick auf die Minimap startet eine Autoroute (Ziel-Marke), W bricht sie ab.
# Inventar und Ausrüstung (Schritt 10b): B öffnet das Inventar mit der Rüstung (Symbol, Belegung,
# Tooltip), Rechtsklick legt sie an (anderes Modell), C zeigt sie und Verteidigung 94; über den Link
# "Johnny" zu ihm (Teil 7994), die Verfolgung zeigt "Novizen-Langschwert 0/1 (Waffenregal)", der Link
# führt zum Regal, Klick darauf sammelt (Fortschrittsbalken), das Schwert liegt in der Tasche,
# Ziehen auf den Waffenplatz legt es an (Waffe außerhalb des Kampfes auf dem Rücken der Figur und im Figurenbild, Angriff
# 296-316), Rechtsklick legt ab und wieder an, Johnny schließt 5679 ab (Stufe 2).
# Kampf (Schritt 9): Johnny gibt 5680, die Verfolgung zählt die Beute; zweiter Klick auf ein Wildschwein
# läuft hin und greift an (Angriffs-Aktion, schwebende Zahlen, Leben im Ziel-Fenster), W beendet den
# Angriff, das Wildschwein schlägt zurück, stirbt sichtbar, Chat "6 EXP"; zehn Stück, 5680 bei Lady
# Vestry abschließen; jeder Treffer zeigt beim Einschlag (Angriffspunkt der Aktion) sein Treffer-GFX, erst
# dann die Zahl; ein Magier schießt seinen Energieball (Flug-GFX) und die Wirkung kommt mit dem Einschlag;
# im Kampf hängt das Schwert in der Hand, 6 s danach wieder auf dem Rücken; ein
# Assassine trägt zwei Dolche (Gürtel, im Kampf in beiden Händen, der linke wirbelt im Angriff 1);
# Statuseffekte (F3): Client merkt sich buffs, zeigt Brand-Schaden / Heilung als Zahlen; Anzeige (F4): eigene
# Effekte in Win_Buff (Symbol, Restzeit, Stapel, Reihen), Brennen im Ziel-Fenster, Tooltips, Flammen-GFX am Monster;
# Fertigkeiten (F2): Taste 2 ohne Ziel -> Meldung, Hieb auf ein Wildschwein (hinlaufen, Aktion, Zauberbalken,
# Treffer, Mana, Abklingzeit-Uhr, gleich wieder -> "noch nicht bereit", nach 3 s bereit); Magier-Feuerball
# an einer gebauten Figur (Aktion nachgebaut, Feuer in der Hand, Feuerball fliegt mit elapsed sofort);
# ohne Ausrüstung bei den Giftjagdhunden sterben (Win_Message4), "Wiederbeleben"
# bringt die Figur zum Wiederbelebungspunkt.
# NPCs und Monster: erscheinen mit Modell (importiert oder, wenn nicht, zur Laufzeit gebaut), Lady Vestry
# mit Namen in NPC-Farbe, alle stehen auf dem Boden des Clients, der zweite Spieler kennt sie an
# derselben Stelle, ein umherlaufendes Monster kommt genau am Ziel des Servers an.
# Ende: "WELT-TEST OK" (Exit 0) oder "WELT-TEST FEHLER" (Exit 1), nach 420 s Abbruch (Exit 2).
# ====================================================

const Settings = preload("../common/settings.gd")
const Proto = preload("../common/protocol.gd")
const Net = preload("../common/net.gd")
const Session = preload("../client/session.gd")
const LoginScreen = preload("../client/login_screen.gd")
const NpcData = preload("../client/npc_data.gd")
const VESTRY = 14429
const ADAM = 14432
const JOHNNY = 21041
const RACK = 13533
const SWORD = 15612
const ARMOR = 15613
const BOAR = 14563
const BOAR_LOOT = 14533
const DAGGER = 15436 # Novizen-Assassinenklinge
const STAFF = 15452 # Novizen-Magiestab
const HOUNDS_AT = Vector3(20.0, 82.0, 84.0)
const PASSWORD = "geheim-123"
const LOOK = {"face": 0, "mask": 0, "hair": 1, "skin": 0, "hair_color": 0x902E1E}

var shots = ""
var port = Proto.DEFAULT_PORT
var ls
var checks = 0
var failures = 0
var other_pushes = []
var _corrections = 0
var _sk_cool = false # Hieb: Meldung cooldown gesehen
var _sk_mp = [-1, -1] # Mana vor / nach der Wirkung (stats vor bzw. direkt nach cooldown)


func _initialize() -> void:
	var args = Settings.user_args()
	shots = str(args.get("shots", ""))
	port = int(args.get("port", str(Proto.DEFAULT_PORT)))
	var game = load("res://game/main.tscn").instantiate()
	root.add_child(game)
	create_timer(1000.0).timeout.connect(func(): _end(2))
	_run.call_deferred(game)

func _run(game: Node) -> void:
	await _frames(5)
	ls = game.get_node_or_null("Login")
	if ls == null:
		_check("Login im Spielstil", false)
		_end(1)
		return
	# Konto und Figur über die Sitzung des Clients, dann "Start" wie im Spiel
	var acc = "Wt_%05d" % (randi() % 100000)
	await ls.session.register(acc, PASSWORD)
	ls.dlg_login.set_text("DEFAULT_Txt_Account", acc)
	ls.dlg_login.set_text("Txt_PassWord", PASSWORD)
	ls._on_login_command("Btn_Login")
	await _until(func(): return ls.state == LoginScreen.State.SELECT_CHAR and ls.chars.dlg_list.visible)
	var hero = "Wanderer%03d" % (randi() % 1000)
	var r = await ls.session.create_char(hero, 1, 1, 0, LOOK)
	_check("Figur %s angelegt" % hero, r["code"] == Proto.Code.OK)
	await ls.chars.refresh()
	ls.chars.show_list()
	ls.chars._on_enter_command("Btn_EnterWorld")
	await _until(func(): return ls.world != null and ls.world.ready_in_world, 90.0)
	var w = ls.world
	ls.session.net.pushed.connect(func(what, _d): if what == "pos_correct": _corrections += 1)
	_check("Welt s9 geladen (%s)" % ", ".join(w.warnings if w != null else []), w != null and w.ready_in_world and w.map_root != null)
	if w == null or not w.ready_in_world:
		_end(1)
		return
	_check("Map hat Licht (%s)" % ("aus dem Import" if w.light_added == "" else "ergänzt: " + w.light_added),
		w.map_root.get_node_or_null("Sun") is DirectionalLight3D and w.map_root.get_node_or_null("Environment") is WorldEnvironment)
	await _physics(20)
	var p = w.player
	var start = p.global_position
	_check("Figur steht auf dem Boden am Start", p.is_on_floor() and Vector2(start.x + 144.556, start.z - 34.636).length() < 1.5)
	await _shot("1_world")

	# zweiter Spieler
	var other = await _second_player()
	_check_ok("zweiter Spieler in der Welt", other != null)
	if other == null:
		_end(1)
		return
	await _until(func(): return not w.remotes.is_empty(), 5.0)
	_check("zweiter Spieler erscheint mit Namen", w.remotes.size() == 1 and w.remotes.values()[0].label.text.begins_with("Gast"))
	await _npcs(w)
	await _skills(w) # schließt das Fenster "Neue Fertigkeiten" (es läge sonst über der Welt)
	await _hud(w, other)
	await _quests(w)
	var seen_me = []
	other.net.state_received.connect(func(entries): seen_me.append(entries))

	# "W" 1,5 s halten
	_key(KEY_W, true)
	await create_timer(1.5).timeout
	_key(KEY_W, false)
	await _physics(10)
	await _until(func(): return p.state == Proto.MOVE_STAND, 3.0) # am Hang: erst landen
	var moved = p.global_position
	_check("W läuft (%.1f m)" % Vector2(moved.x - start.x, moved.z - start.z).length(), Vector2(moved.x - start.x, moved.z - start.z).length() > 3.0)
	_check("Lauf-Animation lief, jetzt Stehen", p.state == Proto.MOVE_STAND)
	# zweiter Spieler läuft 2 m zur Seite
	var o_pos: Vector3 = other.get_meta("pos")
	for i in 10:
		o_pos.x += 0.2
		other.send_move(o_pos, 1.5, Proto.MOVE_RUN)
		await create_timer(0.1).timeout
	other.send_move(o_pos, 1.5, Proto.MOVE_STAND)
	await create_timer(0.8).timeout
	var remote = w.remotes.values()[0]
	_check("zweiter Spieler läuft sichtbar mit", remote.position.distance_to(o_pos) < 0.3)
	var me = func():
		for entries in seen_me:
			for e in entries:
				if absf(e[1] - moved.x) < 0.5 and absf(e[3] - moved.z) < 0.5:
					return true
		return false
	_check("der zweite sieht die eigene Figur dort", await _until_ok(me, 3.0))
	await _shot("2_moved")

	# Esc -> Systemmenü -> "Wechseln" -> Figurenauswahl, dann wieder hinein
	_key(KEY_ESCAPE, true)
	_key(KEY_ESCAPE, false)
	await _until(func(): return w.hud.menu_open())
	_check("Esc öffnet das Systemmenü", w.hud.menu_open())
	await _shot("5_menu")
	w.hud.dlg("Quit").send("Btn_Return")
	await _until(func(): return ls.state == LoginScreen.State.SELECT_CHAR and ls.chars.dlg_list.visible, 10.0)
	_check("zurück in der Figurenauswahl", ls.state == LoginScreen.State.SELECT_CHAR and ls.world == null)
	ls.chars._on_enter_command("Btn_EnterWorld")
	await _until(func(): return ls.world != null and ls.world.ready_in_world, 90.0)
	await _physics(10)
	var again = ls.world.player.global_position if ls.world != null and ls.world.player != null else Vector3.ZERO
	_check("wieder an der gelaufenen Stelle", Vector2(again.x - moved.x, again.z - moved.z).length() < 0.5)
	var h2 = ls.world.hud if ls.world != null else null
	_check("nach dem Wiedereintritt: Hieb auf Platz 2 unten, kein Fenster 'Neue Fertigkeiten'", h2 != null
		and h2.skill_at("bar0", 1) == 122 and h2.skill_at("bar0", 0) == 0 and not h2.new_skills_shown())
	other.close()
	_end(0 if failures == 0 else 1)

# Fertigkeiten: Fenster "Neue Fertigkeiten" mit den Startfertigkeiten, Ziehen in die Leisten, K, Tooltips,
# Verschieben in der Leiste, Herausziehen leert, Schließen legt den Rest weg
func _skills(w) -> void:
	var h = w.hud
	var sd = w.skill_data
	_check("Fertigkeiten-Skripte geladen", sd != null)
	if sd == null:
		return
	await _until(func(): return h.new_skills_shown(), 3.0)
	var pop = h.dlg(h.NEW_SKILLS)
	var icons = [0, 1].map(func(i): return h.skill_control("new", i).get_node("Symbol").texture != null)
	_check("Fenster 'Neue Fertigkeiten' mit Hieb und Überfall (Symbole %s)" % str(icons), h.new_skills_shown()
		and h.skill_state["new"] == [122, 1581] and icons == [true, true])
	h._on_skill_hover("new", 0)
	_check("Tooltip im Fenster: %s" % h.tooltip_text().get_slice("\n", 0).strip_edges(), h.tooltip_text().contains(sd.skill_name(122)))
	await _shot("3_new_skills")
	h._skill_drop(Vector2.ZERO, {"skill": 122, "from": "new", "idx": 0}, "bar0", 0)
	await _until(func(): return h.skill_at("bar0", 0) == 122, 3.0)
	_check("Hieb in die Leiste unten gezogen, im Fenster bleibt Überfall", h.skill_at("bar0", 0) == 122
		and h.skill_control("bar0", 0).get_node("Symbol").texture != null and h.skill_state["new"] == [1581])
	_key(KEY_K, true)
	_key(KEY_K, false)
	await _until(func(): return h.window_open(h.SKILLS), 3.0)
	var d = h.dlg(h.SKILLS)
	var names = [1, 2, 3].map(func(i): return str(d.get_text("Txt_%02d" % i)).get_slice("\n", 0))
	_check("K öffnet die Fertigkeiten: %s" % str(names), h.window_open(h.SKILLS) and names == [sd.skill_name(120), sd.skill_name(122),
		sd.skill_name(1581)] and h.skill_control("skill", 1).get_node("Symbol").texture != null)
	h._on_skill_hover("skill", 1)
	var tip = h.tooltip_text()
	_check("Tooltip mit Beschreibung (%d Zeilen)" % tip.count("\n"), tip.contains(sd.skill_name(122)) and tip.count("\n") >= 4)
	await _shot("3_skills")
	h._skill_drop(Vector2.ZERO, {"skill": 1581, "from": "skill", "idx": 2}, "bar1", 2)
	await _until(func(): return h.skill_at("bar1", 2) == 1581, 3.0)
	_check("Überfall aus K in die Leiste rechts gezogen", h.skill_at("bar1", 2) == 1581)
	h._on_skill_hover("bar1", 2)
	_check("Tooltip in der Leiste", h.tooltip_text().contains(sd.skill_name(1581)))
	h._skill_drop(Vector2.ZERO, {"skill": 122, "from": "bar0", "idx": 0}, "bar0", 1)
	await _until(func(): return h.skill_at("bar0", 1) == 122 and h.skill_at("bar0", 0) == 0, 3.0)
	_check("in der Leiste verschoben (Platz 1 -> 2)", h.skill_at("bar0", 1) == 122 and h.skill_at("bar0", 0) == 0)
	h._drag_shortcut = Vector2i(1, 2) # wie _skill_drag aus der Leiste rechts, Platz 3
	h._notification(Node.NOTIFICATION_DRAG_END) # nirgends abgelegt
	await _until(func(): return h.skill_at("bar1", 2) == 0, 3.0)
	_check("aus der Leiste herausgezogen: Platz leer", h.skill_at("bar1", 2) == 0)
	pop.send("Btn_Close")
	await _until(func(): return not h.new_skills_shown(), 3.0)
	_check("Schließen legt die übrigen neuen weg", not h.new_skills_shown() and h.skill_state["new"].is_empty())
	_key(KEY_ESCAPE, true)
	_key(KEY_ESCAPE, false)
	await _until(func(): return not h.window_open(h.SKILLS), 3.0)
	_check("Esc schließt die Fertigkeiten", not h.window_open(h.SKILLS))
	h.hide_tooltip()

# Zweite Sitzung mit eigenem Konto und Figur neben dem Start
func _second_player():
	var branch = Node.new()
	branch.name = "Zweiter"
	root.add_child(branch)
	set_multiplayer(SceneMultiplayer.new(), branch.get_path())
	var g = Node.new()
	g.name = "Game"
	branch.add_child(g)
	var n = Net.new()
	n.name = "Net"
	g.add_child(n)
	var s = Session.new()
	s.name = "Session"
	s.port = port
	g.add_child(s)
	var acc = "Wg_%05d" % (randi() % 100000)
	await s.register(acc, PASSWORD)
	var r = await s.login(acc, PASSWORD)
	if r["code"] != Proto.Code.OK:
		return null
	s.net.pushed.connect(func(what, data): other_pushes.append([what, data]))
	r = await s.create_char("Gast%04d" % (randi() % 10000), 1, 6, 1, LOOK)
	r = await s.enter_char(r["data"].get("char", {}).get("id", 0))
	if r["code"] != Proto.Code.OK:
		return null
	var pos: Array = r["data"]["pos"]
	r = await s.world_ready()
	if r["code"] != Proto.Code.OK:
		return null
	s.set_meta("pos", Vector3(pos[0], pos[1], pos[2]))
	return s


# NPCs und Monster in der Welt
func _npcs(w) -> void:
	await _until(func(): return w.npcs.size() > 20, 5.0)
	var with_model = w.npcs.values().filter(func(n): return n.anim != null).size()
	_check("NPCs und Monster erscheinen (%d, %d mit Modell; %d Modelle nicht importiert, %d gebaut)" % [w.npcs.size(),
		with_model, w.missing_models.size(), w.built_models],
		w.npcs.size() > 20 and with_model >= w.npcs.size() - 2)
	var vestry = null
	for n in w.npcs.values():
		if n.tid == VESTRY:
			vestry = n
	_check("Lady Vestry mit Namen in NPC-Farbe (%s)" % (vestry.label.text.replace("\n", " ") if vestry != null else "fehlt"),
		vestry != null and vestry.label.text.length() > 2 and not vestry.label.text.is_valid_int()
		and vestry.label.modulate.is_equal_approx(NpcData._argb(NpcData.NPC_COLOR)))
	await _physics(2)
	var off = []
	for n in w.npcs.values():
		if not n.is_moving():
			var g = n._ground(n.position.x, n.position.y, n.position.z)
			if absf(g - n.position.y) > 0.15:
				off.append("%d %.2f" % [n.tid, g - n.position.y])
	_check("stehen auf dem Boden des Clients (%d daneben %s)" % [off.size(), off.slice(0, 4)], off.size() <= 2)
	# der zweite Spieler kennt sie an derselben Stelle (Ziel, wenn sie laufen)
	var known = {}
	for e in other_pushes:
		if e[0] == "npc_enter":
			for x in e[1]["list"]:
				known[x[0]] = Vector2(x[7][0], x[7][2]) if x[7].size() == 4 else Vector2(x[2], x[4])
		elif e[0] == "npc_move" and known.has(e[1]["id"]):
			known[e[1]["id"]] = Vector2(e[1]["to"][0], e[1]["to"][2])
	var same = 0
	var differ = []
	for id in w.npcs:
		if known.has(id):
			var n = w.npcs[id]
			var at: Vector3 = n.target if n.is_moving() else n.position
			if Vector2(at.x, at.z).distance_to(known[id]) < 0.01:
				same += 1
			else:
				differ.append(id)
	_check("zweiter Spieler: %d an derselben Stelle, %d anders" % [same, differ.size()], same > 20 and differ.is_empty())
	await _shot("2_npcs")
	await _until(func(): return w.npcs.values().any(func(n): return n.is_moving()), 12.0)
	# das nächste laufende (weiter außen kann es während des Gangs aus der Sicht laufen)
	var walker = null
	var best = INF
	for n in w.npcs.values():
		var d = n.position.distance_to(w.player.global_position)
		if n.is_moving() and d < best:
			walker = n
			best = d
	var tid = walker.tid if walker != null else 0
	var goal: Vector3 = walker.target if walker != null else Vector3.ZERO
	if walker != null:
		var end = Time.get_ticks_msec() + 20000
		while is_instance_valid(walker) and walker.is_moving() and Time.get_ticks_msec() < end:
			goal = walker.target # bekommt es unterwegs ein neues Ziel (npc_move), zählt das
			await process_frame
		await _frames(2)
	var arrived = walker != null and is_instance_valid(walker) and not walker.is_moving() \
		and Vector2(walker.position.x - goal.x, walker.position.z - goal.z).length() < 0.01
	_check("Monster läuft umher und hält am Ziel des Servers (%s, %.0f m entfernt)" % [str(tid) if tid != 0 else "keins", best], arrived)


# HUD: Werte, Ziel (Tab, Klick, F1, Esc), Chat, Skin-Wechsel
func _hud(w, other) -> void:
	var h = w.hud
	_check("HUD gebaut (Skin %d, %s)" % [h.skin if h != null else 0, ", ".join(h.warnings) if h != null else "fehlt"],
		h != null and h.aui.visible and h.dlg("CharHead") != null and h.dlg("CharHead").visible)
	if h == null:
		return
	var head = h.dlg("CharHead")
	_check("Kopf: Name, Stufe 1, 1500/1500 HP, 500/500 MP (%s, %s, %s, %s)" % [head.get_text("Txt_Name"), head.get_text("Txt_Lv0"),
		head.get_text("Txt_HP"), head.get_text("Txt_MP")], head.get_text("Txt_Name") == w.info["char"]["name"]
		and head.get_text("Txt_Lv0") == "1" and head.get_text("Txt_HP") == "1500/1500" and head.get_text("Txt_MP") == "500/500")
	var title = h.dlg("MiniMap").get_text("Btn_Bar")
	_check("Minimap: %s mit Kartenbild" % title, title == h.map_title and title != "s9" and (title == "Morgenrotland" or ls.language != "Deu")
		and h._radar != null and h._radar.material.get_shader_parameter("has_map"))
	# Tab: Regel aus SelectTargetRule.lua (höchstens R m); am Start steht keins so nah -> nichts gewählt
	var p = w.player.global_position
	var cam_dir = -w.player.camera.global_basis.z
	var expect: Array = w.tab_candidates(p, cam_dir)
	_check("Tab-Regel aus SelectTargetRule.lua (r %s, R %s, Winkel %s)" % [h.tab_rule["r"], h.tab_rule["R"], h.tab_rule["angle"]],
		h.tab_rule["R"] == 20.0 and h.tab_rule["r"] == 5.0)
	_key(KEY_TAB, true)
	_key(KEY_TAB, false)
	await _until(func(): return w.target_id != 0, 2.0)
	_check("Tab am Start: %d Monster in Reichweite, gewählt %d" % [expect.size(), w.target_id],
		(expect.is_empty() and w.target_id == 0) or (not expect.is_empty() and w.target_id == expect[0]) and not h.chat_focused())
	# Kandidaten neben einem Tab-wählbaren Monster: es kommt zuerst, auch hinter der Kamera bis r
	var monster = null
	for n in w.npcs.values():
		var i = w.npc_data.info(n.tid)
		if not i["npc"] and i["tab"]:
			monster = n
	var near: Array = w.tab_candidates(monster.global_position + Vector3(3, 0, 0), Vector3(1, 0, 0)) if monster != null else []
	var far: Array = w.tab_candidates(monster.global_position + Vector3(-15, 0, 0), Vector3(-1, 0, 0)) if monster != null else []
	_check("Tab-Kandidaten: 3 m daneben dabei, 15 m hinter der Kamera nicht", monster != null and monster.id in near
		and not monster.id in far)
	# Monster wie mit Tab auswählen (Server, Fenster, Ring)
	if monster != null:
		w.select_target(monster.id)
	await _until(func(): return w.target_kind == "monster", 3.0)
	_check("Monster als Ziel (%s, Stufe %s)" % [h.dlg("TargetMonster").get_text("Txt_Name"), h.dlg("TargetMonster").get_text("Txt_LV")],
		w.target_kind == "monster" and h.dlg("TargetMonster").visible and h.dlg("TargetMonster").get_text("Txt_LV") == str(monster.level))
	await _frames(2)
	_check("Ring unter dem Ziel", w._ring != null and w._ring.visible and w._ring.global_position.distance_to(w._target_node().global_position) < 0.2)
	await _shot("3_target")
	# Klick auf Lady Vestry (Kamera zu ihr gedreht)
	var vestry = null
	for n in w.npcs.values():
		if n.tid == VESTRY:
			vestry = n
	if vestry != null:
		var d: Vector3 = vestry.global_position - w.player.global_position
		w.player.cam_yaw.rotation.y = atan2(-d.x, -d.z)
		await _frames(3)
		var at = vestry.global_position + Vector3(0, vestry.height * 0.6, 0)
		var screen = w.player.camera.unproject_position(at)
		_click(screen)
		await _until(func(): return w.target_id == vestry.id, 3.0)
	_check("Klick wählt Lady Vestry (NPC-Fenster: %s)" % (h.dlg("TargetNPC").get_text("Txt_Name") if h.dlg("TargetNPC") != null else "-"),
		vestry != null and w.target_id == vestry.id and w.target_kind == "npc" and h.dlg("TargetNPC").visible
		and not h.dlg("TargetMonster").visible)
	_check("Klick auf eine Figur läuft nicht", w.player.target == null)
	_key(KEY_F1, true)
	_key(KEY_F1, false)
	await _until(func(): return w.target_id == w.my_id, 3.0)
	_check("F1 wählt die eigene Figur (%s)" % h.dlg("TargetPlayer").get_text("Txt_Name"), w.target_kind == "player"
		and h.dlg("TargetPlayer").visible and h.dlg("TargetPlayer").get_text("Txt_Name") == w.info["char"]["name"])
	_key(KEY_ESCAPE, true)
	_key(KEY_ESCAPE, false)
	await _frames(3)
	_check("Esc wählt ab", w.target_id == 0 and not h.dlg("TargetPlayer").visible and not h.menu_open())
	# Chat
	_key(KEY_ENTER, true)
	_key(KEY_ENTER, false)
	await _frames(2)
	_check("Enter öffnet die Chat-Eingabe", h.chat_focused())
	var before = w.player.global_position
	_key(KEY_W, true)
	await create_timer(0.5).timeout
	_key(KEY_W, false)
	await _physics(3)
	_check("W läuft beim Tippen nicht", w.player.global_position.distance_to(before) < 0.05)
	h._chat_edit.text = "Hallo aus dem Welt-Test!"
	_key(KEY_ENTER, true)
	_key(KEY_ENTER, false)
	var mine = func(): return h.chat_lines.any(func(l): return l.contains("Hallo aus dem Welt-Test!"))
	_check("Enter sendet, eigene Nachricht im Verlauf", await _until_ok(mine, 3.0) and not h.chat_focused())
	var heard = func(): return other_pushes.any(func(e): return e[0] == "chat" and e[1]["text"] == "Hallo aus dem Welt-Test!")
	_check("zweiter Spieler hört sie", await _until_ok(heard, 3.0))
	await other.say("Hallo zurück vom Gast")
	var theirs = func(): return h.chat_lines.any(func(l): return l.contains("Hallo zurück vom Gast") and l.contains("Gast"))
	_check("Nachricht des zweiten im Verlauf", await _until_ok(theirs, 3.0))
	await _shot("4_chat")
	# Skin wechseln und zurück
	var lines = h.chat_lines.size()
	var skin0 = h.skin
	h.open_menu()
	h.dlg("Quit").send("Btn_ChangeUI")
	await _until(func(): return w.hud != h and w.hud.skin != h.skin, 5.0)
	var h1 = w.hud
	_check("Fenster wechseln: Skin %d, Kopf und Verlauf da" % h1.skin, h1.aui.visible and h1.dlg("CharHead").visible
		and h1.dlg("CharHead").get_text("Txt_HP") == "1500/1500" and h1.chat_lines.size() == lines)
	await _shot("4b_skin%d" % h1.skin)
	h1.open_menu()
	h1.dlg("Quit").send("Btn_ChangeUI")
	await _until(func(): return w.hud != h1, 5.0)
	_check("und zurück zu Skin %d" % w.hud.skin, w.hud.skin == skin0 and w.hud.dlg("CharHead").visible)

# Erste Menschen-Quest über die Oberfläche
func _quests(w) -> void:
	var h = w.hud
	var vestry = null
	var adam = null
	for n in w.npcs.values():
		if n.tid == VESTRY:
			vestry = n
		elif n.tid == ADAM:
			adam = n
	var trace: Array = h.trace_items()
	var vname = w.npc_data.info(VESTRY)["name"]
	_check("Verfolgung: %s" % str(trace), not trace.is_empty() and trace[0].size() >= 3 and trace[0][2].contains(vname))
	_check("Symbol über Lady Vestry (abschließbar)", vestry != null and vestry.quest_icon != null and vestry.quest_icon.visible)
	await _shot("6_quest_icon")
	# zweimal wählen = ansprechen
	w.select_target(vestry.id)
	await _until(func(): return w.target_id == vestry.id, 3.0)
	w.select_target(vestry.id)
	await _until(func(): return h.npc_open(), 5.0)
	var entries: Array = h.npc_entries
	_check("Fenster von Lady Vestry mit 'Aufwachen' (%s)" % str(entries.map(func(e): return e["title"])),
		h.npc_open() and entries.any(func(e): return e["id"] == 5699))
	await _shot("7_npc")
	_check("Teil 1 über das Gespräch abgeschlossen", await _talk_through(w, 5699, 5700))
	_check("Verfolgung: weiter mit 'Was ist passiert?' bei Adam (%s)" % str(h.trace_items()),
		h.trace_items()[0].any(func(l): return l.contains(w.npc_data.info(ADAM)["name"])))
	# Verfolgung: Titel öffnet die Beschreibung, "-" klappt ein / aus, NPC als grüner Link
	var qid = int(h.trace_entries[0]["id"])
	var text: String = h._trace_label.text
	_check("Verfolgung: Adam als grüner Link (%s)" % text.replace("\n", " | "), text.contains("[url=npc:%d][color=%s][u]" % [ADAM, h.LINK_COLOR])
		and text.contains("[url=quest:%d]" % qid) and text.contains("[url=fold:%d]-" % qid))
	h._trace_label.meta_clicked.emit("quest:%d" % qid)
	await _frames(2)
	var des = h.dlg("QuestMinionDes")
	_check("Klick auf den Titel öffnet die Beschreibung links daneben (%s)" % (des.get_text("Txt_Content").left(40) if des != null else "-"),
		h.des_open() and des.get_text("Txt_Content").length() > 20 and des.item("Txt_QuestItem").text.contains("npc:%d" % ADAM)
		and des.position.x + des.size.x <= h.dlg("QuestMinion").position.x + 1.0)
	await _shot("7b_quest_des")
	h._trace_label.meta_clicked.emit("quest:%d" % qid)
	await _frames(2)
	_check("zweiter Klick schließt sie", not h.des_open())
	h._trace_label.meta_clicked.emit("fold:%d" % qid)
	await _frames(1)
	var folded: String = h._trace_label.text
	h._trace_label.meta_clicked.emit("fold:%d" % qid)
	await _frames(1)
	_check("'-' klappt die Quest ein, '+' wieder aus", not folded.contains("npc:%d" % ADAM) and folded.contains("[url=fold:%d]+" % qid)
		and h._trace_label.text == text)
	# zu Adam über den Link: zwischen ihm und Lady Vestry steht eine Plattform
	var from = w.player.global_position
	h._trace_label.meta_clicked.emit("npc:%d" % ADAM)
	await _until(func(): return w.player.following(), 3.0)
	var path: PackedVector3Array = w.player.path
	_check("Link startet die Autoroute (%d Wegpunkte, Ziel-Marke auf der Minimap)" % path.size(), w.routing() and path.size() >= 3
		and h.route_target != null)
	var bends = path.size() >= 3 and _off_line(path, from, adam.global_position) > 1.5
	_check("Weg führt um die Plattform herum", bends)
	await _until(func(): return h.npc_open(), 40.0)
	_check("Figur läuft zu Adam, sein Fenster geht auf (%.1f m)" % w.player.global_position.distance_to(adam.global_position),
		h.npc_open() and w.talk_npc == adam.id and not w.routing() and h.route_target == null)
	await _shot("7c_adam")
	_check("Teil 2 bei Adam", await _talk_through(w, 5700, 5701))
	_check("Verfolgung: zurück zu Lady Vestry als Link", h._trace_label.text.contains("[url=npc:%d]" % VESTRY))
	h._trace_label.meta_clicked.emit("npc:%d" % VESTRY)
	await _until(func(): return h.npc_open(), 40.0)
	_check("zurück bei Lady Vestry über den Link", h.npc_open() and w.talk_npc == vestry.id)
	var done = await _talk_through(w, 5701, 0)
	await _until(func(): return h.chat_lines.any(func(l): return l.contains("40 EXP")), 3.0)
	var lines = h.chat_lines.filter(func(l): return l.contains("ffff00"))
	_check("Quest erfüllt: Meldung, 40 EXP, Gegenstand im Chat (%d Zeilen)" % lines.size(), done and lines.size() >= 3
		and h.chat_lines.any(func(l): return l.contains("40 EXP")))
	_check("Werte: 40 / 70 EXP (Balken %.0f %%)" % h.dlg("QuickBar0").item("Pro_Exp").value, w.info.get("exp") == 40
		and absf(h.dlg("QuickBar0").item("Pro_Exp").value - 100.0 * 40 / 70) < 1.0)
	await _until(func(): return vestry.quest_icon != null and vestry.quest_icon.visible, 3.0)
	_check("Lady Vestry bietet die Folgequest an (Symbol)", vestry.quest_icon != null and vestry.quest_icon.visible)
	# Folgequest annehmen
	w.select_target(vestry.id)
	await _until(func(): return h.npc_open(), 5.0)
	_check("Folgequest 'Greift zu den Waffen!' im Fenster", h.npc_entries.any(func(e): return e["id"] == 5679))
	_check("Folgequest angenommen", await _talk_through(w, 5679, 7994))
	_check("Verfolgung: 5679 (%s)" % str(h.trace_items()), h.trace_items().any(func(t): return t[0].contains(Hud_plain(w.quest_data.task(5679)["name"]))))
	await _shot("8_quest_done")
	# Quest-Fenster (Q)
	_key(KEY_Q, true)
	_key(KEY_Q, false)
	await _until(func(): return h.quest_open(), 3.0)
	var ql: Array = h.quest_list
	_check("Q öffnet das Quest-Fenster mit 5679, Beschreibung, nicht aufgebbar (%s)" % str(ql.map(func(e): return e["name"])),
		h.quest_open() and ql.any(func(e): return e["id"] == 5679 and str(e["description"]).length() > 20)
		and h.quest_selected != 0 and h.dlg("Quest").item("Btn_Abandon").disabled)
	await _shot("9_quests")
	_key(KEY_ESCAPE, true)
	_key(KEY_ESCAPE, false)
	await _frames(3)
	_check("Esc schließt das Quest-Fenster", not h.quest_open())
	await _inventory(w)
	await _combat(w)
	# NPC in einem anderen Gebiet
	var far_tid = 0
	for tid in w.quest_data.npc_pos:
		if int(w.quest_data.npc_pos[tid][0]) != int(w.info.get("world", 0)):
			far_tid = tid
			break
	w.route_npc(far_tid)
	await _frames(2)
	var far_name = Hud_plain(str(w.npc_data.info(far_tid)["name"]))
	_check("NPC-Link in ein anderes Gebiet: Meldung (%s)" % far_name, far_tid != 0 and not w.routing()
		and h.chat_lines.back().contains(far_name))
	h.chat_lines.pop_back() # keine Fehlermeldung der Quests
	# Klick auf die Minimap: rechts / links / unten / oben der Mitte, der erste begehbare Punkt (Karte
	# gespiegelt: rechts = Welt -x)
	var area: Control = h._radar_marks
	var off = Vector2.ZERO
	for r in [20, 10, 30, 40]:
		for a in 8:
			var o = Vector2(r, 0).rotated(a * PI / 4.0).round()
			var wp = h.radar_to_world(o)
			var c = w.movemap.cell_of(wp.x, wp.y) if w.movemap != null else Vector2i.ZERO
			if off == Vector2.ZERO and w.movemap != null and w.movemap.passable(0, c.x, c.y):
				off = o
	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = area.size / 2.0 + off
	var expect = h.radar_to_world(off)
	var me_pos = w.player.global_position
	area.gui_input.emit(ev)
	await _until(func(): return w.player.following(), 3.0)
	var mirrored = (off.x > 0 and expect.x < me_pos.x) or (off.x < 0 and expect.x > me_pos.x) or (off.y > 0 and expect.y < me_pos.z) \
		or (off.y < 0 and expect.y > me_pos.z)
	_check("Klick auf die Minimap %s startet die Autoroute (Ziel %s, gespiegelt)" % [off, expect], off != Vector2.ZERO and w.routing()
		and h.route_target != null and Vector2(h.route_target.x, h.route_target.z).distance_to(expect) < 0.01 and mirrored)
	await _shot("9b_route")
	_key(KEY_W, true)
	await _physics(3)
	_key(KEY_W, false)
	await _physics(3)
	_check("W bricht die Autoroute ab", not w.routing() and not w.player.following() and h.route_target == null)
	_check("keine Rücksetzung durch den Server beim Laufen (%d)" % _corrections, _corrections == 0)
	var errs = h.chat_lines.filter(func(l): return l.begins_with("^" + h.SYSTEM_COLOR))
	_check("keine Fehlermeldung der Quests im Chat (%s)" % str(errs), errs.is_empty())
	w.select_target(0)
	await _frames(3)

# Inventar, Charakter, Waffenregal, Schwert anlegen, 5679 abschließen
func _inventory(w) -> void:
	var h = w.hud
	var bag_pos = func(id: int) -> int:
		for pos in h.inventory["bag"]:
			if h.inventory["bag"][pos][0] == id:
				return pos
		return -1
	_key(KEY_B, true)
	_key(KEY_B, false)
	await _until(func(): return h.window_open(h.INVENTORY), 3.0)
	var inv = h.dlg(h.INVENTORY)
	var apos = bag_pos.call(ARMOR)
	var slot: Control = inv.item("Item_%02d" % apos) if apos >= 0 else null
	_check("B öffnet das Inventar: Rüstung mit Symbol, Belegung %s" % inv.get_text("Txt_BagNum"), h.window_open(h.INVENTORY)
		and slot != null and slot.get_node("Symbol").texture != null and inv.get_text("Txt_BagNum") == "1/24"
		and inv.item("Item_30").get_node("Sperre").visible)
	h._on_slot_hover("bag", apos)
	var tip: String = h.tooltip_text()
	var armor_name = Hud_plain(w.item_data.info(ARMOR)["name"])
	_check("Tooltip: %s" % tip.replace("\n", " | "), tip.contains(armor_name) and tip.contains("34"))
	await _shot("10_inventory")
	h.hide_tooltip()
	var body_before = _skin(w.player.model, "body")
	_right_click(slot)
	await _until(func(): return h.inventory["equip"].get(3, 0) == ARMOR, 3.0)
	await _frames(3)
	_check("Rechtsklick legt die Rüstung an, die Figur trägt sie (neuer Körper-Skin)", h.inventory["equip"].get(3, 0) == ARMOR
		and bag_pos.call(ARMOR) < 0 and _skin(w.player.model, "body") != null and _skin(w.player.model, "body") != body_before)
	_key(KEY_C, true)
	_key(KEY_C, false)
	await _until(func(): return h.window_open(h.CHARACTER), 3.0)
	var ch = h.dlg(h.CHARACTER)
	await _frames(5)
	var pv = h.preview
	_check("C öffnet das Charakter-Fenster: Rüstung, Verteidigung %s, Mana %s, %s (Figurenbild %s, Bild %s, %s)" % [ch.get_text("Txt_Defense"),
		ch.get_text("Txt_Mp"), ch.get_text("Txt_Prof1"), h._preview_rect.size, pv.viewport.size if pv != null else "-",
		pv.model.bounds() if pv != null and pv.model != null else "-"], h.window_open(h.CHARACTER) and ch.item("Equip_03").get_node("Symbol").texture != null
		and ch.get_text("Txt_Defense") == "94" and ch.get_text("Txt_Mp").ends_with("/561") and ch.get_text("Txt_Damage") == "196-196"
		and h.preview != null and h.preview.model.root != null)
	await _shot("11_character")
	_key(KEY_ESCAPE, true)
	_key(KEY_ESCAPE, false)
	await _frames(3)
	_check("Esc schließt Inventar und Charakter", not h.window_open(h.INVENTORY) and not h.window_open(h.CHARACTER))
	# zu Johnny über den Link in der Verfolgung
	_check("Verfolgung: Johnny als Link", h._trace_label.text.contains("[url=npc:%d]" % JOHNNY))
	h._trace_label.meta_clicked.emit("npc:%d" % JOHNNY)
	await _until(func(): return h.npc_open(), 60.0)
	var johnny = w.npcs.get(w.talk_npc)
	_check("Autoroute zu Johnny, sein Fenster geht auf", h.npc_open() and johnny != null and johnny.tid == JOHNNY)
	_check("Teil 7994 bei Johnny", await _talk_through(w, 7994, 8366))
	var text: String = h._trace_label.text
	var sword_name = Hud_plain(w.item_data.info(SWORD)["name"])
	_check("Verfolgung: %s 0/1 mit Link zum Waffenregal" % sword_name, text.contains(sword_name + " 0/1") and text.contains("[url=pos:"))
	var at = text.find("[url=pos:")
	var meta = text.substr(at + 5, text.find("]", at) - at - 5)
	h._trace_label.meta_clicked.emit(meta)
	await _until(func(): return w.player.following(), 3.0)
	_check("Koordinaten-Link startet die Autoroute (%s)" % meta, w.routing())
	await _until(func(): return not w.routing(), 40.0)
	var rack = null
	for n in w.npcs.values():
		if n.tid == RACK:
			rack = n
	_check("am Waffenregal angekommen (%.1f m)" % (w.player.global_position.distance_to(rack.global_position) if rack != null else -1.0),
		rack != null and w.player.global_position.distance_to(rack.global_position) < 8.0 and rack.model != null)
	await _shot("12_rack")
	w.select_target(rack.id)
	await _until(func(): return h.progress_shown(), 10.0)
	_check("Klick auf das Regal: Sammeln mit Fortschrittsbalken (%s)" % h.dlg(h.PROGRESS).get_text("Txt_info"), h.progress_shown())
	await _shot("13_gather")
	await _until(func(): return bag_pos.call(SWORD) >= 0 and not h.progress_shown(), 10.0)
	await _until(func(): return w.quest_data.is_active(7997), 3.0)
	_check("Schwert in der Tasche (Chat), 8366 erfüllt, weiter mit 7997", bag_pos.call(SWORD) >= 0 and w.quest_data.is_active(7997)
		and h.chat_lines.any(func(l): return l.contains(sword_name)))
	# Ziehen auf den Waffenplatz
	_key(KEY_B, true)
	_key(KEY_B, false)
	_key(KEY_C, true)
	_key(KEY_C, false)
	await _frames(3)
	var drag = {"kind": "bag", "idx": bag_pos.call(SWORD), "id": SWORD}
	_check("Waffenplatz nimmt das Schwert an, der Körperplatz nicht", h._slot_can_drop(Vector2.ZERO, drag, "equip", 0)
		and not h._slot_can_drop(Vector2.ZERO, drag, "equip", 3))
	h._slot_drop(Vector2.ZERO, drag, "equip", 0)
	await _until(func(): return h.inventory["equip"].get(0, 0) == SWORD, 3.0)
	await _frames(5)
	var weapon = w.player.model.get_node_or_null("Skeleton3D/Waffe")
	_check("Schwert angelegt: an der Figur (außerhalb des Kampfes auf dem Rücken: %s) und im Figurenbild, Angriff %s, Leben %s" % [
		weapon.bone_name if weapon != null else "-", ch.get_text("Txt_Damage"), ch.get_text("Txt_Hp")],
		h.inventory["equip"].get(0, 0) == SWORD and weapon != null and weapon.get_child_count() > 0 and weapon.bone_name == "HH_背_巨剑"
		and h.preview.model.weapon != null and ch.get_text("Txt_Damage") == "296-316" and ch.get_text("Txt_Hp").ends_with("/1674"))
	await _shot("14_sword")
	_right_click(ch.item("Equip_00"))
	await _until(func(): return bag_pos.call(SWORD) >= 0, 3.0)
	await _frames(3)
	_check("Rechtsklick legt das Schwert ab (wieder in der Tasche, keine Waffe an der Figur)", bag_pos.call(SWORD) >= 0
		and w.player.model.get_node_or_null("Skeleton3D/Waffe") == null)
	_right_click(inv.item("Item_%02d" % bag_pos.call(SWORD)))
	await _until(func(): return h.inventory["equip"].get(0, 0) == SWORD, 3.0)
	_check("und wieder angelegt", h.inventory["equip"].get(0, 0) == SWORD)
	h.close_window(h.INVENTORY)
	h.close_window(h.CHARACTER)
	h._trace_label.meta_clicked.emit("npc:%d" % JOHNNY)
	await _until(func(): return h.npc_open(), 40.0)
	var done = await _talk_through(w, 7997, 0)
	await _until(func(): return int(h.stats.get("level", 1)) == 2, 3.0)
	_check("5679 bei Johnny abgeschlossen: Stufe 2", done and int(h.stats.get("level", 1)) == 2
		and w.quest_data.task(5679) != {} and not w.quest_data.is_active(5679))

# Kampf: 5680 (zehn Wildschweine), Treffer, Tod, EXP; Tod und Wiederbeleben bei den Giftjagdhunden
func _combat(w) -> void:
	var h = w.hud
	var me = w.my_id
	var hits_on_me = [0]
	var my_hits = [0]
	var first_hit_ms = [0] # Zeit der ersten eigenen Treffer-Meldung
	var first_hit = {} # ihre Daten (verfehlt: Leben bleibt)
	ls.session.net.pushed.connect(func(what, d): if what == "hit" and int(d["dst"]) == me: hits_on_me[0] += 1)
	ls.session.net.pushed.connect(func(what, d): if what == "hit" and int(d["src"]) == me: my_hits[0] += 1)
	ls.session.net.pushed.connect(func(what, d): if what == "hit" and int(d["src"]) == me and first_hit.is_empty(): first_hit.merge(d))
	ls.session.net.pushed.connect(func(what, d): if what == "hit" and int(d["src"]) == me and first_hit_ms[0] == 0: first_hit_ms[0] = Time.get_ticks_msec())
	await create_timer(0.5).timeout
	w.route_npc(JOHNNY)
	await _until(func(): return h.npc_open(), 40.0)
	_check("Johnny bietet 5680 'Wetzt Eure Knochen' an", h.npc_open() and h.npc_entries.any(func(e): return e["id"] == 5680))
	_check("5680 angenommen", await _talk_through(w, 5680, 5680))
	var loot_name = Hud_plain(w.item_data.info(BOAR_LOOT)["name"])
	_check("Verfolgung: %s 0/10" % loot_name, h._trace_label.text.contains(loot_name + " 0/10"))
	var killed = 0
	var back_checked = false # Gegenangriff geprüft (stirbt das erste am ersten Schlag - Krit -, zählen die übrigen)
	for k in 10:
		var boar = _nearest(w, BOAR)
		if boar == null:
			break
		var bid: int = boar.id # das Modell wird nach dem Tod freigegeben
		w.select_target(bid)
		await _until(func(): return w.target_id == bid, 3.0)
		w.select_target(bid)
		var started = func(): return w.attacking == bid or (k == 0 and my_hits[0] > 0) # Krit kann es sofort töten
		await _until(started, 30.0)
		if k == 0:
			_check("zweiter Klick auf das Wildschwein: hinlaufen und angreifen", started.call())
			await _until(func(): return my_hits[0] > 0, 6.0)
			await _frames(1)
			var early = w.get_children().filter(func(c): return c is Label3D).size()
			await _until(func(): return w.get_children().any(func(c): return c is Label3D), 3.0)
			var delay = Time.get_ticks_msec() - first_hit_ms[0]
			var hit_fx = w.attack_fx.get_children().size()
			_check("Einschlag: Treffer-GFX am Wildschwein (%d), Zahl erst danach (%d ms nach der Meldung, vorher %d)" % [hit_fx, delay, early],
				hit_fx > 0 and early == 0 and delay >= 250)
			var act = str(w.player.anim.current_animation)
			var bar = h.dlg("TargetMonster").item("Prg_HP")
			# die erste Zahl kann auch der Gegenschlag sein: auf das Leben im Ziel-Fenster warten
			await _until(func(): return bar == null or bar.value < 100.0 or first_hit.get("miss", false), 2.0)
			var floats = w.get_children().filter(func(c): return c is Label3D)
			_check("Treffer: Aktion %s, %d schwebende Zahlen, Leben im Ziel-Fenster %.0f %%%s" % [act, floats.size(), bar.value if bar != null else -1.0,
				" (verfehlt)" if first_hit.get("miss", false) else ""], my_hits[0] > 0 and not floats.is_empty() and bar != null
				and (bar.value < 100.0 or first_hit.get("miss", false)) and act.begins_with("普通攻击"))
			var held = w.player.model.get_node_or_null("Skeleton3D/Waffe")
			_check("im Kampf: Schwert in der Hand (%s)" % (held.bone_name if held != null else "-"), w.player.fighting and held != null
				and held.bone_name == "HH_righthandweapon")
			await _shot("15_attack")
			_key(KEY_W, true)
			await _physics(2)
			_key(KEY_W, false)
			await _physics(2)
			_check("W beendet den Angriff", w.attacking == 0)
			if w.npcs.has(bid) and not w.npcs[bid].dead:
				await _until(func(): return hits_on_me[0] > 0, 6.0)
				_check("das Wildschwein schlägt zurück (%d Treffer, Leben %s)" % [hits_on_me[0], h.stats.get("hp")], hits_on_me[0] > 0)
				back_checked = true
				w.select_target(bid)
				await _until(func(): return w.attacking == bid, 20.0)
		await _until(func(): return not w.npcs.has(bid), 20.0)
		if w.npcs.has(bid):
			break
		killed += 1
		if k == 0:
			await _until(func(): return not is_instance_valid(boar) or boar.dead, 3.0) # nach dem Einschlag
			_check("Wildschwein stirbt sichtbar, Chat: 6 EXP", is_instance_valid(boar) and boar.dead
				and h.chat_lines.any(func(l): return l.contains("6 EXP")))
			await _shot("16_dead_boar")
	if not back_checked:
		_check("die Wildschweine schlagen zurück (%d Treffer; das erste starb am ersten Schlag)" % hits_on_me[0], hits_on_me[0] > 0)
	await _until(func(): return h._trace_label.text.contains(loot_name + " 10/10"), 3.0)
	_check("zehn Wildschweine (%d), Verfolgung %s 10/10" % [killed, loot_name], killed == 10 and h._trace_label.text.contains(loot_name + " 10/10"))
	w.route_npc(VESTRY)
	await _until(func(): return h.npc_open(), 60.0)
	_check("5680 bei Lady Vestry abgeschlossen (Beute eingezogen)", await _talk_through(w, 5680, 0)
		and w._bag_count(BOAR_LOOT) == 0)
	await _until(func(): return not w.player.fighting, 8.0)
	var back = w.player.model.get_node_or_null("Skeleton3D/Waffe")
	_check("6 s nach dem Kampf: Schwert wieder auf dem Rücken, Stehen %s" % str(w.player.anim.current_animation), not w.player.fighting
		and back != null and back.bone_name == "HH_背_巨剑" and not str(w.player.anim.current_animation).begins_with("战斗"))
	await _skill_cast(w)
	_dual_daggers(w)
	await _mage_projectile(w)
	await _mage_fireball(w)
	# Tod: ohne Ausrüstung bei den Giftjagdhunden
	for slot in [0, 3]:
		h.unequip_requested.emit(slot, -1)
		await _until(func(): return not h.inventory["equip"].has(slot), 3.0)
	w.route_to(HOUNDS_AT, "Giftjagdhunde")
	await _until(func(): return not w.routing(), 90.0)
	for i in 3:
		var hound = _nearest(w, 14578)
		if hound == null or w.player.dead:
			break
		w.select_target(hound.id)
		await _until(func(): return w.target_id == hound.id, 3.0)
		w.select_target(hound.id)
		var hits_before = my_hits[0]
		await _until(func(): return my_hits[0] > hits_before or w.player.dead, 25.0)
		w.stop_attack()
		w.select_target(0)
	await _until(func(): return w.player.dead, 90.0)
	await _frames(5)
	_check("ohne Ausrüstung bei den Giftjagdhunden gestorben: Win_Message4, Sterbe-Aktion, keine Steuerung",
		w.player.dead and h.revive_shown() and not w.player.input_enabled and str(w.player.anim.current_animation).begins_with("死亡"))
	await _shot("17_dead")
	var corrections = _corrections
	h.dlg("Message4").send("Btn_Decide")
	await _until(func(): return not w.player.dead, 5.0)
	await _frames(5)
	_corrections = corrections # das Wiederbeleben setzt die Figur absichtlich um (pos_correct)
	await _physics(5)
	var p = w.player.global_position
	_check("Wiederbeleben: am Wiederbelebungspunkt (%.0f, %.0f), %s HP" % [p.x, p.z, h.stats.get("hp")], not w.player.dead
		and not h.revive_shown() and Vector2(p.x + 151.0, p.z - 42.0).length() < 2.0 and int(h.stats.get("hp", 0)) < int(h.stats.get("max_hp", 0)))
	for e in h.bag_items():
		if e[1] == SWORD or e[1] == ARMOR:
			h.equip_requested.emit(e[0])
	await _until(func(): return h.inventory["equip"].has(0) and h.inventory["equip"].has(3), 5.0)

func _nearest(w, tid: int):
	var best = null
	for n in w.npcs.values():
		if n.tid == tid and not n.dead and (best == null or n.global_position.distance_to(w.player.global_position) < best.global_position.distance_to(w.player.global_position)):
			best = n
	return best

func _skin(model: Node3D, slot: String):
	var sk = model.get_node_or_null("Skeleton3D") if model != null else null
	if sk == null:
		return null
	for c in sk.get_children():
		if c is MeshInstance3D and c.get_meta("slot", "") == slot:
			return c.mesh
	return null

func _right_click(c: Control) -> void:
	if c == null:
		return
	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	c.gui_input.emit(ev)

# Größter Abstand der Wegpunkte von der geraden Linie a -> b (x / z)
static func _off_line(path: PackedVector3Array, a: Vector3, b: Vector3) -> float:
	var a2 = Vector2(a.x, a.z)
	var d = Vector2(b.x, b.z) - a2
	var n = Vector2(-d.y, d.x).normalized()
	var best = 0.0
	for p in path:
		best = maxf(best, absf((Vector2(p.x, p.z) - a2).dot(n)))
	return best

static func Hud_plain(s: String) -> String:
	return load("res://game/client/hud.gd")._plain(s)

# Eintrag id im offenen NPC-Fenster wählen und jeweils die erste Option klicken, bis das Fenster
# zugeht; danach muss next_id laufen (0 = id ist nicht mehr da)
func _talk_through(w, id: int, next_id: int) -> bool:
	var h = w.hud
	var idx = -1
	for i in h._npc_options.size():
		if h._npc_options[i][0] == "entry" and int(h._npc_options[i][1]["id"]) == id:
			idx = i
	if idx < 0:
		return false
	h._on_npc_list(idx)
	for step in 12:
		await _frames(1)
		if not h.npc_open():
			break
		h._on_npc_list(0)
	var ok = func(): return (next_id == 0 and not w.quest_data.is_active(id)) or w.quest_data.is_active(next_id)
	await _until(ok, 3.0)
	return ok.call() and not h.npc_open()

func _click(screen: Vector2) -> void:
	for pressed in [true, false]:
		var ev = InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = screen
		ev.global_position = screen
		Input.parse_input_event(ev)


# ====================================================
# HILFEN
# ====================================================
# Magier (Mensch, Klasse 5) mit dem Novizen-Magiestab greift das nächste Monster an (nur Effekte, ohne
# Server): der Angriffspunkt (750 ms, 法系普攻3.att) schießt den Energieball (Flug-GFX) von der Brust
# zum Ziel, beim Einschlag Treffer-GFX und erst dann die Wirkung
func _mage_projectile(w) -> void:
	var eq = w.equip_models({0: STAFF}, 1, 5, 0)
	var err = w.factory.build(1, 0, 5, LOOK, w._actions({0: STAFF}), eq)
	var mage: Node3D = w.factory.detach() if err == "" else null
	var target = _nearest(w, BOAR)
	if target == null:
		target = _nearest(w, 14578)
	if mage == null or target == null:
		_check("Magier gebaut, Ziel da (%s)" % err, false)
		return
	var holder = Node3D.new()
	w.add_child(holder)
	holder.add_child(mage)
	var to = target.global_position
	var away = Vector3(to.x - w.player.global_position.x, 0, to.z - w.player.global_position.z).normalized()
	holder.global_position = to - (away if away.length() > 0.1 else Vector3.FORWARD) * 10.0
	var pts = w.attack_fx.points_of(mage, "普通攻击1_法杖")
	var t0 = Time.get_ticks_msec()
	var hit_at = [0]
	mage.get_node("AnimationPlayer").play("普通攻击1_法杖")
	w.attack_fx.play(holder, mage, "普通攻击1_法杖", target, func(): hit_at[0] = Time.get_ticks_msec())
	var flew = await _until_ok(func(): return not w.attack_fx._flying.is_empty(), 3.0)
	var fly_ms = Time.get_ticks_msec() - t0
	await _until(func(): return hit_at[0] > 0, 3.0)
	_check("Magier: Angriffspunkt %s, Energieball fliegt ab %d ms, Einschlag nach %d ms (Wirkung erst dann)" % [str(pts), fly_ms,
		hit_at[0] - t0], pts.size() == 1 and str(pts[0][1]).ends_with("法系普攻3.att") and flew and fly_ms >= 600
		and hit_at[0] - t0 > fly_ms and w.attack_fx.importer.written.is_empty())
	holder.queue_free()

# Fertigkeit einsetzen (Fertigkeiten-Fahrplan F2): Taste 2 (Hieb, Leiste unten Platz 2) ohne Ziel -> Meldung;
# auf ein Wildschwein: hinlaufen, zaubern (Aktion 战士_斩击, Zauberbalken mit dem Namen), Treffer mit Zahl,
# Mana weniger, Abklingzeit-Uhr auf dem Platz; gleich noch einmal -> "noch nicht bereit"
func _skill_cast(w) -> void:
	var h = w.hud
	var me = w.my_id
	var skill_name = Hud_plain(w.skill_data.skill_name(122))
	w.select_target(0)
	await _until(func(): return w.target_id == 0, 3.0)
	var lines = h.chat_lines.size()
	_key(KEY_2, true)
	_key(KEY_2, false)
	await _until(func(): return h.chat_lines.size() > lines, 3.0)
	_check("Taste 2 ohne Ziel: %s" % (h.chat_lines[-1] if h.chat_lines.size() > lines else "-"), h.chat_lines.size() > lines
		and h.chat_lines[-1].contains(Proto.text(Proto.Code.NO_TARGET, ls.language)))
	if h.chat_lines.size() > lines:
		h.chat_lines.pop_back() # erwartete Meldung (die Quests prüfen später: keine Fehlermeldung im Chat)
	var boar = _nearest(w, BOAR)
	if boar == null:
		_check("Wildschwein für Hieb", false)
		return
	var bid: int = boar.id
	w.select_target(bid)
	await _until(func(): return w.target_id == bid, 3.0)
	var mp0 = int(h.stats.get("mp", 0))
	_sk_mp = [mp0, -1]
	ls.session.net.pushed.connect(_skill_push)
	var hit = {}
	ls.session.net.pushed.connect(func(what, d): if what == "hit" and int(d["src"]) == me and int(d.get("skill", 0)) == 122 and hit.is_empty(): hit.merge(d))
	_key(KEY_2, true)
	_key(KEY_2, false)
	await _until(func(): return w.casting.has("end"), 60.0) # das nächste Wildschwein steht gut 80 m weit
	await _frames(3)
	var act = str(w.player.anim.current_animation)
	var bar_text = str(h.dlg(h.PROGRESS).get_text("Txt_info")) if h.progress_shown() else ""
	_check("Taste 2: hinlaufen und Hieb zaubern (Aktion %s, Zauberbalken '%s'%s)" % [act, bar_text,
		"" if w.casting.has("end") else ", Chat: " + (h.chat_lines[-1] if not h.chat_lines.is_empty() else "-")],
		w.casting.has("end") and act == "战士_斩击" and bar_text.contains(skill_name))
	await _shot("18_skill")
	await _until(func(): return not hit.is_empty() and w.casting.is_empty(), 5.0)
	await _until(func(): return _sk_mp[1] >= 0, 2.0)
	ls.session.net.pushed.disconnect(_skill_push)
	var slot = h.skill_control("bar0", 1)
	var cool = slot.get_node_or_null("Cool") if slot != null else null
	await _frames(2)
	_check("Hieb trifft (%s Schaden%s), Mana %d -> %d, Balken weg, Abklingzeit-Uhr auf Platz 2 (%.2f)" % [str(hit.get("dmg")),
		", verfehlt" if hit.get("miss", false) else "", _sk_mp[0], _sk_mp[1], cool._left if cool != null else -1.0],
		not hit.is_empty() and _sk_mp[1] == _sk_mp[0] - 18 and not h.progress_shown() and cool != null and cool._left > 0.0
		and h.cool_fraction(122) > 0.0)
	await _shot("19_cooldown")
	lines = h.chat_lines.size()
	_key(KEY_2, true)
	_key(KEY_2, false)
	await _until(func(): return h.chat_lines.size() > lines, 3.0)
	_check("gleich noch einmal: %s" % (h.chat_lines[-1] if h.chat_lines.size() > lines else "-"), h.chat_lines.size() > lines
		and h.chat_lines[-1].contains(Proto.text(Proto.Code.SKILL_COOLDOWN, ls.language)))
	if h.chat_lines.size() > lines:
		h.chat_lines.pop_back()
	await _until(func(): return h.cool_fraction(122) == 0.0, 5.0)
	await _frames(2)
	_check("nach 3 s ist Hieb wieder bereit (Uhr weg)", h.cool_fraction(122) == 0.0 and cool != null and cool._left <= 0.0)
	w.stop_attack()
	w.select_target(0)
	# Statuseffekte (F3) im Client: Meldungen buffs, hit mit buff (nur Zahl, sofort), heal (grüne Zahl)
	var mob = _nearest(w, BOAR)
	if mob != null:
		var mid: int = mob.id
		var labels = func(): return w.get_children().filter(func(c): return c is Label3D).size()
		var l0 = labels.call()
		w._on_pushed("buffs", {"id": mid, "list": [[583, 1, 5000, 5000]]})
		w._on_pushed("hit", {"src": me, "dst": mid, "dmg": 30, "miss": false, "crit": false, "buff": 583, "hp": 100, "max_hp": 426})
		w._on_pushed("heal", {"src": me, "dst": me, "amount": 50, "buff": 120, "hp": int(h.stats.get("hp", 1)), "max_hp": int(h.stats.get("max_hp", 1))})
		var l1 = labels.call()
		var b: Array = w.buffs.get(mid, [])
		var left = int(b[0][2]) - Time.get_ticks_msec() if not b.is_empty() else -1
		_check("Client merkt sich Brennen am Monster (Rest %d ms), Brand-Schaden und Heilung als Zahlen sofort (%d neu)" % [left, l1 - l0],
			not b.is_empty() and int(b[0][0]) == 583 and left > 4500 and left <= 5000 and l1 - l0 == 2)
		w._on_pushed("buffs", {"id": mid, "list": []})
		_check("leere Liste: Effekte weg", not w.buffs.has(mid))
		await _buff_display(w, mob)

# Anzeige der Statuseffekte (F4) mit Meldungen wie vom Server: Mentaler Fokus (64, Stärkung, 2 min) und 3 x
# Verteidigung reduziert (646, Schwächung, 15 s) an der eigenen Figur, Brennen (583, Sichtbar-Index 8) am gewählten
# Wildschwein
func _buff_display(w, mob) -> void:
	var h = w.hud
	var me = w.my_id
	var d = h.dlg(h.BUFF)
	var bd = w.buff_data
	if d == null or bd == null or not is_instance_valid(mob):
		_check("Win_Buff und Effekt-Daten da", false)
		return
	var mid: int = mob.id
	w.select_target(mid)
	await _until(func(): return w.target_id == mid and h.target_shown(), 3.0)
	w._on_pushed("buffs", {"id": me, "list": [[64, 1, 120000, 120000, -1], [646, 3, 15000, 15000, -1]]})
	w._on_pushed("buffs", {"id": mid, "list": [[583, 1, 5000, 5000, 8]]})
	await _frames(3)
	var b1: TextureRect = d.item("Img_Buff1")
	var b10: TextureRect = d.item("Img_Buff10")
	var stack = (b10.get_node("Stack") as Label).text
	_check("Win_Buff: Mentaler Fokus auf Platz 1 (%s), 3 x Verteidigung reduziert in der Schwächungs-Reihe auf Platz 10 (%s, Stapel %s), lang: %s" % [
		d.get_text("Txt_Time1"), d.get_text("Txt_Time10"), stack, d.get_text("Txt_Buff_Long")], b1.visible and b1.texture != null
		and b1.texture == bd.icon(64) and d.get_text("Txt_Time1") == "2 m" and b10.visible and b10.texture == bd.icon(646)
		and d.get_text("Txt_Time10") == "15 s" and stack == "3" and d.get_text("Txt_Buff_Long") == "0"
		and d.is_shown("Img_Debuff_Back_Sign_2") and not d.item("Img_Buff2").visible and d.is_shown("Img_Buff0"))
	var red = (d.item("Txt_Time10") as Label).get_theme_color("font_color")
	var normal = (d.item("Txt_Time1") as Label).get_theme_color("font_color")
	_check("Restzeit unter 30 s rot (%s), sonst in der Farbe des Dialogs (%s)" % [red, normal], red == Color(1, 0, 0) and normal != red)
	var td = h.dlg(h.TARGETS["monster"])
	var deb: TextureRect = td.item("debuff_1") if td != null else null
	var st: TextureRect = td.item("st_1") if td != null else null
	_check("Ziel-Fenster: Brennen in debuff_1 (%s), st_1 leer" % (str(deb.size) if deb != null else "-"), deb != null and st != null
		and deb.texture != null and deb.texture == bd.icon(583) and deb.size == Vector2(22, 22) and st.texture == null)
	b10.mouse_entered.emit()
	var tip = h.tooltip_text()
	b10.mouse_exited.emit()
	deb.mouse_entered.emit()
	var tip2 = h.tooltip_text()
	deb.mouse_exited.emit()
	var left = h.texts()["buff_left"].replace("%s", "")
	_check("Tooltips mit Text und Restzeit: '%s' / '%s'" % [tip.replace("\n", " | "), tip2.replace("\n", " | ")], tip.contains(bd.title(646))
		and tip.contains(left) and tip2.contains(bd.title(583)) and tip2.contains(left) and bd.title(583) != "")
	var nodes: Dictionary = w._buff_gfx.get(mid, {}).get("nodes", {})
	var fire = nodes.get(8)
	_check("Flammen-GFX (Sichtbar-Index 8, %s) am Wildschwein (%s)" % [str(bd.gfx(0, 0, 8)), fire.get_class() if fire != null else "-"],
		fire != null and is_instance_valid(fire) and mob.is_ancestor_of(fire) and fire.get_child_count() > 0)
	await _shot("21_buffs")
	w._on_pushed("buffs", {"id": me, "list": []})
	w._on_pushed("buffs", {"id": mid, "list": []})
	await _frames(2)
	_check("leere Listen: Win_Buff und Ziel-Fenster ohne Effekte, GFX weg", not b1.visible and not b10.visible and deb.texture == null
		and not w._buff_gfx.has(mid) and not is_instance_valid(fire))
	w.select_target(0)

# Mana vor der Wirkung (letztes stats davor, auch Regeneration) und direkt danach (stats nach cooldown)
func _skill_push(what: String, d: Dictionary) -> void:
	if what == "cooldown" and int(d.get("id", 0)) == 122:
		_sk_cool = true
	elif what == "stats" and d.has("mp"):
		if not _sk_cool:
			_sk_mp[0] = int(d["mp"])
		elif _sk_mp[1] < 0:
			_sk_mp[1] = int(d["mp"])

# Magier-Fertigkeit Feuerball an einer gebauten Figur: angelica_player.gd add_actions baut die Aktion 法师_火球术
# nach, ihre Ereignisse (Feuer in der Hand am Haken HH_shouR, Klänge) und der Angriffspunkt (675 ms) kommen
# mit; play_events hängt das Hand-GFX an den Haken, play mit elapsed 750 ms schießt den Feuerball sofort ab
func _mage_fireball(w) -> void:
	var eq = w.equip_models({0: STAFF}, 1, 5, 0)
	var err = w.factory.build(1, 0, 5, LOOK, w._actions({0: STAFF}), eq)
	var mage: Node3D = w.factory.detach() if err == "" else null
	var target = _nearest(w, BOAR)
	if target == null:
		target = _nearest(w, 14578)
	if mage == null or target == null:
		_check("Magier gebaut, Ziel da (%s)" % err, false)
		return
	var act = "法师_火球术"
	var anim: AnimationPlayer = mage.get_node("AnimationPlayer")
	var before = anim.has_animation(act)
	var n = w.factory.add_actions(mage, [act])
	var pts = w.attack_fx.points_of(mage, act)
	var evs: Array = mage.get_meta("action_events", {}).get(act, [])
	var hand = evs.filter(func(e): return int(e["type"]) == 100 and str(e["hook"]) == "HH_shouR")
	_check("Feuerball nachgebaut (vorher %s, %d neu): Angriffspunkt %s, %d Ereignisse, Hand-GFX %s" % [str(before), n, str(pts), evs.size(),
		str(hand.map(func(e): return str(e["files"][0]).get_file()))], not before and n == 1 and anim.has_animation(act)
		and pts.size() == 1 and int(pts[0][0]) == 675 and str(pts[0][1]).ends_with("火球术.att") and hand.size() == 1
		and evs.any(func(e): return int(e["type"]) == 101))
	var holder = Node3D.new()
	w.add_child(holder)
	holder.add_child(mage)
	var to = target.global_position
	var away = Vector3(to.x - w.player.global_position.x, 0, to.z - w.player.global_position.z).normalized()
	holder.global_position = to - (away if away.length() > 0.1 else Vector3.FORWARD) * 12.0
	anim.play(act)
	w.attack_fx.play_events(holder, mage, act, anim.get_animation(act).length)
	await _frames(3)
	var sk: Skeleton3D = mage.get_node("Skeleton3D")
	var bound = sk.get_children().filter(func(c): return c is BoneAttachment3D and c.bone_name.to_lower() == "hh_shour" and c.get_child_count() > 0)
	var hit_at = [0]
	var t0 = Time.get_ticks_msec()
	w.attack_fx.play(holder, mage, act, target, func(): hit_at[0] = Time.get_ticks_msec(), 750)
	var flew = await _until_ok(func(): return not w.attack_fx._flying.is_empty(), 1.0)
	var fly_ms = Time.get_ticks_msec() - t0
	await _until(func(): return hit_at[0] > 0, 3.0)
	_check("Feuer in der Hand (%d am Haken), Feuerball fliegt nach %d ms ab (Treffer 750 ms nach Beginn), Einschlag nach %d ms" % [bound.size(),
		fly_ms, hit_at[0] - t0], bound.size() == 1 and flew and fly_ms < 300 and hit_at[0] > t0)
	await _shot("20_fireball")
	holder.queue_free()

# Assassine (Mensch, Klasse 3) mit der Novizen-Assassinenklinge: zwei Dolche (models[] file_model_male_l),
# in Ruhe am Gürtel, im Kampf in beiden Händen; der linke wirbelt im ersten Normalangriff (Knochen 左武器)
func _dual_daggers(w) -> void:
	var eq = w.equip_models({0: DAGGER}, 1, 3, 0)
	var err = w.factory.build(1, 0, 3, LOOK, w._actions({0: DAGGER}), eq)
	var fig: Node3D = w.factory.detach() if err == "" else null
	if fig == null:
		_check("Assassine gebaut (%s)" % err, false)
		return
	var r = fig.get_node_or_null("Skeleton3D/Waffe")
	var l = fig.get_node_or_null("Skeleton3D/Waffe links")
	_check("Assassine: zwei Dolche am Gürtel (%s / %s)" % [r.bone_name if r != null else "-", l.bone_name if l != null else "-"], r != null and l != null
		and r.bone_name == "HH_腰_右匕首" and l.bone_name == "HH_腰_左匕首")
	w._player_script.place_weapons(fig, true)
	var sk: Skeleton3D = fig.get_node("Skeleton3D")
	var anim: AnimationPlayer = fig.get_node("AnimationPlayer")
	var hand = w._player_script._bone(sk, "Bip01 L Hand")
	var hook = w._player_script._bone(sk, "HH_lefthandweapon")
	var a: Animation = anim.get_animation("普通攻击1_匕首") if anim.has_animation("普通攻击1_匕首") else null
	var spin = 0.0
	if a != null and hand >= 0 and hook >= 0:
		w.add_child(fig)
		anim.play("普通攻击1_匕首")
		var prev = null
		var t = 0.0
		while t <= a.length:
			anim.seek(t, true)
			sk.force_update_all_bone_transforms()
			var rel: Basis = (sk.get_bone_global_pose(hand).basis.inverse() * sk.get_bone_global_pose(hook).basis).orthonormalized()
			if prev != null:
				spin += rad_to_deg((prev.inverse() * rel).get_rotation_quaternion().get_angle())
			prev = rel
			t += 1.0 / 30.0
	_check("im Kampf beide in der Hand, der linke wirbelt im Angriff 1 (%.0f Grad)" % spin, r != null and l != null
		and r.bone_name == "HH_righthandweapon" and l.bone_name == "HH_lefthandweapon" and spin > 360.0)
	fig.queue_free()

func _key(code: Key, pressed: bool) -> void:
	var ev = InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _physics(n: int) -> void:
	for i in n:
		await physics_frame

func _until(cond: Callable, seconds: float = 10.0) -> void:
	var end = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < end:
		await process_frame
	await _frames(2)

func _until_ok(cond: Callable, seconds: float) -> bool:
	await _until(cond, seconds)
	return cond.call()

func _shot(shot_name: String) -> void:
	await _frames(3)
	if shots == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(shots)
	root.get_texture().get_image().save_png(shots.path_join(shot_name + ".png"))

func _check_ok(what: String, ok: bool) -> void:
	_check(what, ok)

func _check(what: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("WELT-TEST: ", "ok      " if ok else "FEHLER  ", what)

func _end(code: int) -> void:
	if ls != null and ls.session != null:
		ls.session.close()
	if ls != null and ls.world != null:
		ls.world.stop_sounds()
		await _frames(3)
	if code == 2:
		print("WELT-TEST FEHLER: Zeitlimit (%d Prüfungen bis dahin)" % checks)
	elif failures == 0:
		print("WELT-TEST OK (%d Prüfungen)" % checks)
	else:
		print("WELT-TEST FEHLER: %d von %d Prüfungen" % [failures, checks])
	quit(code)
