extends RefCounted

# ====================================================
# Spielwelt des Servers: Figuren in ihren Maps, Bewegung prüfen, Sichtbereich, Position speichern.
# Eine Figur kommt mit world_ready in die Welt (nach char_enter) und geht mit world_leave, Abmelden
# oder Trennung; dabei und alle SAVE_SECONDS werden Position, Leben und Mana gespeichert (Stufe, EXP,
# Quests und Inventar sofort bei jeder Änderung).
# Bewegung (MOVE vom Client): angenommen, wenn der Weg seit der letzten angenommenen Position zur
# Zeit passt (waagrecht höchstens (RUN_SPEED + Tempo der Statuseffekte) * SPEED_TOLERANCE + SLACK, senkrecht MAX_FALL_SPEED)
# und die Position in der Map liegt (|x|, |z| <= MAP_LIMIT); sonst Meldung pos_correct mit der
# letzten guten Position. Bodenhöhe prüft der Server noch nicht (dazu fehlen ihm Terrain-Daten).
# Sichtbereich wie das Gitter des Spiels grob: andere Figuren derselben Map im Umkreis
# Proto.VIEW_RANGE; kommen sie hinein / gehen sie hinaus -> player_enter / player_leave
# (zuverlässig), sonst bis 10 / s STATE mit ihren Positionen (unzuverlässig, geordnet): nur Figuren,
# die sich seit dem letzten Senden an diesen Spieler bewegt / gedreht / den Zustand gewechselt haben,
# unveränderte spätestens nach STATE_REFRESH ms (falls ein Paket verloren ging); Zahlen auf 32 Bit
# gerundet (var_to_bytes braucht dann 4 statt 8 Byte).
# NPCs und Monster je Map: npcs.gd (npc_maps, vom Server beim Start geladen). Sie laufen nur auf
# Maps mit Spielern; jeder Spieler bekommt npc_enter / npc_leave für seinen Umkreis (in Paketen
# zu NPC_BATCH) und npc_move, wenn eine sichtbare Figur losläuft. Den Umkreis rechnet der Server je
# Spieler nur jeden VIEW_TICKS. Takt ganz neu (versetzt) oder sobald er VIEW_MOVE m gelaufen ist;
# Tode und Gänge sichtbarer NPCs gehen jeden Takt hinaus.
# Ziel (target): nur Figuren, die der Spieler gerade sieht (NPCs / Monster mit can_selected,
# Spieler im Umkreis, die eigene Figur); Antwort mit Name / Stufe / Leben / Mana.
# "Sagen" (say): an alle Figuren derselben Map im Umkreis Proto.SAY_RANGE, auch an den Sender;
# Steuerzeichen entfernt, Wörter der Wortliste (badwords, setzt der Server) durch * ersetzt,
# höchstens Proto.CHAT_BURST Nachrichten in Proto.CHAT_WINDOW s.
# Quests: quests.gd (setzt der Server); Zustand je Figur beim Betreten geladen, Warten / Zeitlimits
# jeden Takt; npc_info() liefert Vorlage und Ort eines NPCs für Annehmen / Abschließen.
# Inventar, Ausrüstung, Sammeln: inventory.gd (setzt der Server); beim Betreten geladen (Werte mit
# Ausrüstung), Sammeln jeden Takt geprüft und abgebrochen, wenn die Figur sich bewegt; player_enter
# enthält die Ausrüstung (equip [[Platz, ID]]), Änderungen gehen als player_equip an alle, die die
# Figur sehen.
# Kampf: combat.gd (setzt der Server) jeden Takt nach den NPCs; eine tote Figur (dead) kann sich nicht
# bewegen (pos_correct), player_enter enthält dead.
# Statuseffekte: buffs.gd; kommt eine Figur / ein Monster mit Effekten in Sicht, folgt auf player_enter /
# npc_enter eine Meldung buffs (GFX am Modell).
# ====================================================

const Proto = preload("../common/protocol.gd")
const SPEED_TOLERANCE = 1.6
const SLACK = 1.5
const MAX_FALL_SPEED = 40.0
const MIN_DT = 0.05 # Sekunden: kürzere Abstände zählen wie dieser
const MAP_LIMIT = 4096.0
const SAVE_SECONDS = 60.0
const NPC_BATCH = 48 # Einträge je npc_enter
const STATE_REFRESH = 1000 # ms
const VIEW_TICKS = 5
const VIEW_MOVE = 3.0 # m

