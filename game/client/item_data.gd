extends RefCounted

# ====================================================
# Gegenstände im Client (Schritt 10b), je Vorlage einmal gelesen aus der elements.data der Sprache
# (npc_data.gd elements):
#   info(id)    {id, name, type, quality, icon, mask, lv, race, prof, gender, hp, mp, dmg [min, max],
#               def, hit, range, pile, price, equip}
#   icon(id)    Symbol: file_icon -> path.data nennt eine Datei (z.B. surfaces\武器图标\x.dds), die es
#               einzeln nicht gibt - sie steht in den Symbol-Atlanten surfaces\iconset\iconlist_ivtr0 - 2
#               (.dds + .txt wie CECGameUIMan: Breite, Höhe, Zeilen, Spalten, dann die Dateinamen; Symbol i
#               in Spalte i % Spalten, Zeile i / Spalten); erst im Sprachordner, dann in resources\
#   model(id, Rasse, Klasse, Geschlecht[, links])  Modell der Ausrüstung an der Figur (models[]: Eintrag
#               zu Rasse und Klasse, file_model_male / _female -> .ski = Kleidung, .ecm = Waffe; links:
#               file_model_male_l / _female_l, die Waffe der linken Hand, z.B. der zweite Dolch), "" wenn keins
#   tooltip(id, Anzahl, Spieler, Texte)  BBCode: Name in der Qualitätsfarbe, Platz, Werte, Bedingungen
#               (nicht erfüllte rot), Stapel, Verkaufspreis. Die Beschreibung des Originals entsteht
#               per Lua (itemdesc.lua mit vielen Parametern) - das kommt später.
# Qualitätsfarben wie STRING_TABLE.ITEMQUALITY_COL_0 - 9 (script\global_string.lua,
# CLuaResource::GetItemQualityColor).
# ====================================================

const QUALITY_COLORS = ["a1a3a4", "ffffff", "00ff00", "006eff", "9800cd", "f7cc00", "ff0000", "ff0000", "1eb0ff", "b468ff"]
const RED = "ff4040"
const GREY = "c8c8c8"
const ICON_SETS = ["iconlist_ivtr0", "iconlist_ivtr1", "iconlist_ivtr2"]

var elements = null # angelica_elements.gd
var files = null # angelica_files.gd (Symbol-Atlanten)
var language = "Deu"
var _cache = {}
var _icons = {}
var _atlas_index = {} # Dateiname klein -> [Atlas, Symbol]
var _atlases: Array = [] # [{tex, w, h, cols}]
var _atlas_loaded = false


func info(id: int) -> Dictionary:
	if _cache.has(id):
		return _cache[id]
	var r: Dictionary = elements.get_record(id) if elements != null else {}
	var t = str(r.get("_type", ""))
	var out = {"id": id, "name": _clean(r.get("name", str(id))), "type": t, "quality": int(r.get("item_quality", 1)),
		"icon": elements.path_of(int(r.get("file_icon", 0))) if r.has("file_icon") and elements != null else "",
		"pile": maxi(1, int(r.get("pile_num_max", 1))), "price": int(r.get("shop_price", r.get("price", 0))),
		"equip": t == "EQUIPMENT_ESSENCE", "models": r.get("models", [])}
	if out["equip"]:
		out["mask"] = int(r.get("equip_mask", 0))
		out["lv"] = int(r.get("require_level", 0))
		out["race"] = int(r.get("mask_race", 0))
		out["prof"] = int(r.get("character_combo_id", 0))
		out["gender"] = int(r.get("require_gender", 2))
		out["hp"] = int(r.get("hp", 0))
		out["mp"] = int(r.get("mp", 0))
		out["dmg"] = [int(r.get("min_dmg", 0)), int(r.get("min_dmg", 0)) + int(r.get("dmg_val", 0))]
		out["def"] = int(r.get("defence", 0))
		out["hit"] = int(r.get("attack", 0))
		out["range"] = float(r.get("attack_range", 0.0))
		out["action_type"] = int(r.get("action_type", 0))
	_cache[id] = out
	return out

func icon(id: int) -> Texture2D:
	if _icons.has(id):
		return _icons[id]
	_load_atlases()
	var key = info(id)["icon"].replace("\\", "/").get_file().to_lower()
	var at: Array = _atlas_index.get(key, [])
	var tex: AtlasTexture = null
	if not at.is_empty():
		var a: Dictionary = _atlases[at[0]]
		tex = AtlasTexture.new()
		tex.atlas = a["tex"]
		tex.region = Rect2((at[1] % a["cols"]) * a["w"], (at[1] / a["cols"]) * a["h"], a["w"], a["h"])
	_icons[id] = tex
	return tex

