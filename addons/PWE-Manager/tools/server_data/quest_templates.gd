extends SceneTree

# ====================================================
# Erzeugt Server/quest_templates.json: was der Spiel-Server über die Quests wissen muss, aus der
# tasks.data des Clients (Data/angelica_tasks.gd, Version 184; die Server-Datei FW_496 Version 179
# ist noch nicht lesbar - laut Leiste ABGLEICH enthält der Client 8510 ihrer 8517 Quests) und den
# Quest-Diensten der NPCs aus der elements.data des Clients (NPC_TASK_OUT_SERVICE: Quests, die ein
# NPC vergibt; NPC_TASK_IN_SERVICE: Quests, die er abnimmt).
# Ausnahme "auto" (automatisch vergeben): das entscheidet der Server, und seine tasks.data sagt bei
# einigen Quests etwas anderes als die des Clients (z.B. die Werwolf-Startquest 15356 "Andere Welt":
# nur auf dem Server automatisch). Die Server-Datei ist sonst noch nicht lesbar, ihr Kopf schon so weit:
# tasks.data (Magic, Version 179, Anzahl, Teildateien), tasks.data1 - N (Magic, Anzahl, Offsets; je
# Quest oberster Ebene zuerst m_ID), m_bAutoDeliver bei Offset SERVER_AUTO_OFFSET (206 = 218 der
# v181-Struktur - 12; geprüft: 99,5 % der gemeinsamen Quests stimmen mit dem Client überein). Für
# Quests oberster Ebene, die es dort gibt, gilt dieser Wert; ohne Server-Datei der des Clients.
# Aufruf in einem Projekt mit dem Plugin unter res://addons/PWE-Manager:
#   godot --headless --path <Projekt> -s res://addons/PWE-Manager/tools/server_data/quest_templates.gd
#         [-- --client=res://Stock-PWE-Client] [--server=res://Stock-PWE-Server/server-fw/gamed/config]
# Je Quest (alle Ebenen, eine je Zeile; Standardwerte weggelassen):
#   id, name (fürs Log), p Eltern-Quest, s Unteraufgaben (Reihenfolge), m Methode (0 Unteraufgaben,
#   1 Monster töten, 2 Gegenstände sammeln, 3 NPC ansprechen ...), f Abschluss (0 sofort, 1 beim NPC),
#   auto, redo, giveup, order (Unteraufgaben der Reihe nach), one (eine wählen), rand (eine zufällig),
#   psucc / pfail (Erfolg / Misserfolg gilt auch für die Eltern-Quest), hidden, key, delv / anpc (NPC,
#   der vergibt / abnimmt), lv [min, max], race, occ, gender, pre (Vorquests), mutex (Ausschluss),
#   given (Gegenstände bei Vergabe), mon (Monster: id, num Kills; drop / drop_num / prob / common: statt
#   der Kills zählt ein Gegenstand, den das Monster mit prob fallen lässt, common = gewöhnlicher statt
#   Quest-Gegenstand), clear (m_bClearAcquired: gesammelte / erbeutete Gegenstände beim Abschluss
#   einziehen), items (zu sammeln), time (Zeitlimit s), wait
#   (Methode 5 "Warten": Sekunden bis erfüllt), redo_fail (nach Misserfolg wieder annehmbar),
#   award {exp, gold, new (Folgequest), items [{random, items: [{id, num, prob}]}]},
#   block: Felder mit Bedingungen, die der Server noch nicht prüft (Zeitplan, Gebiet, Gilde, Gruppe,
#   Ruf, Gegenstände ...; angelica_tasks.gd UNSUPPORTED) - eine solche Quest vergibt er nicht.
# ====================================================

const PLUGIN = "res://addons/PWE-Manager/"
const Tasks = preload("../../Data/angelica_tasks.gd")
const Elements = preload("../../Data/angelica_elements.gd")
const Files = preload("../../Data/angelica_files.gd")
const OUT = PLUGIN + "Server/quest_templates.json"
const TASK_INFO_MAGIC = 0x03958276
const TASK_PACK_MAGIC = 0x02003304
const SERVER_TASK_VERSION = 179
const SERVER_AUTO_OFFSET = 206
var server_auto = {} # Quest (oberste Ebene) -> m_bAutoDeliver der Server-tasks.data