var db
var net
var log_line: Callable
var players = {} # Peer -> {id, name, race, gender, class, level, hp, max_hp, mp, max_mp, appearance, map, world,
#                  pos, dir, state, t, seen, state_sent, npc_seen, view_pos, view_slot, saved, target, chat}
var npc_maps = {} # Map -> npcs.gd
var npc_ids = {"next": Proto.NPC_ID_BASE} # gemeinsamer Zähler aller Maps
var badwords: Array = [] # klein, Leerzeichen am Rand = nur an Wortgrenzen (characters.gd)
var quests = null # quests.gd
var inventory = null # inventory.gd
var combat = null # combat.gd
var skills = null # skills.gd
var casting = null # skill_cast.gd
var buffs = null # buffs.gd
var templates = {} # Startvorlagen (characters.gd): Startfertigkeiten
var _last_tick = 0
var _tick_n = 0


func _init(p_db, p_net, p_log: Callable) -> void:
	db = p_db
	net = p_net
	log_line = p_log

func has(peer: int) -> bool:
	return players.has(peer)

# Figur (Zeile aus characters.enter) in die Welt
func enter(peer: int, info: Dictionary) -> void:
	leave(peer)
	var c: Dictionary = info["char"]
	var pos: Array = info["pos"]
	players[peer] = {"id": c["id"], "name": c["name"], "race": c["race"], "gender": c["gender"], "class": c["class"],
		"level": int(c.get("level", 1)), "hp": int(info.get("hp", 1)), "max_hp": int(info.get("max_hp", info.get("hp", 1))),
		"mp": int(info.get("mp", 0)), "max_mp": int(info.get("max_mp", info.get("mp", 0))),
		"exp": int(info.get("exp", 0)), "money": int(info.get("money", 0)),
		"appearance": c["appearance"], "map": info["map"], "world": info["world"],
		"pos": Vector3(pos[0], pos[1], pos[2]), "dir": float(info["dir"]), "state": Proto.MOVE_STAND,
		"t": Time.get_ticks_msec(), "seen": {}, "state_sent": {}, "npc_seen": {}, "view_pos": Vector3(INF, 0, 0),
		"view_slot": randi() % VIEW_TICKS, "saved": Time.get_ticks_msec(), "target": 0, "chat": [],
		"quests": {"active": {}, "done": {}}, "dead": int(info.get("hp", 1)) <= 0}
	if quests != null:
		quests.load_player(players[peer])
	if inventory != null:
		inventory.load_player(players[peer])
		inventory.apply_stats(players[peer])
	if skills != null:
		skills.load_player(players[peer], templates.get("%d_%d_%d" % [c["race"], c["class"], c["gender"]], {}))
	log_line.call("Мир: %s вошёл на карту %s в точке %s; игроков в мире: %d" % [c["name"], info["map"], _fmt(players[peer]["pos"]), players.size()])

func leave(peer: int) -> void:
	var p = players.get(peer)
	if p == null:
		return
	if inventory != null:
		inventory.cancel_gather(peer, p, npc_maps.get(p["map"]), false)
	if buffs != null:
		buffs.forget(p)
	save(peer)
	players.erase(peer)
	for other in players:
		if players[other]["seen"].has(p["id"]):
			players[other]["seen"].erase(p["id"])
			net.push(other, "player_leave", {"id": p["id"]})
	log_line.call("Мир: %s покинул карту %s в точке %s; игроков в мире: %d" % [p["name"], p["map"], _fmt(p["pos"]), players.size()])