func _load_atlases() -> void:
	if _atlas_loaded or files == null:
		return
	_atlas_loaded = true
	for n in ICON_SETS:
		var txt = ""
		for base in [language + "/surfaces/iconset", "resources/" + language + "/surfaces/iconset", "resources/surfaces/iconset"]:
			txt = files.resolve("%s/%s.txt" % [base, n])
			if txt != "":
				break
		if txt == "":
			continue
		var lines: PackedStringArray = files.read_lines(txt)
		var img = files.load_image(txt.get_basename() + ".dds") if lines.size() > 4 else null
		if img == null:
			continue
		var ai = _atlases.size()
		_atlases.append({"tex": ImageTexture.create_from_image(img), "w": lines[0].to_int(), "h": lines[1].to_int(),
			"cols": maxi(1, lines[3].to_int())})
		for i in range(4, lines.size()):
			var key = lines[i].strip_edges().to_lower()
			if key != "" and not _atlas_index.has(key):
				_atlas_index[key] = [ai, i - 4]

# Erster Platz (EQUIP_INDEX_*) einer Ausrüstung, -1 wenn keine
func slot_of(id: int) -> int:
	var mask = int(info(id).get("mask", 0))
	for i in 32:
		if mask & (1 << i):
			return i
	return -1

func model(id: int, race: int, prof: int, gender: int, left: bool = false) -> String:
	if elements == null:
		return ""
	var any = ""
	var field = ("file_model_female" if gender == 1 else "file_model_male") + ("_l" if left else "")
	for m in info(id)["models"]:
		var f = int(m.get(field, 0))
		if f == 0:
			continue
		if int(m.get("race", 0)) == race and int(m.get("profession", 0)) == prof:
			return elements.path_of(f)
		if any == "" and int(m.get("race", 0)) == race:
			any = elements.path_of(f)
	return any

# Bedingungen für die Figur p ({level, race, class, gender}) -> [Stufe ok, Rasse ok, Klasse ok, Geschlecht ok]
func fits(id: int, p: Dictionary) -> Array:
	var i = info(id)
	if not i["equip"]:
		return [true, true, true, true]
	var race = int(i["race"])
	var prof = int(i["prof"])
	return [int(i["lv"]) <= int(p.get("level", 1)), race == 0 or (race & (1 << int(p.get("race", 0)))) != 0,
		prof == 0 or (prof & (1 << int(p.get("class", 0)))) != 0, int(i["gender"]) == 2 or int(i["gender"]) == int(p.get("gender", 0))]

# tx: hud.gd texts() (Platz-Namen, Beschriftungen); class_label: Callable(Klasse) -> Name
func tooltip(id: int, count: int, p: Dictionary, tx: Dictionary, class_label: Callable) -> String:
	var i = info(id)
	var q = clampi(int(i["quality"]), 0, QUALITY_COLORS.size() - 1)
	var lines = ["[color=#%s]%s[/color]" % [QUALITY_COLORS[q], _bb(i["name"])]]
	if i["equip"]:
		var slots: Array = tx["slots"]
		var s = slot_of(id)
		if s >= 0 and s < slots.size() and slots[s] != "":
			lines.append("[color=#%s]%s[/color]" % [GREY, slots[s]])
		var ok = fits(id, p)
		var d: Array = i["dmg"]
		if d[1] > 0:
			lines.append(tx["item_dmg"] % [d[0], d[1]])
		if i["def"] > 0:
			lines.append(tx["item_def"] % i["def"])
		if i["hp"] > 0:
			lines.append(tx["item_hp"] % i["hp"])
		if i["mp"] > 0:
			lines.append(tx["item_mp"] % i["mp"])
		if i["hit"] > 0:
			lines.append(tx["item_hit"] % i["hit"])
		if i["range"] > 0.0:
			lines.append(tx["item_range"] % i["range"])
		if i["lv"] > 0:
			lines.append(_req(tx["item_lv"] % i["lv"], ok[0]))
		if i["prof"] != 0:
			var names = []
			for c in range(1, 16):
				if i["prof"] & (1 << c):
					names.append(class_label.call(c))
			lines.append(_req(tx["item_prof"] % ", ".join(names), ok[2]))
		if i["gender"] != 2:
			lines.append(_req(tx["item_gender"] % tx["genders"][clampi(i["gender"], 0, 1)], ok[3]))
		if not ok[1]:
			lines.append(_req(tx["item_race"], false))
	if i["pile"] > 1:
		lines.append(tx["item_pile"] % [count, i["pile"]])
	if i["price"] > 0:
		lines.append("[color=#%s]%s[/color]" % [GREY, tx["item_price"] % i["price"]])
	return "\n".join(lines)

static func _req(s: String, ok: bool) -> String:
	return s if ok else "[color=#%s]%s[/color]" % [RED, s]

static func _bb(s: String) -> String:
	return s.replace("[", "[lb]")

static func _clean(s) -> String:
	var t = str(s)
	return load("res://addons/PWE-Manager/Data/angelica_elements.gd").strip_codes(t).strip_edges() if t.contains("^") else t.strip_edges()
