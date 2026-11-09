extends RefCounted

# ====================================================
# Fertigkeiten der Figuren (wie SkillWrapper): bekannte Fertigkeiten mit Stufe (Tabelle skills) und
# Schnellleisten (Tabelle shortcuts).
#   Startfertigkeiten: die der Startvorlage (Plugin Server/start_roles.json skills_raw = clsconfig
#   GRoleStatus.skills im Format von SkillWrapper::LoadDatabase: Version (1 Byte), bei Version 1 der
#   Talentzweig (1 Byte), Anzahl (4 Byte), je ID (4 Byte) und Stufe (1 Byte)); eine Figur ohne
#   gespeicherte Fertigkeit bekommt sie beim Betreten der Welt, als "neu". Dazu kennt jede Figur
#   DEFAULT_SKILLS (120 Stadtportal, wie LoadDatabase mit MASK_DEFAULT_SKILL; nicht gespeichert).
#   Neue Fertigkeiten (new) zeigt der Client im Fenster "Neue Fertigkeiten" (Win_NewSKill), bis er sie
#   mit skill_seen weglegt (CECHostPlayer::RemoveNewSkill); learn() gibt weitere (Meldung skill_new).
#   Schnellleisten: Leiste 0 unten (Win_QuickBar0), 1 rechts (Win_QuickBar1), je SLOTS Plätze; nur
#   bekannte Fertigkeiten.
#   load_player(p, Vorlage), state_of(p) -> {skills: [[ID, Stufe]], new: [IDs], shortcuts: [[Leiste, Platz, ID]]}
#   seen(p, ids), set_shortcut(p, Leiste, Platz, ID) -> [Code, Daten]
#   Einsetzen und Werte (info, Meldung skill_info): skill_cast.gd
# ====================================================

const Proto = preload("../common/protocol.gd")
const DEFAULT_SKILLS = {120: 1}
const BARS = 2
const SLOTS = 10

var db
var net
var log_line: Callable
var info_of: Callable # (p, ID) -> Werte der Fertigkeit (skill_cast.gd info), Meldung skill_info beim Lernen


func _init(p_db, p_net, p_log: Callable) -> void:
	db = p_db
	net = p_net
	log_line = p_log

# Fertigkeiten und Leisten aus der DB; ohne gespeicherte die der Startvorlage (neu)
func load_player(p: Dictionary, template: Dictionary) -> void:
	var known = {}
	var fresh = {}
	var rows = db.query("SELECT skill_id, level, new FROM skills WHERE character_id = ?", [p["id"]])
	for r in (rows if rows != null else []):
		known[int(r["skill_id"])] = int(r["level"])
		if int(r["new"]) != 0:
			fresh[int(r["skill_id"])] = true
	if known.is_empty() and rows != null:
		for e in start_skills(str(template.get("skills_raw", ""))):
			if _save(p, e[0], e[1], true):
				known[e[0]] = e[1]
				fresh[e[0]] = true
		if not known.is_empty():
			log_line.call("Fertigkeiten: %s bekommt die Startfertigkeiten %s" % [p["name"], str(known.keys())])
	for id in DEFAULT_SKILLS:
		if not known.has(id):
			known[id] = DEFAULT_SKILLS[id]
	var bars = {}
	var srows = db.query("SELECT bar, slot, skill_id FROM shortcuts WHERE character_id = ?", [p["id"]])
	for r in (srows if srows != null else []):
		bars[Vector2i(int(r["bar"]), int(r["slot"]))] = int(r["skill_id"])
	p["skills"] = known
	p["skills_new"] = fresh
	p["shortcuts"] = bars

func state_of(p: Dictionary) -> Dictionary:
	var sk = []
	var known: Dictionary = p.get("skills", {})
	var ids = known.keys()
	ids.sort()
	for id in ids:
		sk.append([id, known[id]])
	var sc = []
	for k in p.get("shortcuts", {}):
		sc.append([k.x, k.y, p["shortcuts"][k]])
	return {"skills": sk, "new": p.get("skills_new", {}).keys(), "shortcuts": sc}

# Startfertigkeiten aus skills_raw (hex) -> [[ID, Stufe], ...]
static func start_skills(raw: String) -> Array:
	var b = raw.hex_decode()
	var out = []
	if b.size() < 5:
		return out
	var p = 1 + (1 if b[0] == 1 else 0)
	var n = b.decode_u32(p)
	p += 4
	for i in n:
		if p + 5 > b.size():
			break
		out.append([b.decode_u32(p), b[p + 4]])
		p += 5
	return out

# Aus dem Fenster "Neue Fertigkeiten" weggelegt (gezogen oder Fenster geschlossen)
func seen(p: Dictionary, ids) -> Array:
	if not ids is Array:
		return [Proto.Code.BAD_REQUEST, {}]
	var fresh: Dictionary = p.get("skills_new", {})
	for v in ids:
		if (v is int or v is float) and fresh.has(int(v)):
			fresh.erase(int(v))
			db.run("UPDATE skills SET new = 0 WHERE character_id = ? AND skill_id = ?", [p["id"], int(v)])
	return [Proto.Code.OK, {"new": fresh.keys()}]

# Platz einer Schnellleiste belegen (id 0 = leeren)
func set_shortcut(p: Dictionary, bar, slot, id) -> Array:
	if not bar is int or not slot is int or not id is int:
		return [Proto.Code.BAD_REQUEST, {}]
	if bar < 0 or bar >= BARS or slot < 0 or slot >= SLOTS:
		return [Proto.Code.SHORTCUT_INVALID, {}]
	if id != 0 and not p.get("skills", {}).has(id):
		return [Proto.Code.SKILL_UNKNOWN, {}]
	var key = Vector2i(bar, slot)
	if id == 0:
		p["shortcuts"].erase(key)
		db.run("DELETE FROM shortcuts WHERE character_id = ? AND bar = ? AND slot = ?", [p["id"], bar, slot])
	else:
		p["shortcuts"][key] = id
		db.run("INSERT OR REPLACE INTO shortcuts (character_id, bar, slot, skill_id) VALUES (?, ?, ?, ?)", [p["id"], bar, slot, id])
	return [Proto.Code.OK, {"bar": bar, "slot": slot, "id": id}]

# Fertigkeit lernen bzw. Stufe setzen; neu gelernte meldet skill_new (Popup im Client)
func learn(peer: int, p: Dictionary, id: int, level: int = 1) -> void:
	var known: Dictionary = p.get("skills", {})
	var is_new = not known.has(id)
	if _save(p, id, level, is_new):
		known[id] = level
		if is_new:
			p["skills_new"][id] = true
		net.push(peer, "skill_new" if is_new else "skill_level", {"id": id, "level": level})
		if info_of.is_valid():
			net.push(peer, "skill_info", {"id": id, "info": info_of.call(p, id)})
		log_line.call("Fertigkeiten: %s lernt %d (Stufe %d)" % [p["name"], id, level])

func _save(p: Dictionary, id: int, level: int, is_new: bool) -> bool:
	if db.run("INSERT OR REPLACE INTO skills (character_id, skill_id, level, new) VALUES (?, ?, ?, ?)", [p["id"], id, level, 1 if is_new else 0]):
		return true
	log_line.call("FEHLER Datenbank: " + db.last_error)
	return false