func move(peer: int, pos: Vector3, dir: float, state: int) -> void:
	var p = players.get(peer)
	if p == null:
		return
	var now = Time.get_ticks_msec()
	if p.get("dead", false):
		if pos.distance_to(p["pos"]) > 0.05:
			net.push(peer, "pos_correct", {"pos": [p["pos"].x, p["pos"].y, p["pos"].z], "dir": p["dir"]})
		p["t"] = now
		return
	var dt = maxf(MIN_DT, (now - p["t"]) / 1000.0)
	var d: Vector3 = pos - p["pos"]
	var flat = Vector2(d.x, d.z).length()
	var ok = flat <= (Proto.RUN_SPEED + maxf(0.0, float(p.get("speed_add", 0.0)))) * SPEED_TOLERANCE * dt + SLACK and absf(d.y) <= MAX_FALL_SPEED * dt + SLACK \
		and absf(pos.x) <= MAP_LIMIT and absf(pos.z) <= MAP_LIMIT and state >= Proto.MOVE_STAND and state <= Proto.MOVE_JUMP
	if not ok:
		net.push(peer, "pos_correct", {"pos": [p["pos"].x, p["pos"].y, p["pos"].z], "dir": p["dir"]})
		p["t"] = now
		return
	p["pos"] = pos
	p["dir"] = wrapf(dir, -PI, PI)
	p["state"] = state
	p["t"] = now
	var g: Dictionary = p.get("gather", {})
	if not g.is_empty() and pos.distance_to(g["pos"]) > inventory.GATHER_MOVE:
		inventory.cancel_gather(peer, p, npc_maps.get(p["map"]), true)
	if casting != null and p.has("cast"):
		casting.moved(peer, p)

# 10 / s: NPCs bewegen, Sichtbereich nachführen und Positionen der Sichtbaren schicken; Speichern fällig?
func tick() -> void:
	var now = Time.get_ticks_msec()
	var dt = clampf((now - _last_tick) / 1000.0, 0.0, 1.0) if _last_tick > 0 else 1.0 / Proto.MOVE_RATE
	_last_tick = now
	_tick_n += 1
	var near = {} # Map -> Positionen der Spieler
	for peer in players:
		var p = players[peer]
		if not near.has(p["map"]):
			near[p["map"]] = []
		near[p["map"]].append(p["pos"])
	for map_name in npc_maps:
		npc_maps[map_name].tick(now / 1000.0, dt, near.get(map_name, []))
	if casting != null:
		casting.tick()
	if buffs != null:
		buffs.tick()
	if combat != null:
		combat.tick(now / 1000.0, dt)
	for peer in players:
		_npc_view(peer, players[peer])
	for map_name in npc_maps:
		npc_maps[map_name].moves.clear()
		npc_maps[map_name].died.clear()
	for peer in players:
		var p = players[peer]
		var visible = {}
		var entries = []
		var sent: Dictionary = p["state_sent"]
		for other_peer in players:
			if other_peer == peer:
				continue
			var o = players[other_peer]
			if o["map"] != p["map"] or o["pos"].distance_to(p["pos"]) > Proto.VIEW_RANGE:
				continue
			visible[o["id"]] = true
			if not p["seen"].has(o["id"]):
				net.push(peer, "player_enter", {"id": o["id"], "name": o["name"], "race": o["race"], "gender": o["gender"],
					"class": o["class"], "level": o["level"], "appearance": o["appearance"],
					"pos": [o["pos"].x, o["pos"].y, o["pos"].z], "dir": o["dir"],
					"equip": inventory.equip_list(o.get("equip", {})) if inventory != null else [], "dead": o.get("dead", false)})
				_push_buffs(peer, o)
			var last = sent.get(o["id"])
			if last == null or last[0] != o["pos"] or last[1] != o["dir"] or last[2] != o["state"] or now - last[3] >= STATE_REFRESH:
				var f = PackedFloat32Array([o["pos"].x, o["pos"].y, o["pos"].z, o["dir"]])
				entries.append([o["id"], f[0], f[1], f[2], f[3], o["state"]])
				sent[o["id"]] = [o["pos"], o["dir"], o["state"], now]
		for id in p["seen"]:
			if not visible.has(id):
				net.push(peer, "player_leave", {"id": id})
				sent.erase(id)
				if p["target"] == id:
					p["target"] = 0
		p["seen"] = visible
		if not entries.is_empty():
			net.send_state(peer, entries)
		if now - p["saved"] > SAVE_SECONDS * 1000.0:
			save(peer)
		if quests != null:
			quests.tick(peer, p)
		if inventory != null:
			inventory.tick(peer, p, npc_maps.get(p["map"]))

