extends RefCounted

# ====================================================
# Quests im Client (Fahrplan Schritt 10): Texte und Gespräche aus der tasks.data der Sprache
# (angelica_tasks.gd im Index-Modus: nur die gebrauchten Quests liegen im Speicher), Quest-Dienste der
# NPCs aus der elements.data (NPC_TASK_OUT_SERVICE / NPC_TASK_IN_SERVICE), Symbole aus
# script\NPCTaskInfo.lua (angelica_lua.gd) mit dem Bildersatz surfaces\ingame\QuestList.tga (.txt).
# Der Server entscheidet; der Client zeigt an, was nach seinem Zustand (quests-Meldung) möglich ist:
#   npc_entries(NPC)  Einträge des NPC-Fensters wie CDlgNPC::PopupTaskDialog: abschließbar (talk_award),
#                     annehmbar (talk_deliver, sonst grau talk_unqualified), läuft (talk_execute)
#   head_icon(NPC)    Symbol über dem Kopf wie CECNPCServer::UpdateCurQuestIcon (abschließbar vor
#                     annehmbar vor läuft), Art des Bildes nach m_nTopic der Quest
#   trace()           Quest-Verfolgung: sichtbare Quests der obersten Ebene mit dem laufenden Teil
#   format_text()     Platzhalter wie CDlgTask::FormatTaskText (&name&, &level&, &race&, &item:ID& ...);
#                     Koordinaten-Links &pos:(x,y,z,Welt)Name& werden zu POS_OPEN x,y,z,Welt POS_MID Name
#                     POS_CLOSE (hud.gd macht daraus grüne Links mit Autoroute)
#   item_count        Callable(ID) -> Anzahl in der Tasche (Ziele "Gegenstände sammeln": Name 0/1)
#   npc_pos           Orte der Quest-NPCs aus data\task_npc.data (angelica_tasks.gd npc_positions)
# Annehmbar heißt hier wie auf dem Server (quests.gd can_deliver): Stufe, Rasse, Klasse, Geschlecht,
# Vorquests, Ausschluss, nicht laufend, erledigt nur wiederholbar, keine noch nicht geprüfte
# Vorbedingung (angelica_tasks.gd UNSUPPORTED).
# ====================================================

const TASKS = "res://addons/PWE-Manager/Data/angelica_tasks.gd"
const FILES = "res://addons/PWE-Manager/Data/angelica_files.gd"
const LUA = "res://addons/PWE-Manager/Data/angelica_lua.gd"
const ICON_SET = "ingame\\QuestList.tga"
const POS_OPEN = "\uE000"
const POS_MID = "\uE001"
const POS_CLOSE = "\uE002"
# CECNPCTaskInfo: Art des Eintrags
const QBT_CAN_NOT_GET = 1
const QBT_CAN_NOT_FINISH = 2
const QBT_CAN_GET = 3
const QBT_CAN_FINISH = 4
const TOPIC_ELSE = 4
# Gesprächsoptionen mit Sonderbedeutung (SERVICE_TYPE in ExpTypes.h)
const NPC_GIVE_TASK = 0x80000006
const NPC_COMPLETE_TASK = 0x80000007
const TALK_RETURN = 0x80000011
const TALK_EXIT = 0x80000012
const TALK_GIVEUP_TASK = 0x80000015
const METHOD_TALK = 3
const METHOD_WAIT = 5

var tasks = null # angelica_tasks.gd (Index)
var elements = null # angelica_elements.gd (npc_data.gd)
var active = {} # ID -> Fortschritt (vom Server)
var done = {} # ID -> true (erfüllt, oberste Ebene)
var player = {} # name, level, race, class, gender
var icons = {} # [Art, Thema] -> Name des Bildes (NPCTaskInfo.lua)
var icon_rects = {} # Name des Bildes -> Rect2 im Bildersatz
var icon_texture: Texture2D
var strings = {} # Texttabelle der Oberfläche (2201 ... Geschlecht, 120 + Rasse)
var warnings: Array = []
var npc_pos = {} # NPC-Vorlage -> [Welt, Vector3] (task_npc.data, Ziele der Autoroute)
var item_count: Callable = func(_id): return 0
var _services = {} # NPC-Vorlage -> [Ausgabe, Annahme]


# Im Thread: tasks.data der Sprache indizieren -> "" oder Fehlertext
func open(data_root: String, language: String) -> String:
	var files = load(FILES).new(data_root)
	var script = load(TASKS)
	var path: String = script.locate(files, language)
	if path == "":
		return "tasks.data fehlt"
	tasks = script.new()
	var err = tasks.open(path, files)
	if err != "":
		return err
	tasks.index_all()
	npc_pos = script.npc_positions(files, language)
	_read_icons(files, language)
	return ""