func _initialize() -> void:
	var args = {}
	for a in OS.get_cmdline_user_args():
		var eq = a.find("=")
		if a.begins_with("--") and eq > 0:
			args[a.substr(2, eq - 2)] = a.substr(eq + 1)
	var files = Files.new(str(args.get("client", "res://Stock-PWE-Client")))
	var t = Tasks.new()
	var tpath: String = Tasks.locate(files, "")
	var err = t.open(tpath, files) if tpath != "" else "tasks.data nicht gefunden"
	if err != "":
		print("FEHLER: ", err)
		quit(1)
		return
	t.load_all()
	print("%s: Version %d, %d Quests (%d oberste Ebene), %d Fehler" % [tpath, t.version, t.tasks.size(), t.top.size(), t.errors.size()])
	var serr = _read_server_auto(str(args.get("server", "res://Stock-PWE-Server/server-fw/gamed/config")))
	var differ = server_auto.keys().filter(func(id): return t.tasks.has(id) and bool(server_auto[id]) != bool(t.tasks[id]["auto_deliver"]))
	print("Server-tasks.data: %s" % (serr if serr != "" else "%d Quests, \"auto\" weicht bei %d ab (gilt der Server)" % [server_auto.size(), differ.size()]))
	var services = _services(files)
	var lines = ["{", "\"source\": %s," % JSON.stringify("%s v%d, NPC-Dienste aus %s, auto aus der Server-tasks.data v%d (%d Quests)" % [
		tpath.get_file(), t.version, services["source"], SERVER_TASK_VERSION, server_auto.size()]),
		"\"note\": \"tools/server_data/quest_templates.gd, Felder siehe dort\","]
	var block_counts = {}
	var ids = t.tasks.keys()
	ids.sort()
	lines.append("\"tasks\": {")
	for i in ids.size():
		var q = _quest(t, t.tasks[ids[i]], block_counts)
		lines.append("%s: %s%s" % [JSON.stringify(str(ids[i])), JSON.stringify(q, "", false), "," if i < ids.size() - 1 else ""])
	lines.append("},")
	for part in ["npc_out", "npc_in"]:
		var d: Dictionary = services[part]
		var keys = d.keys()
		keys.sort()
		lines.append("\"%s\": {" % part)
		for i in keys.size():
			lines.append("%s: %s%s" % [JSON.stringify(str(keys[i])), JSON.stringify(d[keys[i]]), "," if i < keys.size() - 1 else ""])
		lines.append("}," if part == "npc_out" else "}")
	lines.append("}")
	var f = FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	var free = 0
	for id in t.top:
		if not t.tasks[id].has("_blocked"):
			free += 1
	var bc = block_counts.keys()
	bc.sort_custom(func(a, b): return block_counts[a] > block_counts[b])
	print("oberste Ebene: %d ohne Sperre, gesperrt nach Feld: %s" % [free, ", ".join(bc.map(func(k): return "%s %d" % [k, block_counts[k]]))])
	print("NPC-Dienste: %d vergeben, %d nehmen ab -> %s" % [services["npc_out"].size(), services["npc_in"].size(), OUT])
	quit(0)

