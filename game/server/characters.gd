extends RefCounted

# ====================================================
# Figuren der Konten (Tabelle characters, schema.gd): auflisten, anlegen, löschen, auswählen.
# Anlegen nach den Startvorlagen des Servers (Plugin Server/start_roles.json aus clsconfig):
# nur Rasse / Klasse / Geschlecht mit Vorlage (sonst CLASS_CLOSED), Startwelt, Position, Leben,
# Mana, Geld, Inventar und Ausrüstung aus der Vorlage.
# Name: 2 - 12 Zeichen, Buchstabe vorn, dann Buchstaben / Ziffern (auch Umlaute), nicht in der
# Wortliste des Spiels (Server/data/badwords.txt: Einträge mit Leerzeichen am Rand gelten nur an
# Wortgrenzen), eindeutig ohne Groß- / Kleinschreibung.
# Aussehen (wie GRoleInfo / DlgCreateSelectStyle): face, mask, hair, skin (Indizes), hair_color
# (0xRRGGBB); gespeichert als JSON.
# Bis zu MAX_CHARS Figuren je Konto (Win_CharList hat 8 Plätze). Löschen geht sofort.
# ====================================================

const Proto = preload("../common/protocol.gd")
const PLUGIN_SERVER = "res://addons/PWE-Manager/Server/"
const MAX_CHARS = 8
const NAME_MIN = 2
const NAME_MAX = 12
const APPEARANCE_LIMITS = {"face": 20, "mask": 10, "hair": 50, "skin": 19}
const LIST_COLUMNS = "id, slot, name, race, class, gender, level, appearance, map, last_played"

var db
var templates = {} # "<Rasse>_<Klasse>_<Geschlecht>" -> Vorlage aus start_roles.json
var badwords: Array = []
var _name_re = RegEx.new()


func _init(p_db) -> void:
	db = p_db
	_name_re.compile("^\\p{L}[\\p{L}\\p{N}]{%d,%d}$" % [NAME_MIN - 1, NAME_MAX - 1])
	var d = JSON.parse_string(FileAccess.get_file_as_string(PLUGIN_SERVER + "start_roles.json"))
	if d is Dictionary:
		for r in d.get("roles", []):
			templates["%d_%d_%d" % [r["race"], r["class"], r["gender"]]] = r
	var f = FileAccess.open(PLUGIN_SERVER + "data/badwords.txt", FileAccess.READ)
	if f != null:
		var b = f.get_buffer(f.get_length())
		var text = b.get_string_from_utf16() if b.size() >= 2 and b[0] == 0xFF and b[1] == 0xFE else b.get_string_from_utf8()
		for line in text.split("\n", false):
			var w = line.strip_edges().trim_prefix("\"").trim_suffix("\"").to_lower()
			if w.strip_edges() != "":
				badwords.append(w)

func valid_name(char_name: String) -> bool:
	if _name_re.search(char_name) == null:
		return false
	var padded = " " + char_name.to_lower() + " "
	for w in badwords:
		if padded.contains(w):
			return false
	return true


# ====================================================
# ANFRAGEN -> [Code, Daten]
# ====================================================
func list(account_id: int) -> Array:
	var rows = db.query("SELECT %s FROM characters WHERE account_id = ? AND deleted = 0 ORDER BY slot" % LIST_COLUMNS, [account_id])
	if rows == null:
		return [Proto.Code.SERVER_ERROR, {}]
	var out = []
	for r in rows:
		out.append(_public(r))
	return [Proto.Code.OK, {"chars": out, "max": MAX_CHARS, "classes": templates.keys()}]

