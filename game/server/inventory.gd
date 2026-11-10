extends RefCounted

# ====================================================
# Inventar, Ausrüstung und Sammeln auf dem Server (Fahrplan Schritt 10b), vereinfacht nach dem gs
# (item_list, player_imp::EquipItem, gmatter_mine_imp). Daten: Plugin Server/item_templates.json
# (tools/server_data/item_templates.gd aus der elements.data des Clients).
# Zustand je Figur (players[...]): bag {Platz: [ID, Anzahl]} (Tabelle inventory, Ort 0, Plätze
# 0 .. bag_size - 1), equip {Platz: ID} (Ort 1, Platz = EQUIP_INDEX_* = Bit in equip_mask).
#   add       stapelt bis pile (Stapelgröße der Vorlage), dann freie Plätze von vorn
#   equip     Gegenstand aus der Tasche an seinen Platz (erstes Bit seiner equip_mask, bei mehreren
#             Bits der erste freie); Bedingungen wie CECIvtrEquip: Stufe, Rasse (Bit), Klasse (Bit,
#             0 = alle), Geschlecht; was dort lag, kommt an den frei gewordenen Taschenplatz
#   unequip   zurück in die Tasche (an den genannten freien Platz bzw. den ersten freien)
#   move      zwei Taschenplätze tauschen (gleiche Vorlage mit Platz im Stapel: zusammenlegen)
# Werte (apply_stats): Höchst-HP / -MP = Klasse und Stufe (stats.gd) + hp / mp der Ausrüstung;
# Kampfwerte attr (stats.gd attributes) mit Angriff, Verteidigung, Treffer der Ausrüstung.
# Sammeln (gather): Sammelpunkt (npcs.gd, Vorlage in mines) in Sicht, höchstens dist + GATHER_SLACK m
# entfernt, Quest task_in läuft (falls verlangt), nicht schon beim Sammeln; Dauer t[0] - t[1] s.
# Fertig (tick): noch in der Nähe -> task_out an quests.gd mine() (CheckMining: der gesuchte
# Gegenstand der Quest), sonst ein Material nach Wahrscheinlichkeit; ein Punkt ohne perm verschwindet
# (npcs.gd harvest, Respawn). Bewegt sich die Figur mehr als GATHER_MOVE m, bricht es ab.
# Meldungen: inventory {size, bag: [[Platz, ID, Anzahl]], equip: [[Platz, ID]]}, gather_end {id, ok,
# items: [[ID, Anzahl]]}; Ausrüstung für andere: player_equip {id, equip} (world.gd).
# ====================================================

const Proto = preload("../common/protocol.gd")
const Settings = preload("../common/settings.gd")
const PLUGIN_SERVER = "res://addons/PWE-Manager/Server/"
const BAG_SIZE = 24 # Startvorlagen inventory_size
const BAG = 0
const EQUIP = 1
const EQUIP_SLOTS = 32
const GATHER_SLACK = 1.5 # m zusätzlich zu max_distance (Lauf-Latenz)
const GATHER_MOVE = 0.5 # m: weiter bewegt = abgebrochen

var db
var net
var log_line: Callable
var stats # stats.gd
var quests = null # quests.gd (Sammeln für Quests, Gegenstands-Ziele)
var items = {} # ID -> Vorlage
var mines = {} # ID -> Sammelpunkt-Vorlage
var on_equip_changed: Callable # (peer, p): andere Spieler informieren (world.gd)


func _init(p_db, p_net, p_log: Callable, p_stats) -> void:
	db = p_db
	net = p_net
	log_line = p_log
	stats = p_stats

# item_templates.json laden -> "" oder Fehlertext
func load_templates() -> String:
	var path = Settings.server_data_path("item_templates.json")
	var d = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not d is Dictionary or not d.has("items"):
		return "Файл отсутствует или недоступен для чтения: " + path
	for k in d["items"]:
		items[int(k)] = _ints(d["items"][k])
	for k in d.get("mines", {}):
		mines[int(k)] = _ints(d["mines"][k])
	return ""

static func _ints(t: Dictionary) -> Dictionary:
	for k in t:
		var v = t[k]
		if v is float and k != "dist" and k != "range":
			t[k] = int(v)
		elif v is Array and k in ["t", "lv", "dmg"]:
			t[k] = v.map(func(x): return int(x))
	return t

func item(id: int) -> Dictionary:
	return items.get(id, {})

func pile_of(id: int) -> int:
	return maxi(1, int(item(id).get("pile", 1)))


