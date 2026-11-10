extends RefCounted

# ====================================================
# Quests auf dem Server (Fahrplan Schritt 10), vereinfacht nach ATaskTempl (gs/task: CheckDeliverTask,
# DeliverTask, RecursiveAward). Daten: Plugin Server/quest_templates.json (tools/server_data/
# quest_templates.gd aus der tasks.data des Clients, dazu die Quest-Dienste der NPCs).
# Zustand je Figur (players[...]["quests"]): active {ID: {p: Fortschritt, t: angenommen}} für jede
# laufende Quest samt ihren laufenden Unteraufgaben, done {ID: {ok, times, t}} für erledigte Quests
# der obersten Ebene; in der Tabelle quests: state 0 = läuft, 1 = erfüllt, 2 = gescheitert.
# Vergabe (can_deliver, CheckPrerequisite): oberste Ebene, nicht gesperrt (block: Bedingungen, die
# der Server noch nicht prüft), nicht schon laufend, erledigt nur mit redo / redo_fail, Stufe,
# Rasse, Klasse, Geschlecht (1 = männlich, 2 = weiblich), alle Vorquests erfüllt, keine Ausschluss-
# Quest läuft oder ist erledigt. Mit Unteraufgaben: der Reihe nach (order) nur die erste, sonst alle.
#   accept    am NPC, der vergibt (delv bzw. NPC_TASK_OUT_SERVICE), höchstens SERVICE_RANGE m entfernt
#   complete  am NPC, der abnimmt (anpc bzw. NPC_TASK_IN_SERVICE): Methode 3 "NPC ansprechen" ist damit
#             erfüllt; Methode 2 "Gegenstände sammeln", wenn alle gesuchten in der Tasche sind; andere
#             Methoden erst, wenn ihr Ziel erreicht ist (Kampf: später)
#   kill      Monster getötet (combat.gd): Methode 1 "Monster töten" zählt die Kills je Vorlage (Fortschritt
#             k {Vorlage: Anzahl}) bzw. - mit drop - kommt mit prob der Beute-Gegenstand in die Tasche, bis
#             drop_num erreicht ist; Abschluss "sofort" (f 0) dann erfüllt, sonst beim NPC. Mit clear
#             (m_bClearAcquired) wird die Beute beim Abschluss eingezogen (RemoveAcquiredItem).
#   mine      Sammeln an einem Punkt mit task_out (inventory.gd, CheckMining): läuft die Quest mit
#             Methode 2, kommt ihr erster gesuchter Gegenstand (1 Stück) in die Tasche, solange noch
#             welche fehlen; Abschluss "sofort" (f 0) ist dann erfüllt, sobald alle da sind
#             (check_items, auch nach jeder Belohnung). Die gesammelten Gegenstände bleiben (die
#             Quests hier haben kein m_bClearAcquired).
#   abandon   nur Quests der obersten Ebene mit giveup; gilt als gescheitert
#   tick      Methode 5 "Warten": erfüllt nach wait s; Zeitlimit (time): gescheitert
# Abschluss einer Unteraufgabe: psucc -> auch die Eltern-Quest erfüllt; sonst der Reihe nach die
# nächste, ohne nächste bzw. wenn alle erfüllt sind die Eltern-Quest; Misserfolg mit pfail auch.
# Belohnung je erfüllter Quest: EXP (Stufenaufstieg mit vollen HP / MP), Geld, Gegenstände (Gruppe
# random: einer nach prob, sonst alle; vorher Platz im Inventar geprüft, inventory.gd stapelt),
# Folgequest (new).
# Automatische Vergabe beim Betreten der Welt und nach jedem Abschluss / Stufenaufstieg: auto,
# vorläufig nur sichtbare Quests mit Rassen- / Klassen-Bedingung oder Vorquest (Story-Ketten wie
# 5678): die übrigen automatischen Quests und die versteckten Auslöser-Quests (z.B. 15014 "Gnädiger
# Mut", sofort erfüllt mit Folgequest voller Gegenstände) warten auf Bedingungen, die es noch nicht
# gibt (Gebiete, Zähler, Kontomerkmale, Lua) bzw. die erst die Server-Quests (v179) zeigen.
# Meldungen an den Spieler: quests {active: [[ID, Fortschritt]], done: [IDs]}, quest_event {id, kind
# ("new" / "done" / "failed" / "bag_full"), exp, gold, items}, stats {level, exp, exp_next, hp,
# max_hp, mp, max_mp, money, attr}.
# ====================================================