# Anzahl der NPCs / Monster im Umkreis einer Figur (world_ready: der Client wartet auf sie)
func npcs_in_view(peer: int) -> int:
	var p = players.get(peer)
	var nm = npc_maps.get(p["map"]) if p != null else null
	return nm.visible(p["pos"], Proto.VIEW_RANGE).size() if nm != null else 0

# NPCs im Umkreis: neue -> npc_enter, verschwundene -> npc_leave, losgelaufene -> npc_move
func _npc_view(peer: int, p: Dictionary) -> void:
	var nm = npc_maps.get(p["map"])
	if nm == null:
		return
	var seen: Dictionary = p["npc_seen"]
	if (_tick_n + p["view_slot"]) % VIEW_TICKS != 0 and p["pos"].distance_to(p["view_pos"]) <= VIEW_MOVE:
		_npc_changes(peer, nm, seen)
		return
	p["view_pos"] = p["pos"]
	var now_seen = {}
	var enter = []
	for id in nm.visible(p["pos"], Proto.VIEW_RANGE):
		now_seen[id] = true
		if not seen.has(id):
			enter.append(nm.entry(id))
	var gone = []
	var dead = []
	for id in seen:
		if not now_seen.has(id):
			(dead if id in nm.died else gone).append(id)
	for id in nm.moves:
		if seen.has(id) and now_seen.has(id):
			var o = nm.objects[id]
			net.push(peer, "npc_move", {"id": id, "pos": [o["pos"].x, o["pos"].y, o["pos"].z], "to": nm.move_of(o).slice(0, 3),
				"speed": o["speed"]})
	if not gone.is_empty():
		net.push(peer, "npc_leave", {"ids": gone, "die": false})
	if not dead.is_empty():
		net.push(peer, "npc_leave", {"ids": dead, "die": true})
	for i in range(0, enter.size(), NPC_BATCH):
		net.push(peer, "npc_enter", {"list": enter.slice(i, i + NPC_BATCH)})
	for e in enter:
		_push_buffs(peer, nm.objects[e[0]])
	p["npc_seen"] = now_seen

# Figur / Monster mit Statuseffekten kommt in Sicht: buffs wie bei einer Änderung (GFX am Modell, Ziel-Fenster)
func _push_buffs(peer: int, o: Dictionary) -> void:
	if buffs != null and not o.get("buffs", []).is_empty():
		net.push(peer, "buffs", {"id": o["id"], "list": buffs.list_of(o)})

# Zwischen zwei ganzen Sicht-Rechnungen: nur Tode und Gänge der gesehenen NPCs
func _npc_changes(peer: int, nm, seen: Dictionary) -> void:
	var dead = []
	for id in nm.died:
		if seen.has(id):
			seen.erase(id)
			dead.append(id)
	for id in nm.moves:
		if seen.has(id) and nm.objects.has(id):
			var o = nm.objects[id]
			net.push(peer, "npc_move", {"id": id, "pos": [o["pos"].x, o["pos"].y, o["pos"].z], "to": nm.move_of(o).slice(0, 3),
				"speed": o["speed"]})
	if not dead.is_empty():
		net.push(peer, "npc_leave", {"ids": dead, "die": true})

# ====================================================
# ZIEL UND CHAT -> [Code, Daten]
# ====================================================
func select_target(peer: int, id: int) -> Array:
	var p = players.get(peer)
	if p == null:
		return [Proto.Code.NOT_IN_WORLD, {}]
	if id == 0:
		p["target"] = 0
		return [Proto.Code.OK, {"id": 0}]
	var t = target_info(p, id)
	if t.is_empty():
		return [Proto.Code.TARGET_INVALID, {}]
	p["target"] = id
	return [Proto.Code.OK, t]

# Was der Spieler p über die Figur id erfahren darf ({} = nicht sichtbar / nicht wählbar)
func target_info(p: Dictionary, id: int) -> Dictionary:
	if id >= Proto.NPC_ID_BASE:
		var nm = npc_maps.get(p["map"])
		if nm == null or not p["npc_seen"].has(id) or not nm.objects.has(id) or not nm.objects[id]["select"]:
			return {}
		var i: Dictionary = nm.info(id)
		i["kind"] = "mine" if i["mine"] else ("npc" if i["npc"] else "monster")
		i.erase("npc")
		i.erase("mine")
		i["buffs"] = buffs.list_of(nm.objects[id]) if buffs != null else []
		return i
	var o = p if id == p["id"] else null
	if o == null and p["seen"].has(id):
		for other in players:
			if players[other]["id"] == id:
				o = players[other]
				break
	if o == null:
		return {}
	return {"id": id, "kind": "player", "name": o["name"], "race": o["race"], "class": o["class"], "level": o["level"],
		"hp": o["hp"], "max_hp": o["max_hp"], "mp": o["mp"], "max_mp": o["max_mp"], "buffs": buffs.list_of(o) if buffs != null else []}