# ====================================================
# ZUSTAND JE FIGUR
# ====================================================
func load_player(p: Dictionary) -> void:
	p["bag"] = {}
	p["equip"] = {}
	p["bag_size"] = BAG_SIZE
	p["gather"] = {}
	var rows = db.query("SELECT location, pos, item_id, count FROM inventory WHERE character_id = ? AND location IN (?, ?)",
		[p["id"], BAG, EQUIP])
	for r in (rows if rows != null else []):
		if int(r["location"]) == BAG:
			p["bag"][int(r["pos"])] = [int(r["item_id"]), int(r["count"])]
		else:
			p["equip"][int(r["pos"])] = int(r["item_id"])

func state_of(p: Dictionary) -> Dictionary:
	var bag = []
	var keys = p["bag"].keys()
	keys.sort()
	for pos in keys:
		bag.append([pos, p["bag"][pos][0], p["bag"][pos][1]])
	return {"size": p["bag_size"], "bag": bag, "equip": equip_list(p["equip"])}

static func equip_list(equip: Dictionary) -> Array:
	var out = []
	var keys = equip.keys()
	keys.sort()
	for slot in keys:
		out.append([slot, equip[slot]])
	return out

func push(peer: int, p: Dictionary) -> void:
	net.push(peer, "inventory", state_of(p))

# Ausrüstung einer Figur aus der Datenbank (char_enter, vor dem Betreten): {Platz: ID}
func equip_of(char_id: int) -> Dictionary:
	var out = {}
	var rows = db.query("SELECT pos, item_id FROM inventory WHERE character_id = ? AND location = ?", [char_id, EQUIP])
	for r in (rows if rows != null else []):
		out[int(r["pos"])] = int(r["item_id"])
	return out

func count_of(p: Dictionary, id: int) -> int:
	var n = 0
	for pos in p["bag"]:
		if p["bag"][pos][0] == id:
			n += p["bag"][pos][1]
	return n

func free_slot(p: Dictionary) -> int:
	for i in p["bag_size"]:
		if not p["bag"].has(i):
			return i
	return -1

# Passen die Gegenstände [[ID, Anzahl]] (mit Stapeln) in die Tasche?
func can_add(p: Dictionary, list: Array) -> bool:
	var free = 0
	for i in p["bag_size"]:
		if not p["bag"].has(i):
			free += 1
	var room = {} # ID -> Platz in angefangenen Stapeln
	for pos in p["bag"]:
		var e: Array = p["bag"][pos]
		room[e[0]] = room.get(e[0], 0) + maxi(0, pile_of(e[0]) - e[1])
	for it in list:
		var id = int(it[0])
		var n = int(it[1])
		var fit = mini(n, room.get(id, 0))
		room[id] = room.get(id, 0) - fit
		n -= fit
		var pile = pile_of(id)
		while n > 0:
			if free == 0:
				return false
			free -= 1
			var put = mini(n, pile)
			room[id] = room.get(id, 0) + pile - put
			n -= put
	return true

# In die Tasche legen -> [[Platz, Anzahl]] (leer = kein Platz; vorher can_add prüfen)
func add(p: Dictionary, id: int, count: int) -> Array:
	var out = []
	var pile = pile_of(id)
	var left = count
	var keys = p["bag"].keys()
	keys.sort()
	for pos in keys:
		var e: Array = p["bag"][pos]
		if left > 0 and e[0] == id and e[1] < pile:
			var put = mini(left, pile - e[1])
			e[1] += put
			left -= put
			_save(p, BAG, pos, id, e[1])
			out.append([pos, put])
	while left > 0:
		var pos = free_slot(p)
		if pos < 0:
			break
		var put = mini(left, pile)
		p["bag"][pos] = [id, put]
		left -= put
		_save(p, BAG, pos, id, put)
		out.append([pos, put])
	return out


# Aus der Tasche nehmen (von hinten) -> entfernte Anzahl
func remove(p: Dictionary, id: int, count: int) -> int:
	var left = count
	var keys = p["bag"].keys()
	keys.sort()
	keys.reverse()
	for pos in keys:
		var e: Array = p["bag"][pos]
		if left <= 0 or e[0] != id:
			continue
		var take = mini(left, e[1])
		e[1] -= take
		left -= take
		if e[1] <= 0:
			p["bag"].erase(pos)
			_delete(p, BAG, pos)
		else:
			_save(p, BAG, pos, id, e[1])
	return count - left