# Bilder und Symbole (NPCTaskInfo.lua, QuestList.txt); aui: aui_manager.gd für Texturen
func set_ui(aui) -> void:
	strings = aui.strings
	icon_texture = aui.texture(ICON_SET)

func _read_icons(files, language: String) -> void:
	var dir = ""
	for base in [language + "/script", "resources/" + language + "/script"]:
		if files.resolve(base) != "":
			dir = files.resolve(base)
			break
	var lua = load(LUA).new(files)
	var p = files.resolve("npctaskinfo.lua", dir) if dir != "" else ""
	if p != "" and lua.run_file(p) == "":
		var info = lua.value("NPCTaskInfo")
		if info is Dictionary:
			for qbt in info:
				for topic in info[qbt]:
					icons[[int(qbt), int(topic)]] = str(info[qbt][topic].get("icon", ""))
	else:
		warnings.append("NPCTaskInfo.lua nicht lesbar")
	lua.close()
	# QuestList.txt: Breite, Höhe, Zeilen, Spalten, dann die Namen zeilenweise (CECImageSet::Init)
	var txt = ""
	for base in [language + "/surfaces", "resources/" + language + "/surfaces", "surfaces"]:
		var tp = files.resolve(base + "/ingame/questlist.txt")
		if tp != "":
			txt = files.get_bytes(tp).get_string_from_ascii()
			break
	var lines = txt.replace("\r", "").split("\n")
	if lines.size() < 4:
		warnings.append("QuestList.txt nicht lesbar")
		return
	var w = int(lines[0])
	var h = int(lines[1])
	var rows = int(lines[2])
	var cols = int(lines[3])
	for i in rows * cols:
		if 4 + i < lines.size() and lines[4 + i].strip_edges() != "":
			icon_rects[lines[4 + i].strip_edges().to_lower()] = Rect2((i % cols) * w, (i / cols) * h, w, h)

func task(id: int) -> Dictionary:
	return tasks.get_task(id) if tasks != null else {}

func set_state(d: Dictionary) -> void:
	active = {}
	for e in d.get("active", []):
		active[int(e[0])] = e[1] if e.size() > 1 else {}
	done = {}
	for id in d.get("done", []):
		done[int(id)] = true


# ====================================================
# BEDINGUNGEN
# ====================================================
func is_active(id: int) -> bool:
	return active.has(id)

func can_deliver(id: int) -> bool:
	var t = task(id)
	if t.is_empty() or t["parent"] != 0 or active.has(id) or not tasks.unsupported(t).is_empty():
		return false
	if done.has(id) and not t["can_redo"]:
		return false
	var lv = int(player.get("level", 1))
	if (t["level_min"] != 0 and lv < t["level_min"]) or (t["level_max"] != 0 and lv > t["level_max"]):
		return false
	if not t["races"].is_empty() and not int(player.get("race", 0)) in t["races"]:
		return false
	if not t["occupations"].is_empty() and not int(player.get("class", 0)) in t["occupations"]:
		return false
	var g = int(t["gender"])
	if (g == 1 and int(player.get("gender", 0)) != 0) or (g == 2 and int(player.get("gender", 0)) != 1):
		return false
	for pre in t["premise_tasks"]:
		if not done.has(int(pre)):
			return false
	for m in tasks.field(t, "m_ulMutexTasks"):
		if int(m) != 0 and (active.has(int(m)) or done.has(int(m))):
			return false
	return true

# Kann der laufende Teil hier abgeschlossen werden? (NPC ansprechen; Warten vorbei)
func can_finish(id: int) -> bool:
	var t = task(id)
	if t.is_empty() or not active.has(id) or not t["subs"].is_empty():
		return false
	match int(t["method"]):
		METHOD_TALK:
			return true
		METHOD_WAIT:
			return Time.get_unix_time_from_system() >= float(active[id].get("until", 0))
		1:
			return _monsters_done(t)
		2:
			return t["items"].all(func(i): return int(item_count.call(int(i["id"]))) >= maxi(1, int(i["num"])))
	return false

# Monster-Ziel erreicht? (Beute in der Tasche bzw. Kills laut Fortschritt)
func _monsters_done(t: Dictionary) -> bool:
	if t["monsters"].is_empty():
		return false
	var prog = active.get(int(t["id"]), {})
	var k = prog.get("k", {}) if prog is Dictionary else {}
	for m in t["monsters"]:
		if int(m.get("drop_item", 0)) != 0:
			if int(item_count.call(int(m["drop_item"]))) < int(m["drop_count"]):
				return false
		elif int(k.get(str(int(m["id"])), 0)) < int(m["num"]):
			return false
	return true

func hidden(t: Dictionary) -> bool:
	return tasks.field(t, "m_bHidden") == true

func topic(t: Dictionary) -> int:
	var root = top_of(t)
	return clampi(int(tasks.field(root, "m_nTopic")), 0, TOPIC_ELSE)