const Proto = preload("../common/protocol.gd")
const Settings = preload("../common/settings.gd")
const PLUGIN_SERVER = "res://addons/PWE-Manager/Server/"
const SERVICE_RANGE = 10.0 # m, MAX_SERVICE_DISTANCE des gs
const ACTIVE = 0
const SUCCESS = 1
const FAILED = 2

var db
var net
var log_line: Callable
var stats # stats.gd
var inventory = null # inventory.gd (setzt der Server)
var tasks = {} # ID -> Quest (quest_templates.json)
var npc_out = {} # NPC-Vorlage -> [Quest-IDs]
var npc_in = {}
var auto_list: Array = [] # automatisch vergebbare Quests der obersten Ebene


func _init(p_db, p_net, p_log: Callable, p_stats) -> void:
	db = p_db
	net = p_net
	log_line = p_log
	stats = p_stats

# quest_templates.json laden -> "" oder Fehlertext
func load_templates() -> String:
	var path = Settings.server_data_path("quest_templates.json")
	var d = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not d is Dictionary or not d.has("tasks"):
		return "Файл отсутствует или недоступен для чтения: " + path
	for k in d["tasks"]:
		tasks[int(k)] = _ints(d["tasks"][k])
	for part in [[npc_out, "npc_out"], [npc_in, "npc_in"]]:
		for k in d.get(part[1], {}):
			part[0][int(k)] = d[part[1]][k].map(func(x): return int(x))
	for id in tasks:
		var t = tasks[id]
		if not t.has("p") and t.get("auto", false) and not t.has("block") and not t.get("hidden", false) \
				and (t.has("race") or t.has("occ") or t.has("pre")):
			auto_list.append(id)
	auto_list.sort()
	return ""

# JSON-Zahlen (float) -> int, Listen von IDs ebenso
static func _ints(t: Dictionary) -> Dictionary:
	for k in t:
		var v = t[k]
		if v is float:
			t[k] = int(v)
		elif v is Array and k in ["s", "pre", "mutex", "race", "occ", "lv"]:
			t[k] = v.map(func(x): return int(x))
	return t

func task(id: int) -> Dictionary:
	return tasks.get(id, {})


# ====================================================
# ZUSTAND JE FIGUR
# ====================================================
func load_player(p: Dictionary) -> void:
	var q = {"active": {}, "done": {}}
	var rows = db.query("SELECT task_id, state, progress, accepted, finished, times FROM quests WHERE character_id = ?", [p["id"]])
	for r in (rows if rows != null else []):
		var id = int(r["task_id"])
		if not tasks.has(id):
			continue
		if int(r["state"]) == ACTIVE:
			var prog = JSON.parse_string(str(r["progress"]))
			q["active"][id] = {"p": prog if prog is Dictionary else {}, "t": int(r["accepted"]) if r["accepted"] != null else 0}
		else:
			q["done"][id] = {"ok": int(r["state"]) == SUCCESS, "times": int(r["times"]), "t": int(r["finished"]) if r["finished"] != null else 0}
	p["quests"] = q

# Zustand für den Client: {active: [[ID, Fortschritt]], done: [IDs]}
func state_of(p: Dictionary) -> Dictionary:
	var q: Dictionary = p["quests"]
	var active = []
	for id in q["active"]:
		active.append([id, q["active"][id]["p"]])
	var done = []
	for id in q["done"]:
		if q["done"][id]["ok"]:
			done.append(id)
	return {"active": active, "done": done}

func _push_state(peer: int, p: Dictionary) -> void:
	net.push(peer, "quests", state_of(p))


# ====================================================
# VERGABE
# ====================================================
# Bedingungen einer Quest der obersten Ebene -> Code (OK = vergebbar)
func can_deliver(p: Dictionary, id: int) -> int:
	var t = task(id)
	if t.is_empty() or t.has("p") or t.has("block"):
		return Proto.Code.QUEST_INVALID
	var q: Dictionary = p["quests"]
	if q["active"].has(id):
		return Proto.Code.QUEST_CONDITIONS
	if q["done"].has(id):
		var ok = q["done"][id]["ok"]
		if (ok and not t.get("redo", false)) or (not ok and not t.get("redo_fail", false)):
			return Proto.Code.QUEST_CONDITIONS
	var lv: Array = t.get("lv", [0, 0])
	if (int(lv[0]) != 0 and p["level"] < int(lv[0])) or (int(lv[1]) != 0 and p["level"] > int(lv[1])):
		return Proto.Code.QUEST_CONDITIONS
	if t.has("race") and not _has(t["race"], p["race"]):
		return Proto.Code.QUEST_CONDITIONS
	if t.has("occ") and not _has(t["occ"], p["class"]):
		return Proto.Code.QUEST_CONDITIONS
	var g = int(t.get("gender", 0))
	if (g == 1 and p["gender"] != 0) or (g == 2 and p["gender"] != 1):
		return Proto.Code.QUEST_CONDITIONS
	for pre in t.get("pre", []):
		var d = q["done"].get(int(pre))
		if d == null or not d["ok"]:
			return Proto.Code.QUEST_CONDITIONS
	for m in t.get("mutex", []):
		if q["active"].has(int(m)) or q["done"].has(int(m)):
			return Proto.Code.QUEST_CONDITIONS
	return Proto.Code.OK