# ====================================================
# ANFRAGEN -> [Code, Daten]
# ====================================================
func equip(peer: int, p: Dictionary, pos: int) -> Array:
	var e = p["bag"].get(pos)
	if e == null:
		return [Proto.Code.ITEM_INVALID, {}]
	var t = item(e[0])
	var mask = int(t.get("mask", 0))
	if mask == 0:
		return [Proto.Code.ITEM_CANNOT_EQUIP, {}]
	if not can_wear(p, t):
		return [Proto.Code.ITEM_REQUIREMENTS, {}]
	var slot = -1
	for i in EQUIP_SLOTS:
		if mask & (1 << i):
			if slot < 0:
				slot = i
			if not p["equip"].has(i):
				slot = i
				break
	var old = p["equip"].get(slot, 0)
	p["equip"][slot] = e[0]
	_save(p, EQUIP, slot, e[0], 1)
	if old != 0:
		p["bag"][pos] = [old, 1]
		_save(p, BAG, pos, old, 1)
	else:
		p["bag"].erase(pos)
		_delete(p, BAG, pos)
	log_line.call("Экипировка: %s надел предмет %d (ячейка %d)%s" % [p["name"], e[0], slot, (", предмет %d перемещён в инвентарь" % old) if old != 0 else ""])
	_changed(peer, p)
	return [Proto.Code.OK, {"slot": slot}]

func unequip(peer: int, p: Dictionary, slot: int, to: int = -1) -> Array:
	var id = int(p["equip"].get(slot, 0))
	if id == 0:
		return [Proto.Code.ITEM_INVALID, {}]
	if to < 0 or to >= p["bag_size"] or p["bag"].has(to):
		to = free_slot(p)
	if to < 0:
		return [Proto.Code.BAG_FULL, {}]
	p["equip"].erase(slot)
	_delete(p, EQUIP, slot)
	p["bag"][to] = [id, 1]
	_save(p, BAG, to, id, 1)
	log_line.call("Экипировка: %s снял предмет %d (ячейка %d → инвентарь %d)" % [p["name"], id, slot, to])
	_changed(peer, p)
	return [Proto.Code.OK, {"pos": to}]

func move(peer: int, p: Dictionary, from: int, to: int) -> Array:
	if from == to or from < 0 or to < 0 or from >= p["bag_size"] or to >= p["bag_size"] or not p["bag"].has(from):
		return [Proto.Code.ITEM_INVALID, {}]
	var a: Array = p["bag"][from]
	var b = p["bag"].get(to)
	if b != null and b[0] == a[0] and b[1] < pile_of(a[0]):
		var put = mini(a[1], pile_of(a[0]) - b[1])
		b[1] += put
		a[1] -= put
		_save(p, BAG, to, b[0], b[1])
		if a[1] <= 0:
			p["bag"].erase(from)
			_delete(p, BAG, from)
		else:
			_save(p, BAG, from, a[0], a[1])
	else:
		p["bag"].erase(from)
		_delete(p, BAG, from)
		if b != null:
			p["bag"].erase(to)
			_delete(p, BAG, to)
			p["bag"][from] = b
			_save(p, BAG, from, b[0], b[1])
		p["bag"][to] = a
		_save(p, BAG, to, a[0], a[1])
	push(peer, p)
	return [Proto.Code.OK, {}]

# Bedingungen einer Ausrüstung (CECIvtrEquip: Stufe, Rasse, Klasse, Geschlecht)
func can_wear(p: Dictionary, t: Dictionary) -> bool:
	if int(t.get("lv", 0)) > p["level"]:
		return false
	var race = int(t.get("race", 0))
	if race != 0 and not race & (1 << int(p["race"])):
		return false
	var prof = int(t.get("prof", 0))
	if prof != 0 and not prof & (1 << int(p["class"])):
		return false
	return not t.has("gender") or int(t["gender"]) == int(p["gender"])

func _changed(peer: int, p: Dictionary) -> void:
	apply_stats(p)
	push(peer, p)
	if quests != null:
		quests.save_stats(p)
		net.push(peer, "stats", quests.stats_of(p))
	if on_equip_changed.is_valid():
		on_equip_changed.call(peer, p)


# ====================================================
# WERTE
# ====================================================
# Summe der Ausrüstung: {hp, mp, dmg [min, max], def, hit}
func bonus(equip: Dictionary) -> Dictionary:
	var b = {"hp": 0, "mp": 0, "dmg": [0, 0], "def": 0, "hit": 0}
	for slot in equip:
		var t = item(int(equip[slot]))
		b["hp"] += int(t.get("hp", 0))
		b["mp"] += int(t.get("mp", 0))
		b["def"] += int(t.get("def", 0))
		b["hit"] += int(t.get("hit", 0))
		var d: Array = t.get("dmg", [0, 0])
		b["dmg"][0] += int(d[0])
		b["dmg"][1] += int(d[1])
	return b

# Höchstwerte und Kampfwerte nach Klasse, Stufe und Ausrüstung; HP / MP höchstens bis dahin
func apply_stats(p: Dictionary) -> void:
	var b = bonus(p.get("equip", {}))
	var buff_hp = int(p.get("buff_hp", 0)) # Statuseffekte (buffs.gd)
	var buff_mp = int(p.get("buff_mp", 0))
	p["max_hp"] = stats.max_hp(p["class"], p["level"], p["max_hp"] - int(p.get("bonus_hp", 0)) - buff_hp) + b["hp"] + buff_hp
	p["max_mp"] = stats.max_mp(p["class"], p["level"], p["max_mp"] - int(p.get("bonus_mp", 0)) - buff_mp) + b["mp"] + buff_mp
	p["bonus_hp"] = b["hp"]
	p["bonus_mp"] = b["mp"]
	p["hp"] = mini(int(p["hp"]), p["max_hp"])
	p["mp"] = mini(int(p["mp"]), p["max_mp"])
	p["attr"] = stats.attributes(p["class"], p["level"], b)