func top_of(t: Dictionary) -> Dictionary:
	var r = t
	while not r.is_empty() and r["parent"] != 0:
		r = task(r["parent"])
	return r


# ====================================================
# NPC
# ====================================================
# Quest-Dienste einer NPC-Vorlage: [Ausgabe, Annahme]
func services(tid: int) -> Array:
	if _services.has(tid):
		return _services[tid]
	var out = []
	var inn = []
	var r: Dictionary = elements.get_record(tid) if elements != null else {}
	for k in [["id_task_out_service", out], ["id_task_in_service", inn]]:
		var sid = int(r.get(k[0], 0))
		if sid != 0:
			for x in elements.get_record(sid).get("id_tasks", []):
				if int(x) != 0:
					k[1].append(int(x))
	_services[tid] = [out, inn]
	return _services[tid]

# Einträge des NPC-Fensters: [{id, kind, talk, title}]
func npc_entries(tid: int) -> Array:
	var sv = services(tid)
	var finish = []
	var get = []
	var running = []
	var seen = {}
	for id in sv[1]:
		if can_finish(id) and _award_npc_ok(id, tid):
			finish.append(_entry(id, QBT_CAN_FINISH, "talk_award"))
			seen[id] = true
	for id in sv[0]:
		if seen.has(id):
			continue
		var t = task(id)
		if t.is_empty() or hidden(t):
			continue
		if active.has(id):
			if not can_finish(id):
				running.append(_entry(id, QBT_CAN_NOT_FINISH, "talk_execute"))
		elif can_deliver(id):
			get.append(_entry(id, QBT_CAN_GET, "talk_deliver"))
	var out = []
	for e in finish + get + running:
		var tk: Dictionary = e["talk"]
		var wins: Array = tk.get("windows", [])
		if wins.size() > 1 or (wins.size() == 1 and str(wins[0]["text"]) != ""):
			out.append(e)
	return out

func _award_npc_ok(id: int, tid: int) -> bool:
	var t = task(id)
	return int(t.get("award_npc", 0)) == 0 or int(t["award_npc"]) == tid or id in services(tid)[1]

func _entry(id: int, kind: int, talk_key: String) -> Dictionary:
	var t = task(id)
	var root = top_of(t)
	var lv = int(tasks.field(root, "m_ulSuitableLevel"))
	var title = ("[%d]" % lv if lv != 0 else "") + str(root["name"])
	if t["id"] != root["id"]:
		title += " - " + str(t["name"])
	return {"id": id, "kind": kind, "talk": t.get(talk_key, {}), "title": title, "topic": topic(t)}

# Symbol über dem NPC (Name im Bildersatz) oder ""
func head_icon(tid: int) -> String:
	var sv = services(tid)
	var kind = 0
	var top_topic = TOPIC_ELSE
	for id in sv[1]:
		if active.has(id) and can_finish(id):
			kind = QBT_CAN_FINISH
			top_topic = mini(top_topic, topic(task(id)))
	if kind == 0:
		for id in sv[0]:
			var t = task(id)
			if not t.is_empty() and not hidden(t) and not active.has(id) and can_deliver(id):
				kind = QBT_CAN_GET
				top_topic = mini(top_topic, topic(t))
	if kind == 0:
		for id in sv[1] + sv[0]:
			if active.has(id) and not can_finish(id) and task(id).get("subs", [1]).is_empty():
				kind = QBT_CAN_NOT_FINISH
				top_topic = mini(top_topic, topic(task(id)))
	if kind == 0:
		return ""
	return icons.get([kind, top_topic], icons.get([kind, 0], ""))

func icon_atlas(icon_name: String) -> AtlasTexture:
	var r = icon_rects.get(icon_name.to_lower())
	if r == null or icon_texture == null:
		return null
	var at = AtlasTexture.new()
	at.atlas = icon_texture
	at.region = r
	return at


# ====================================================
# VERFOLGUNG UND TEXTE
# ====================================================
# Sichtbare Quests der obersten Ebene: [{id, name, part (laufender Teil), goal}]
func trace(npc_name: Callable) -> Array:
	var out = []
	for id in active:
		var t = task(id)
		if t.is_empty() or t["parent"] != 0 or hidden(t):
			continue
		var leaf = _running_leaf(t)
		out.append({"id": id, "name": t["name"], "part": leaf.get("name", "") if leaf != t else "",
			"goal": goal_text(leaf, npc_name), "talk": int(leaf.get("method", 0)) == METHOD_TALK,
			"npc": int(leaf.get("award_npc", 0)) if int(leaf.get("method", 0)) == METHOD_TALK else 0,
			"where": first_pos(str(leaf.get("description", ""))) if int(leaf.get("method", 0)) != METHOD_TALK else [],
			"done": int(leaf.get("method", 0)) != METHOD_TALK and can_finish(leaf.get("id", 0))})
	out.sort_custom(func(a, b): return a["id"] < b["id"])
	return out