static func _has(list: Array, v: int) -> bool:
	for x in list:
		if int(x) == v:
			return true
	return false

# Quest (oberste Ebene) samt laufender Unteraufgaben eintragen (DeliverTask)
func deliver(peer: int, p: Dictionary, id: int) -> void:
	var now = _now()
	_add_active(p, id, now)
	_push_state(peer, p)
	net.push(peer, "quest_event", {"id": id, "kind": "new"})
	log_line.call("Задание: персонаж %s получил %d «%s»" % [p["name"], id, task(id).get("name", "")])

func _add_active(p: Dictionary, id: int, now: int) -> void:
	var t = task(id)
	var prog = {}
	if int(t.get("m", 0)) == 5:
		prog["until"] = now + int(t.get("wait", 0))
	p["quests"]["active"][id] = {"p": prog, "t": now}
	_save_row(p, id, ACTIVE, prog, now, null, 0)
	var subs: Array = t.get("s", [])
	if subs.is_empty():
		return
	if t.get("order", false) or t.get("one", false) or t.get("rand", false):
		_add_active(p, int(subs[0]), now)
	else:
		for s in subs:
			_add_active(p, int(s), now)

# Automatische Quests vergeben, deren Bedingungen erfüllt sind
func auto_deliver(peer: int, p: Dictionary) -> void:
	for id in auto_list:
		if can_deliver(p, id) == Proto.Code.OK:
			deliver(peer, p, id)


# ====================================================
# ANFRAGEN -> [Code, Daten]
# ====================================================
# NPC_GIVE_TASK: Quest beim NPC annehmen
func accept(peer: int, p: Dictionary, npc: Dictionary, id: int) -> Array:
	var t = task(id)
	if t.is_empty() or t.has("p"):
		return [Proto.Code.QUEST_INVALID, {}]
	if npc.is_empty() or not _near(p, npc) or not (int(t.get("delv", 0)) == npc["tid"] or _has(npc_out.get(npc["tid"], []), id)):
		return [Proto.Code.QUEST_NOT_HERE, {}]
	var code = can_deliver(p, id)
	if code != Proto.Code.OK:
		return [code, {}]
	deliver(peer, p, id)
	return [Proto.Code.OK, {"id": id}]

# NPC_COMPLETE_TASK: laufende Quest beim NPC abschließen
func complete(peer: int, p: Dictionary, npc: Dictionary, id: int) -> Array:
	var t = task(id)
	if t.is_empty():
		return [Proto.Code.QUEST_INVALID, {}]
	if not p["quests"]["active"].has(id) or not t.get("s", []).is_empty():
		return [Proto.Code.QUEST_NOT_ACTIVE, {}]
	if npc.is_empty() or not _near(p, npc) or not (int(t.get("anpc", 0)) == npc["tid"] or _has(npc_in.get(npc["tid"], []), id)):
		return [Proto.Code.QUEST_NOT_HERE, {}]
	if not _goal_reached(p, id):
		return [Proto.Code.QUEST_NOT_DONE, {}]
	if not _bag_room(p, id):
		return [Proto.Code.QUEST_BAG_FULL, {}]
	finish(peer, p, id, true)
	return [Proto.Code.OK, {"id": id}]

func abandon(peer: int, p: Dictionary, id: int) -> Array:
	var t = task(id)
	if not p["quests"]["active"].has(id) or t.has("p"):
		return [Proto.Code.QUEST_NOT_ACTIVE, {}]
	if not t.get("giveup", false):
		return [Proto.Code.QUEST_NO_GIVEUP, {}]
	finish(peer, p, id, false)
	return [Proto.Code.OK, {"id": id}]