func create(account_id: int, args: Dictionary) -> Array:
	var char_name = args.get("name")
	var race = args.get("race")
	var cls = args.get("class")
	var gender = args.get("gender")
	var look = args.get("appearance", {})
	if not (char_name is String and race is int and cls is int and gender is int and look is Dictionary):
		return [Proto.Code.BAD_REQUEST, {}]
	char_name = char_name.strip_edges()
	if not valid_name(char_name):
		return [Proto.Code.CHAR_NAME_INVALID, {}]
	var tpl = templates.get("%d_%d_%d" % [race, cls, gender])
	if tpl == null:
		return [Proto.Code.CLASS_CLOSED, {}]
	var appearance = _appearance(look)
	if appearance.is_empty():
		return [Proto.Code.BAD_REQUEST, {}]
	var used = db.query("SELECT slot FROM characters WHERE account_id = ? AND deleted = 0", [account_id])
	var taken = db.query("SELECT id FROM characters WHERE name = ?", [char_name])
	if used == null or taken == null:
		return [Proto.Code.SERVER_ERROR, {}]
	if not taken.is_empty():
		return [Proto.Code.CHAR_NAME_TAKEN, {}]
	var slots = used.map(func(r): return r["slot"])
	var slot = -1
	for i in MAX_CHARS:
		if not i in slots:
			slot = i
			break
	if slot < 0:
		return [Proto.Code.CHAR_LIMIT, {}]
	if not db.begin():
		return [Proto.Code.SERVER_ERROR, {}]
	var pos: Array = tpl["pos"]
	var ok = db.run("INSERT INTO characters (account_id, slot, name, race, class, gender, appearance, level, hp, mp, money, "
		+ "world, map, pos_x, pos_y, pos_z, dir, created) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)",
		[account_id, slot, char_name, race, cls, gender, JSON.stringify(appearance), tpl["level"], tpl["hp"], tpl["mp"],
		tpl["money"], tpl["world"], tpl["map"], pos[0], pos[1], pos[2], _now()])
	var char_id = db.last_id()
	for it in tpl.get("items", []):
		ok = ok and db.run("INSERT INTO inventory (character_id, location, pos, item_id, count) VALUES (?, 0, ?, ?, ?)",
			[char_id, it["pos"], it["id"], it["count"]])
	for it in tpl.get("equipment", []):
		ok = ok and db.run("INSERT INTO inventory (character_id, location, pos, item_id, count) VALUES (?, 1, ?, ?, 1)",
			[char_id, it["pos"], it["id"]])
	if not ok or not db.commit():
		db.rollback()
		return [Proto.Code.SERVER_ERROR, {}]
	var row = db.query("SELECT %s FROM characters WHERE id = ?" % LIST_COLUMNS, [char_id])
	return [Proto.Code.OK, {"char": _public(row[0])}]

func delete(account_id: int, args: Dictionary) -> Array:
	var char_id = args.get("id")
	if not char_id is int:
		return [Proto.Code.BAD_REQUEST, {}]
	if not db.run("DELETE FROM characters WHERE id = ? AND account_id = ?", [char_id, account_id]):
		return [Proto.Code.SERVER_ERROR, {}]
	if db.changes() == 0:
		return [Proto.Code.CHAR_NOT_FOUND, {}]
	return [Proto.Code.OK, {}]

# Figur zum Betreten der Welt auswählen -> Map, Welt, Position, Richtung (Welt laden: Schritt 6)
func enter(account_id: int, args: Dictionary) -> Array:
	var char_id = args.get("id")
	if not char_id is int:
		return [Proto.Code.BAD_REQUEST, {}]
	var rows = db.query("SELECT %s, world, pos_x, pos_y, pos_z, dir, hp, mp, exp, money FROM characters "
		% LIST_COLUMNS + "WHERE id = ? AND account_id = ? AND deleted = 0", [char_id, account_id])
	if rows == null:
		return [Proto.Code.SERVER_ERROR, {}]
	if rows.is_empty():
		return [Proto.Code.CHAR_NOT_FOUND, {}]
	var r = rows[0]
	db.run("UPDATE characters SET last_played = ? WHERE id = ?", [_now(), char_id])
	return [Proto.Code.OK, {"char": _public(r), "world": r["world"], "map": r["map"],
		"pos": [r["pos_x"], r["pos_y"], r["pos_z"]], "dir": r["dir"], "hp": r["hp"], "mp": r["mp"],
		"exp": r["exp"], "money": r["money"]}]


# ====================================================
# HILFEN
# ====================================================
func _public(r: Dictionary) -> Dictionary:
	var look = JSON.parse_string(str(r["appearance"]))
	return {"id": r["id"], "slot": r["slot"], "name": r["name"], "race": r["race"], "class": r["class"],
		"gender": r["gender"], "level": r["level"], "appearance": look if look is Dictionary else {},
		"map": r["map"], "last_played": r["last_played"] if r["last_played"] != null else 0}

# Aussehen prüfen und auf bekannte Schlüssel beschränken ({} = ungültig)
static func _appearance(look: Dictionary) -> Dictionary:
	var out = {}
	for key in APPEARANCE_LIMITS:
		var v = look.get(key, 0)
		if not v is int or v < 0 or v >= APPEARANCE_LIMITS[key]:
			return {}
		out[key] = v
	var color = look.get("hair_color", 0xEAF8FD)
	if not color is int or color < 0 or color > 0xFFFFFF:
		return {}
	out["hair_color"] = color
	return out

static func _now() -> int:
	return int(Time.get_unix_time_from_system())
