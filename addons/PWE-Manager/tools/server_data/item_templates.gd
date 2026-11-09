extends SceneTree

# ====================================================
# Erzeugt Server/item_templates.json: was der Spiel-Server über Gegenstände und Sammelpunkte wissen
# muss, aus der elements.data des Clients (wie quest_templates.gd: die Quests kommen ebenfalls aus
# den Client-Daten, damit IDs und Werte zusammenpassen).
# Aufruf in einem Projekt mit dem Plugin unter res://addons/PWE-Manager:
#   godot --headless --path <Projekt> -s res://addons/PWE-Manager/tools/server_data/item_templates.gd
#         [-- --client=res://Stock-PWE-Client]
# items: jede Vorlage mit pile_num_max (Gegenstände aller Listen), Standardwerte weggelassen:
#   pile (Stapelgröße, 1 wenn weggelassen), Ausrüstung (EQUIPMENT_ESSENCE) dazu:
#   mask (equip_mask: Bit = Platz EQUIP_INDEX_*, 0 Waffe, 1 Handgelenk, 3 Körper, 5 Beine, 7 Füße ...),
#   lv (require_level), race (mask_race: Bit = Rasse), prof (character_combo_id: Bit = Klasse, 0 = alle),
#   gender (require_gender 0 männlich, 1 weiblich, 2 beide), hp, mp, dmg [min, max] (min_dmg,
#   min_dmg + dmg_val), def (defence), hit (attack = Treffer), range (attack_range)
# mines: Sammelpunkte (MINE_ESSENCE): t [min, max] s (time_min / time_max), dist (max_distance),
#   task_in (Quest nötig), task_out (Quest, an die das Sammeln geht: CheckMining gibt den gesuchten
#   Gegenstand), mat [[ID, Wahrscheinlichkeit]] (materials), perm (permenent: bleibt stehen), multi
#   (is_multiple: mehrere zugleich), desc (progress_desc), lv [min, max] (Stufe, wenn vorhanden)
# ====================================================

const PLUGIN = "res://addons/PWE-Manager/"
const Elements = preload("../../Data/angelica_elements.gd")
const Files = preload("../../Data/angelica_files.gd")
const OUT = PLUGIN + "Server/item_templates.json"
const EQUIP_FIELDS = {"mask": "equip_mask", "lv": "require_level", "race": "mask_race", "prof": "character_combo_id",
	"hp": "hp", "mp": "mp", "def": "defence", "hit": "attack"}


func _initialize() -> void:
	var args = {}
	for a in OS.get_cmdline_user_args():
		var eq = a.find("=")
		if a.begins_with("--") and eq > 0:
			args[a.substr(2, eq - 2)] = a.substr(eq + 1)
	var files = Files.new(str(args.get("client", "res://Stock-PWE-Client")))
	var path: String = Elements.locate(files, "Deu")
	var el = Elements.new()
	var err = el.open(path, files) if path != "" else "elements.data nicht gefunden"
	if err != "":
		print("FEHLER: ", err)
		quit(1)
		return
	var t0 = Time.get_ticks_msec()
	var items = {}
	var mines = {}
	var skipped = []
	for l in el.lists:
		if l["space"] != "essence":
			continue
		var fields: Array = el._fields(l["type"])
		var names = fields.map(func(f): return f[0])
		var is_mine = l["type"] == "MINE_ESSENCE"
		if not is_mine and not "pile_num_max" in names:
			continue
		if not l["layout"] in [Elements.FULL, Elements.SHIFTED]:
			skipped.append("%s (%s)" % [l["type"], l["layout"]])
			continue
		for i in l["count"]:
			var r = el.record(l["index"], i)
			var id = int(r["id"])
			if is_mine:
				mines[id] = _mine(r)
			elif not items.has(id):
				items[id] = _item(r, l["type"] == "EQUIPMENT_ESSENCE")
	var lines = ["{", "\"source\": %s," % JSON.stringify("%s 0x%x" % [path.get_file(), el.version]),
		"\"note\": \"tools/server_data/item_templates.gd, Felder siehe dort\","]
	for part in [["items", items], ["mines", mines]]:
		var d: Dictionary = part[1]
		var keys = d.keys()
		keys.sort()
		lines.append("\"%s\": {" % part[0])
		for i in keys.size():
			lines.append("%s: %s%s" % [JSON.stringify(str(keys[i])), JSON.stringify(d[keys[i]], "", false), "," if i < keys.size() - 1 else ""])
		lines.append("}," if part[0] == "items" else "}")
	lines.append("}")
	var f = FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	var equip = items.values().filter(func(x): return x.has("mask")).size()
	print("%d Gegenstände (%d Ausrüstung), %d Sammelpunkte in %.1f s -> %s" % [items.size(), equip, mines.size(),
		(Time.get_ticks_msec() - t0) / 1000.0, OUT])
	if not skipped.is_empty():
		print("nicht lesbar: ", ", ".join(skipped))
	quit(0)

func _item(r: Dictionary, equip: bool) -> Dictionary:
	var o = {}
	var pile = int(r.get("pile_num_max", 1))
	if pile > 1:
		o["pile"] = pile
	if not equip:
		return o
	for k in EQUIP_FIELDS:
		var v = int(r.get(EQUIP_FIELDS[k], 0))
		if v != 0:
			o[k] = v
	o["mask"] = int(r.get("equip_mask", 0))
	var g = int(r.get("require_gender", 2))
	if g != 2:
		o["gender"] = g
	var lo = int(r.get("min_dmg", 0))
	var span = int(r.get("dmg_val", 0))
	if lo != 0 or span != 0:
		o["dmg"] = [lo, lo + span]
	var rng = float(r.get("attack_range", 0.0))
	if rng > 0.0:
		o["range"] = snappedf(rng, 0.01)
	return o

func _mine(r: Dictionary) -> Dictionary:
	var o = {"t": [int(r.get("time_min", 0)), int(r.get("time_max", 0))], "dist": snappedf(float(r.get("max_distance", 0.0)), 0.01)}
	for k in [["task_in", "task_in"], ["task_out", "task_out"]]:
		if int(r.get(k[1], 0)) != 0:
			o[k[0]] = int(r[k[1]])
	var mat = []
	for m in r.get("materials", []):
		if int(m.get("id", 0)) != 0 and float(m.get("probability", 0.0)) > 0.0:
			mat.append([int(m["id"]), snappedf(float(m["probability"]), 0.0001)])
	if not mat.is_empty():
		o["mat"] = mat
	if int(r.get("permenent", 0)) != 0:
		o["perm"] = true
	if int(r.get("is_multiple", 0)) != 0:
		o["multi"] = true
	var lmin = int(r.get("level_min", r.get("min_level_required", 0)))
	var lmax = int(r.get("level_max", r.get("max_level_required", 0)))
	if lmin != 0 or lmax != 0:
		o["lv"] = [lmin, lmax]
	return o