# ====================================================
# SAMMELN
# ====================================================
# nm: npcs.gd der Map des Spielers
func gather(peer: int, p: Dictionary, nm, id: int) -> Array:
	if not p["gather"].is_empty():
		return [Proto.Code.GATHER_BUSY, {}]
	var o = nm.objects.get(id) if nm != null and p["npc_seen"].has(id) else null
	var m = mines.get(int(o["tid"]), {}) if o != null and o.get("mine", false) else {}
	if m.is_empty():
		return [Proto.Code.GATHER_INVALID, {}]
	if p["pos"].distance_to(o["pos"]) > float(m.get("dist", 3.0)) + GATHER_SLACK:
		return [Proto.Code.GATHER_TOO_FAR, {}]
	var task_in = int(m.get("task_in", 0))
	if task_in != 0 and (quests == null or not p["quests"]["active"].has(task_in)):
		return [Proto.Code.GATHER_NO_TASK, {}]
	var lv: Array = m.get("lv", [0, 0])
	if (lv[0] != 0 and p["level"] < lv[0]) or (lv[1] != 0 and p["level"] > lv[1]):
		return [Proto.Code.GATHER_INVALID, {}]
	if nm.busy(id) and not m.get("multi", false):
		return [Proto.Code.GATHER_BUSY, {}]
	var t: Array = m.get("t", [0, 0])
	var secs = randi_range(int(t[0]), maxi(int(t[0]), int(t[1])))
	p["gather"] = {"id": id, "tid": int(o["tid"]), "end": Time.get_ticks_msec() + secs * 1000, "pos": p["pos"]}
	nm.lock(id, p["id"])
	return [Proto.Code.OK, {"id": id, "time": secs}]

func cancel_gather(peer: int, p: Dictionary, nm, notify: bool) -> void:
	var g: Dictionary = p.get("gather", {})
	if g.is_empty():
		return
	p["gather"] = {}
	if nm != null:
		nm.unlock(g["id"], p["id"])
	if notify:
		net.push(peer, "gather_end", {"id": g["id"], "ok": false})

# Jeden Takt: Sammeln fertig?
func tick(peer: int, p: Dictionary, nm) -> void:
	var g: Dictionary = p.get("gather", {})
	if g.is_empty() or Time.get_ticks_msec() < int(g["end"]):
		return
	var o = nm.objects.get(g["id"]) if nm != null else null
	var m: Dictionary = mines.get(int(g["tid"]), {})
	if o == null or p["pos"].distance_to(o["pos"]) > float(m.get("dist", 3.0)) + GATHER_SLACK * 2.0:
		cancel_gather(peer, p, nm, true)
		return
	p["gather"] = {}
	nm.unlock(g["id"], p["id"])
	var got = []
	var task_out = int(m.get("task_out", 0))
	if task_out != 0 and quests != null:
		got = quests.mine(peer, p, task_out)
	else:
		var r = randf()
		for mat in m.get("mat", []):
			r -= float(mat[1])
			if r <= 0.0:
				if can_add(p, [[int(mat[0]), 1]]):
					add(p, int(mat[0]), 1)
					got.append([int(mat[0]), 1])
				break
	if not got.is_empty():
		push(peer, p)
	if not m.get("perm", false):
		nm.harvest(g["id"], Time.get_ticks_msec() / 1000.0)
	net.push(peer, "gather_end", {"id": g["id"], "ok": true, "items": got})
	log_line.call("Сбор ресурсов: %s у точки %d → %s" % [p["name"], int(g["tid"]), str(got)])
	if quests != null and not got.is_empty():
		quests.check_items(peer, p)


# ====================================================
# DATENBANK
# ====================================================
func _save(p: Dictionary, loc: int, pos: int, id: int, count: int) -> void:
	if not db.run("INSERT OR REPLACE INTO inventory (character_id, location, pos, item_id, count) VALUES (?, ?, ?, ?, ?)",
			[p["id"], loc, pos, id, count]):
		log_line.call("ОШИБКА базы данных: " + db.last_error)

func _delete(p: Dictionary, loc: int, pos: int) -> void:
	if not db.run("DELETE FROM inventory WHERE character_id = ? AND location = ? AND pos = ?", [p["id"], loc, pos]):
		log_line.call("ОШИБКА базы данных: " + db.last_error)