# Ziel einer Quest ohne Unteraufgaben erreicht? (3 NPC ansprechen: ja; 5 Warten: Zeit um;
# 2 Gegenstände: alle gesuchten in der Tasche)
func _goal_reached(p: Dictionary, id: int) -> bool:
	var t = task(id)
	match int(t.get("m", 0)):
		1:
			if t.get("mon", []).is_empty():
				return false
			var prog: Dictionary = p["quests"]["active"][id]["p"].get("k", {})
			for m in t["mon"]:
				if int(m.get("drop", 0)) != 0:
					if inventory == null or inventory.count_of(p, int(m["drop"])) < int(m["drop_num"]):
						return false
				elif int(prog.get(str(int(m["id"])), 0)) < int(m["num"]):
					return false
			return true
		2:
			if inventory == null or t.get("items", []).is_empty():
				return false
			for it in t["items"]:
				if inventory.count_of(p, int(it["id"])) < maxi(1, int(it["num"])):
					return false
			return true
		3:
			return true
		5:
			return _now() >= int(p["quests"]["active"][id]["p"].get("until", 0))
	return false # Monster: kommt mit dem Kampf

# Sammeln für die Quest id (CheckMining) -> gegebene Gegenstände [[ID, Anzahl]]
func mine(peer: int, p: Dictionary, id: int) -> Array:
	var t = task(id)
	if not p["quests"]["active"].has(id) or int(t.get("m", 0)) != 2 or t.get("items", []).is_empty() or inventory == null:
		return []
	var want: Dictionary = t["items"][0]
	var item_id = int(want["id"])
	if int(want["num"]) > 0 and inventory.count_of(p, item_id) >= int(want["num"]):
		return []
	if not inventory.can_add(p, [[item_id, 1]]):
		net.push(peer, "quest_event", {"id": id, "kind": "bag_full"})
		return []
	inventory.add(p, item_id, 1)
	return [[item_id, 1]]

# Monster tid getötet: Kills / Beute der laufenden Quests mit Methode 1
func kill(peer: int, p: Dictionary, tid: int) -> void:
	var changed = false
	var bag = false
	for id in p["quests"]["active"].keys():
		var t = task(id)
		if int(t.get("m", 0)) != 1 or not t.get("s", []).is_empty():
			continue
		var e: Dictionary = p["quests"]["active"][id]
		for m in t.get("mon", []):
			if int(m["id"]) != tid:
				continue
			if int(m.get("drop", 0)) != 0:
				var drop = int(m["drop"])
				if inventory != null and inventory.count_of(p, drop) < int(m["drop_num"]) and randf() <= float(m.get("prob", 1.0)):
					if inventory.can_add(p, [[drop, 1]]):
						inventory.add(p, drop, 1)
						bag = true
					else:
						net.push(peer, "quest_event", {"id": id, "kind": "bag_full"})
			else:
				var k: Dictionary = e["p"].get("k", {})
				var key = str(tid)
				if int(k.get(key, 0)) < int(m["num"]):
					k[key] = int(k.get(key, 0)) + 1
					e["p"]["k"] = k
					_save_row(p, id, ACTIVE, e["p"], e["t"], null, 0)
					changed = true
	if bag:
		inventory.push(peer, p)
	if changed or bag:
		_push_state(peer, p)
	for id in p["quests"]["active"].keys():
		if not p["quests"]["active"].has(id):
			continue
		var t = task(id)
		if int(t.get("m", 0)) == 1 and int(t.get("f", 0)) == 0 and t.get("s", []).is_empty() and _goal_reached(p, id) and _bag_room(p, id):
			finish(peer, p, id, true)

# Gegenstands-Ziele mit Abschluss "sofort" prüfen (nach jeder Änderung der Tasche)
func check_items(peer: int, p: Dictionary) -> void:
	for id in p["quests"]["active"].keys():
		if not p["quests"]["active"].has(id):
			continue
		var t = task(id)
		if int(t.get("m", 0)) == 2 and int(t.get("f", 0)) == 0 and t.get("s", []).is_empty() and _goal_reached(p, id) \
				and _bag_room(p, id):
			finish(peer, p, id, true)

func _near(p: Dictionary, npc: Dictionary) -> bool:
	return npc.has("pos") and p["pos"].distance_to(npc["pos"]) <= SERVICE_RANGE