# Einträge des Quest-Fensters: trace() dazu Beschreibung, Belohnung (Text) und ob aufgebbar
func log_entries(npc_name: Callable, texts: Dictionary) -> Array:
	var out = trace(npc_name)
	for e in out:
		var t = task(e["id"])
		e["description"] = format_text(str(t.get("description", "")))
		var a: Dictionary = t.get("award", {})
		var parts = []
		if int(a.get("exp", 0)) != 0:
			parts.append("%d EXP" % int(a["exp"]))
		if int(a.get("gold", 0)) != 0:
			parts.append(texts.get("money", "%d") % int(a["gold"]))
		for g in a.get("items", []):
			for it in g.get("items", []):
				parts.append("%s x%d" % [_name(int(it["id"])), maxi(1, int(it["num"]))])
		e["award"] = ", ".join(parts)
		e["giveup"] = t.get("can_give_up", false)
	return out

func _running_leaf(t: Dictionary) -> Dictionary:
	for s in t["subs"]:
		if active.has(s["id"]):
			return _running_leaf(s)
	return t

# Ziel eines Teils als Text (NPC ansprechen: Name des NPCs)
func goal_text(t: Dictionary, npc_name: Callable) -> String:
	if t.is_empty():
		return ""
	match int(t["method"]):
		METHOD_TALK:
			return npc_name.call(int(t["award_npc"])) if int(t["award_npc"]) != 0 else ""
		1:
			return ", ".join(t["monsters"].map(_monster_goal.bind(int(t.get("id", 0)))))
		2:
			return ", ".join(t["items"].map(_item_goal))
	return ""

# Monster-Ziel: Beute in der Tasche ("Beute 3/10") bzw. Kills laut Fortschritt ("Wildschwein 2/5")
func _monster_goal(m: Dictionary, id: int) -> String:
	if int(m.get("drop_item", 0)) != 0:
		var need = int(m["drop_count"])
		return "%s %d/%d" % [_name(int(m["drop_item"])), mini(int(item_count.call(int(m["drop_item"]))), need), need]
	var prog = active.get(id, {})
	var k = prog.get("k", {}) if prog is Dictionary else {}
	var num = int(m["num"])
	return "%s %d/%d" % [_name(int(m["id"])), mini(int(k.get(str(int(m["id"])), 0)), num), num]

# Gesuchter Gegenstand mit Anzahl in der Tasche: "Name 0/1"
func _item_goal(i: Dictionary) -> String:
	var need = int(i["num"])
	return "%s %d/%d" % [_name(int(i["id"])), mini(int(item_count.call(int(i["id"]))), need), need]

func _name(id: int) -> String:
	return elements.name_of(id) if elements != null else str(id)

# Platzhalter wie CDlgTask::FormatTaskText
func format_text(text: String) -> String:
	if not text.contains("&"):
		return text
	var parts = (text + "&").split("&")
	var out = ""
	for i in parts.size():
		if i % 2 == 0:
			out += parts[i]
			continue
		var key: String = parts[i]
		if i == parts.size() - 1:
			break
		match key:
			"":
				out += "^&"
			"name":
				out += str(player.get("name", ""))
			"level":
				out += str(player.get("level", 1))
			"sex1", "sex2", "sex3":
				out += str(strings.get({"sex1": 2201, "sex2": 2203, "sex3": 2205}[key] + int(player.get("gender", 0)), ""))
			"race":
				out += str(strings.get(120 + int(player.get("race", 1)), ""))
			_:
				if key.begins_with("item:"):
					out += _name(key.substr(5).to_int())
				elif key.begins_with("pos:"):
					var p = _parse_pos(key)
					out += POS_OPEN + "%s,%s,%s,%d" % [p[0], p[1], p[2], p[3]] + POS_MID + p[4] + POS_CLOSE if not p.is_empty() else key
	return out

# &pos:(x,y,z,Welt)Name& -> [x, y, z, Welt, Name], [] wenn kein Link
static func _parse_pos(key: String) -> Array:
	var open = key.find("(")
	var close = key.find(")")
	if open < 0 or close < open:
		return []
	var nums = key.substr(open + 1, close - open - 1).split(",")
	if nums.size() < 3:
		return []
	return [nums[0].to_float(), nums[1].to_float(), nums[2].to_float(), nums[3].to_int() if nums.size() > 3 else 0,
		key.substr(close + 1)]

# Erster Koordinaten-Link eines Textes -> [x, y, z, Welt, Name] oder []
static func first_pos(text: String) -> Array:
	var at = text.find("&pos:")
	if at < 0:
		return []
	var end = text.find("&", at + 1)
	return _parse_pos(text.substr(at + 1, end - at - 1)) if end > at else []