# Ausrüstung von p geändert: alle, die p sehen, bekommen player_equip
func equip_changed(_peer: int, p: Dictionary) -> void:
	var msg = {"id": p["id"], "equip": inventory.equip_list(p.get("equip", {}))}
	for other in players:
		if players[other]["seen"].has(p["id"]):
			net.push(other, "player_equip", msg)

# NPC / Monster npc_id auf der Map des Spielers: {tid, pos}, {} wenn es ihn nicht gibt
func npc_info(p: Dictionary, npc_id: int) -> Dictionary:
	var nm = npc_maps.get(p["map"])
	var o = nm.objects.get(npc_id) if nm != null else null
	if o == null:
		return {}
	return {"tid": o["tid"], "pos": o["pos"]}

func say(peer: int, channel, text) -> Array:
	var p = players.get(peer)
	if p == null:
		return [Proto.Code.NOT_IN_WORLD, {}]
	if not channel is int or channel != Proto.CHAT_SAY or not text is String:
		return [Proto.Code.CHAT_INVALID, {}]
	var clean = ""
	for ch in text:
		var u = ch.unicode_at(0)
		if u >= 32 and u != 127:
			clean += ch
	clean = clean.strip_edges()
	if clean == "" or clean.length() > Proto.CHAT_MAX:
		return [Proto.Code.CHAT_INVALID, {}]
	var now = Time.get_ticks_msec()
	var recent: Array = p["chat"].filter(func(t): return now - t < Proto.CHAT_WINDOW * 1000.0)
	if recent.size() >= Proto.CHAT_BURST:
		p["chat"] = recent
		return [Proto.Code.CHAT_TOO_FAST, {}]
	recent.append(now)
	p["chat"] = recent
	clean = filter_words(clean)
	var msg = {"channel": channel, "id": p["id"], "name": p["name"], "text": clean}
	var heard = 0
	for other in players:
		var o = players[other]
		if o["map"] == p["map"] and o["pos"].distance_to(p["pos"]) <= Proto.SAY_RANGE:
			net.push(other, "chat", msg)
			heard += 1
	log_line.call("Chat %s (%s, %d hören): %s" % [p["name"], p["map"], heard, clean])
	return [Proto.Code.OK, {}]

# Wörter der Wortliste durch * ersetzen (ohne Groß- / Kleinschreibung)
func filter_words(text: String) -> String:
	var lower = " " + text.to_lower() + " "
	var out = " " + text + " "
	for w in badwords:
		var core: String = w.strip_edges()
		if core == "":
			continue
		var at = lower.find(w)
		while at >= 0:
			var start = at + w.find(core)
			out = out.substr(0, start) + "*".repeat(core.length()) + out.substr(start + core.length())
			lower = lower.substr(0, start) + "*".repeat(core.length()) + lower.substr(start + core.length())
			at = lower.find(w, at + 1)
	return out.substr(1, out.length() - 2)

func save(peer: int) -> void:
	var p = players.get(peer)
	if p == null:
		return
	p["saved"] = Time.get_ticks_msec()
	if not db.run("UPDATE characters SET map = ?, world = ?, pos_x = ?, pos_y = ?, pos_z = ?, dir = ?, hp = ?, mp = ? WHERE id = ?",
			[p["map"], p["world"], p["pos"].x, p["pos"].y, p["pos"].z, p["dir"], p["hp"], p["mp"], p["id"]]):
		log_line.call("ОШИБКА базы данных: " + db.last_error)

func save_all() -> void:
	for peer in players:
		save(peer)

static func _fmt(v: Vector3) -> String:
	return "(%.1f | %.1f | %.1f)" % [v.x, v.y, v.z]