# ====================================================
# ABSCHLUSS UND BELOHNUNG
# ====================================================
# Quest id erfüllt (ok) oder gescheitert; reicht das an die Eltern-Quest weiter
func finish(peer: int, p: Dictionary, id: int, ok: bool) -> void:
	var t = task(id)
	var q: Dictionary = p["quests"]
	var now = _now()
	_clear_subtree(p, id)
	var award = {}
	if ok:
		award = _award(peer, p, t)
		if t.get("clear", false) and int(t.get("m", 0)) == 1 and inventory != null:
			var taken = 0
			for m in t.get("mon", []):
				if int(m.get("drop", 0)) != 0:
					taken += inventory.remove(p, int(m["drop"]), int(m["drop_num"]))
			if taken > 0:
				inventory.push(peer, p)
	if not t.has("p"):
		var times = int(q["done"].get(id, {}).get("times", 0)) + (1 if ok else 0)
		q["done"][id] = {"ok": ok, "times": times, "t": now}
		_save_row(p, id, SUCCESS if ok else FAILED, {}, null, now, times)
		var ev = {"id": id, "kind": "done" if ok else "failed"}
		ev.merge(award)
		net.push(peer, "quest_event", ev)
		log_line.call("Задание: персонаж %s %s %d «%s»%s" % [p["name"], "выполнил" if ok else "не выполнил", id, t.get("name", ""),
			(" (+%d EXP)" % award.get("exp", 0)) if award.get("exp", 0) else ""])
		if ok and int(t.get("award", {}).get("new", 0)) != 0:
			var nid = int(t["award"]["new"])
			if can_deliver(p, nid) == Proto.Code.OK:
				deliver(peer, p, nid)
		_push_state(peer, p)
		auto_deliver(peer, p)
		return
	var parent_id = int(t["p"])
	var parent = task(parent_id)
	if not award.is_empty():
		var ev = {"id": id, "kind": "done"}
		ev.merge(award)
		net.push(peer, "quest_event", ev)
	if not ok:
		if t.get("pfail", false) and q["active"].has(parent_id):
			finish(peer, p, parent_id, false)
		else:
			_push_state(peer, p)
		return
	if t.get("psucc", false):
		finish(peer, p, parent_id, true)
		return
	var subs: Array = parent.get("s", [])
	if parent.get("order", false):
		var at = subs.find(id)
		if at >= 0 and at + 1 < subs.size():
			_add_active(p, int(subs[at + 1]), now)
			_push_state(peer, p)
			log_line.call("Задание: персонаж %s продолжает %d «%s»" % [p["name"], int(subs[at + 1]), task(int(subs[at + 1])).get("name", "")])
			return
		finish(peer, p, parent_id, true)
		return
	for s in subs:
		if q["active"].has(int(s)):
			_push_state(peer, p) # Geschwister laufen noch
			return
	finish(peer, p, parent_id, true)

# Laufende Einträge einer Quest und ihrer Unteraufgaben entfernen
func _clear_subtree(p: Dictionary, id: int) -> void:
	var q: Dictionary = p["quests"]
	if q["active"].has(id):
		q["active"].erase(id)
		db.run("DELETE FROM quests WHERE character_id = ? AND task_id = ? AND state = ?", [p["id"], id, ACTIVE])
	for s in task(id).get("s", []):
		_clear_subtree(p, int(s))

# Belohnung einer erfüllten Quest -> {exp, gold, items: [[ID, Anzahl]]}
func _award(peer: int, p: Dictionary, t: Dictionary) -> Dictionary:
	var a: Dictionary = t.get("award", {})
	if a.is_empty():
		return {}
	var out = {}
	var changed = false
	if int(a.get("gold", 0)) != 0:
		p["money"] = int(p.get("money", 0)) + int(a["gold"])
		out["gold"] = int(a["gold"])
		changed = true
	var items = _award_items(a)
	if not items.is_empty() and inventory != null:
		out["items"] = []
		for it in items:
			var put: Array = inventory.add(p, it[0], it[1])
			if put.is_empty():
				break
			out["items"].append([it[0], it[1], put[0][0]])
		inventory.push(peer, p)
	if int(a.get("exp", 0)) != 0:
		out["exp"] = int(a["exp"])
		add_exp(p, int(a["exp"]))
		changed = true
	if changed:
		save_stats(p)
		net.push(peer, "stats", stats_of(p))
	return out

# Gegenstände einer Belohnung: [[ID, Anzahl]]
func _award_items(a: Dictionary) -> Array:
	var out = []
	for g in a.get("items", []):
		var list: Array = g.get("items", [])
		if g.get("random", false):
			var r = randf()
			for it in list:
				r -= float(it.get("prob", 0.0))
				if r <= 0.0:
					out.append([int(it["id"]), maxi(1, int(it["num"]))])
					break
		else:
			for it in list:
				out.append([int(it["id"]), maxi(1, int(it["num"]))])
	return out