func _quest(t, q: Dictionary, block_counts: Dictionary) -> Dictionary:
	var o = {"id": q["id"], "name": q["name"]}
	if q["parent"] != 0:
		o["p"] = q["parent"]
	if not q["subs"].is_empty():
		o["s"] = q["subs"].map(func(x): return x["id"])
	o["m"] = q["method"]
	if q["finish_type"] != 0:
		o["f"] = q["finish_type"]
	var auto = server_auto.get(q["id"], q["auto_deliver"]) if q["parent"] == 0 else q["auto_deliver"]
	var flags = {"auto": auto, "redo": q["can_redo"], "giveup": q["can_give_up"],
		"order": t.field(q, "m_bExeChildInOrder"), "one": t.field(q, "m_bChooseOne"), "rand": t.field(q, "m_bRandOne"),
		"psucc": t.field(q, "m_bParentAlsoSucc"), "pfail": t.field(q, "m_bParentAlsoFail"), "hidden": t.field(q, "m_bHidden"),
		"key": t.field(q, "m_bKeyTask")}
	for k in flags:
		if flags[k]:
			o[k] = true
	for k in [["delv", "delv_npc"], ["anpc", "award_npc"], ["gender", "gender"], ["time", "time_limit"]]:
		if int(q[k[1]]) != 0:
			o[k[0]] = q[k[1]]
	if q["level_min"] != 0 or q["level_max"] != 0:
		o["lv"] = [q["level_min"], q["level_max"]]
	for k in [["race", "races"], ["occ", "occupations"], ["pre", "premise_tasks"]]:
		if not q[k[1]].is_empty():
			o[k[0]] = q[k[1]]
	if int(t.field(q, "m_ulWaitTime")) != 0:
		o["wait"] = int(t.field(q, "m_ulWaitTime"))
	if t.field(q, "m_bCanRedoAfterFailure"):
		o["redo_fail"] = true
	var mutex = (t.field(q, "m_ulMutexTasks") as Array).filter(func(x): return int(x) != 0)
	if not mutex.is_empty():
		o["mutex"] = mutex
	for k in [["given", "given_items"], ["items", "items"]]:
		if not q[k[1]].is_empty():
			o[k[0]] = q[k[1]].map(func(it): return {"id": it["id"], "num": it["num"]})
	if not q["monsters"].is_empty():
		o["mon"] = q["monsters"].map(_monster)
	if t.field(q, "m_bClearAcquired"):
		o["clear"] = true
	var a: Dictionary = q["award"]
	var aw = {}
	for k in [["exp", "exp"], ["gold", "gold"], ["new", "new_task"]]:
		if int(a[k[1]]) != 0:
			aw[k[0]] = a[k[1]]
	if not a["items"].is_empty():
		aw["items"] = a["items"].map(func(g): return {"random": g["random"],
			"items": g["items"].map(func(it): return {"id": it["id"], "num": it["num"], "prob": snappedf(it["prob"], 0.0001)})})
	if not aw.is_empty():
		o["award"] = aw
	if q["parent"] == 0:
		var block: Array = t.unsupported(q)
		for fname in block:
			block_counts[fname] = block_counts.get(fname, 0) + 1
		if not block.is_empty():
			o["block"] = block
			q["_blocked"] = true
	return o

static func _monster(m: Dictionary) -> Dictionary:
	var o = {"id": m["id"], "num": m["num"]}
	if int(m.get("drop_item", 0)) != 0:
		o["drop"] = m["drop_item"]
		o["drop_num"] = m["drop_count"]
		o["prob"] = snappedf(float(m.get("drop_prob", 1.0)), 0.0001)
		if m.get("drop_common", false):
			o["common"] = true
	return o

# m_bAutoDeliver der Quests oberster Ebene aus der Server-tasks.data -> "" oder Fehlertext
func _read_server_auto(dir: String) -> String:
	var info = FileAccess.get_file_as_bytes(dir.path_join("tasks.data")) if FileAccess.file_exists(dir.path_join("tasks.data")) else PackedByteArray()
	if info.size() < 20 or info.decode_u32(0) != TASK_INFO_MAGIC:
		return "nicht gefunden (%s), auto wie im Client" % dir
	if info.decode_u32(4) != SERVER_TASK_VERSION:
		return "Version %d statt %d, auto wie im Client" % [info.decode_u32(4), SERVER_TASK_VERSION]
	for n in range(1, info.decode_u32(12) + 1):
		var path = dir.path_join("tasks.data%d" % n)
		var b = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()
		if b.size() < 8 or b.decode_u32(0) != TASK_PACK_MAGIC:
			continue
		for i in b.decode_u32(4):
			var off = b.decode_u32(8 + 4 * i) if 8 + 4 * i + 4 <= b.size() else -1
			if off >= 0 and off + SERVER_AUTO_OFFSET < b.size():
				server_auto[b.decode_u32(off)] = b[off + SERVER_AUTO_OFFSET] == 1
	return ""

# Quest-Dienste aller NPCs: {source, npc_out: {NPC: [Quests]}, npc_in: {...}}
func _services(files) -> Dictionary:
	var out = {"source": "-", "npc_out": {}, "npc_in": {}}
	var path: String = Elements.locate(files, "Deu")
	var el = Elements.new()
	if path == "" or el.open(path, files) != "":
		print("WARNUNG: elements.data nicht lesbar, keine NPC-Dienste")
		return out
	out["source"] = "%s 0x%x" % [path.get_file(), el.version]
	var li = el.list_of("NPC_ESSENCE")
	for i in el.lists[li]["count"]:
		var r = el.record(li, i)
		for k in [["npc_out", "id_task_out_service"], ["npc_in", "id_task_in_service"]]:
			var sid = int(r.get(k[1], 0))
			if sid == 0:
				continue
			var sr = el.get_record(sid)
			var tasks = sr.get("id_tasks", [])
			if tasks is Array:
				var list = tasks.filter(func(x): return int(x) != 0)
				if not list.is_empty():
					out[k[0]][int(r["id"])] = list
	return out