# Reicht der Platz im Inventar für die Gegenstände der Quest (und ihrer Eltern, die mit ihr enden)?
# Bei einer Zufallsgruppe zählt der größte mögliche Gegenstand.
func _bag_room(p: Dictionary, id: int) -> bool:
	var need = []
	var t = task(id)
	while not t.is_empty():
		for g in t.get("award", {}).get("items", []):
			var list: Array = g.get("items", [])
			if g.get("random", false) and not list.is_empty():
				var big = list[0]
				for it in list:
					if int(it["num"]) > int(big["num"]):
						big = it
				need.append([int(big["id"]), maxi(1, int(big["num"]))])
			else:
				for it in list:
					need.append([int(it["id"]), maxi(1, int(it["num"]))])
		if not t.has("p") or not t.get("psucc", false) and not _last_in_order(t):
			break
		t = task(int(t["p"]))
	return need.is_empty() or (inventory != null and inventory.can_add(p, need))

func _last_in_order(t: Dictionary) -> bool:
	var parent = task(int(t.get("p", 0)))
	var subs: Array = parent.get("s", [])
	return parent.get("order", false) and not subs.is_empty() and int(subs[subs.size() - 1]) == int(t["id"])

# EXP dazu; Stufenaufstieg wie PLAYER_LEVELEXP_CONFIG (EXP bis zur nächsten Stufe), volle HP / MP
func add_exp(p: Dictionary, amount: int) -> void:
	p["exp"] = int(p.get("exp", 0)) + amount
	var need = stats.exp_next(p["level"])
	while need > 0 and p["exp"] >= need:
		p["exp"] -= need
		p["level"] += 1
		if inventory != null:
			inventory.apply_stats(p)
		else:
			p["max_hp"] = stats.max_hp(p["class"], p["level"], p["max_hp"])
			p["max_mp"] = stats.max_mp(p["class"], p["level"], p["max_mp"])
		p["hp"] = p["max_hp"]
		p["mp"] = p["max_mp"]
		log_line.call("Уровень: персонаж %s достиг уровня %d" % [p["name"], p["level"]])
		need = stats.exp_next(p["level"])

func stats_of(p: Dictionary) -> Dictionary:
	return {"level": p["level"], "exp": p.get("exp", 0), "exp_next": stats.exp_next(p["level"]), "hp": p["hp"],
		"max_hp": p["max_hp"], "mp": p["mp"], "max_mp": p["max_mp"], "money": p.get("money", 0), "attr": p.get("attr", {}),
		"speed_add": float(p.get("speed_add", 0.0))}

func save_stats(p: Dictionary) -> void:
	if not db.run("UPDATE characters SET level = ?, exp = ?, hp = ?, mp = ?, money = ? WHERE id = ?",
			[p["level"], p.get("exp", 0), p["hp"], p["mp"], p.get("money", 0), p["id"]]):
		log_line.call("ОШИБКА базы данных: " + db.last_error)


# ====================================================
# TAKT
# ====================================================
# Warten (Methode 5) und Zeitlimits der laufenden Quests eines Spielers
func tick(peer: int, p: Dictionary) -> void:
	var now = _now()
	for id in p["quests"]["active"].keys():
		if not p["quests"]["active"].has(id):
			continue # in diesem Takt schon mit einer anderen beendet
		var t = task(id)
		var e: Dictionary = p["quests"]["active"][id]
		if int(t.get("m", 0)) == 5 and t.get("s", []).is_empty() and now >= int(e["p"].get("until", 0)):
			if _bag_room(p, id):
				finish(peer, p, id, true)
		elif int(t.get("time", 0)) > 0 and now - int(e["t"]) > int(t["time"]):
			finish(peer, p, id, false)


# ====================================================
# DATENBANK
# ====================================================
func _save_row(p: Dictionary, id: int, state: int, prog: Dictionary, accepted, finished, times: int) -> void:
	if not db.run("INSERT OR REPLACE INTO quests (character_id, task_id, state, progress, accepted, finished, times) VALUES (?, ?, ?, ?, ?, ?, ?)",
			[p["id"], id, state, JSON.stringify(prog), accepted, finished, times]):
		log_line.call("ОШИБКА базы данных: " + db.last_error)

static func _now() -> int:
	return int(Time.get_unix_time_from_system())
