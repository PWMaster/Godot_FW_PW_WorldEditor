extends SceneTree

# ====================================================
# Erzeugt Server/npc_templates.json: Werte der Monster- und NPC-Vorlagen, die die Spawns in
# Server/data/*/npcgen.data nennen (dazu die Quell-Monster der NPCs), aus der elements.data des
# Spielservers (FW_496 server-fw/gamed/config/elements.data, Version 0x10000253; Felder wie
# exptypes.h, angelica_elements.gd). Der Godot-Server braucht so keine Spieldaten.
# Aufruf in einem Projekt mit dem Plugin unter res://addons/PWE-Manager:
#   godot --headless --path <Projekt> -s res://addons/PWE-Manager/tools/server_data/npc_templates.gd
#         -- --elements=<.../config/elements.data>
# Monster (MONSTER_ESSENCE): Name (englisch, für das Log), Stufen und ihre Wahrscheinlichkeiten,
# Größe, Modell-Maßstab, Geh- / Renntempo, Umherlaufen (patroll_mode), Respawn-Zeit,
# Kampfwerte mit Zuwachs je Stufe (für Schritt 9), Beute-Tabellen.
# NPC (NPC_ESSENCE): Name, Quell-Monster (Stufe, Größe, Tempo kommen von dort, wie der gs),
# Respawn-Zeit, Dienste (id_*_service ungleich 0).
# ====================================================

const PLUGIN = "res://addons/PWE-Manager/"
const Elements = preload("../../Data/angelica_elements.gd")
const NpcGen = preload("../../Server/npcgen.gd")
const OUT = PLUGIN + "Server/npc_templates.json"
const MONSTER_FIELDS = {
	"faction": "faction", "enemy_faction": "enemy_faction", "monster_faction": "monster_faction",
	"size": "size", "scale": "scale_model", "show_level": "show_level", "boss": "is_boss", "fly": "is_fly_state",
	"select": "can_selected", "tab": "can_select_by_tab", "sight": "sight_range", "attack_range": "attack_range",
	"aggressive": "aggressive_mode", "aggro_range": "aggro_range", "aggro_time": "aggro_time",
	"patrol": "patroll_mode", "stand_mode": "stand_mode", "walk": "walk_speed", "run": "run_speed",
	"return_home": "return_to_ori_place_after_battle", "refresh": "time_refresh_default",
	"corpse": "dead_body_exist_time", "killed_exp": "killed_exp", "strategy": "common_strategy",
	"hp": "hp", "mp": "mp", "min_dmg": "min_dmg", "max_dmg": "max_dmg", "defense": "defense", "attack": "attack",
	"armor": "armor", "crit_rate": "crit_rate", "crit_damage": "crit_damage", "anti_crit_rate": "anti_crit_rate",
	"anti_crit_damage": "anti_crit_damage", "exp": "mainprof_exp", "money": "money_average", "money_var": "money_var",
	"hp_regen": "hp_gen2", "drop_times": "drop_times", "drop": "id_drop_table",
}
const LVLUP_FIELDS = ["hp", "mp", "min_dmg", "max_dmg", "defense", "attack", "armor", "crit_rate", "crit_damage",
	"anti_crit_rate", "anti_crit_damage"]
const NPC_FIELDS = {"refresh": "refresh_time", "attack_rule": "attack_rule", "select": "can_selected",
	"collision": "collision_in_server"}


func _initialize() -> void:
	var args = {}
	for a in OS.get_cmdline_user_args():
		var eq = a.find("=")
		if a.begins_with("--") and eq > 0:
			args[a.substr(2, eq - 2)] = a.substr(eq + 1)
	var path = str(args.get("elements", ""))
	if path == "":
		print("Aufruf: ... -- --elements=<config/elements.data>")
		quit(1)
		return
	var el = Elements.new()
	var err = el.open(path)
	if err != "":
		print("FEHLER: ", err)
		quit(1)
		return
	for t in ["MONSTER_ESSENCE", "NPC_ESSENCE"]:
		var li = el.list_of(t)
		if li < 0 or not el.lists[li]["layout"] in [Elements.FULL, Elements.SHIFTED]:
			print("FEHLER: %s in Version 0x%x nicht lesbar" % [t, el.version])
			quit(1)
			return
	var ids = _spawn_ids()
	var monsters = {}
	var npcs = {}
	var missing = []
	var src_ids = {}
	for id in ids:
		var r = el.get_record(id)
		match r.get("_type", ""):
			"MONSTER_ESSENCE":
				monsters[str(id)] = _monster(r)
			"NPC_ESSENCE":
				npcs[str(id)] = _npc(r)
				src_ids[int(r["id_src_monster"])] = true
			_:
				missing.append(id)
	for id in src_ids:
		if id != 0 and not monsters.has(str(id)):
			var r = el.get_record(id)
			if r.get("_type", "") == "MONSTER_ESSENCE":
				monsters[str(id)] = _monster(r)
			else:
				missing.append(id)
	# eine Vorlage je Zeile
	var lines = ["{", "\"source\": %s," % JSON.stringify("%s 0x%x" % [path.get_file(), el.version]),
		"\"note\": \"tools/server_data/npc_templates.gd, Felder siehe dort\","]
	for part in [["monsters", monsters], ["npcs", npcs]]:
		var d: Dictionary = part[1]
		var keys = d.keys()
		keys.sort_custom(func(a, b): return int(a) < int(b))
		lines.append("\"%s\": {" % part[0])
		for i in keys.size():
			lines.append("%s: %s%s" % [JSON.stringify(keys[i]), JSON.stringify(d[keys[i]], "", false), "," if i < keys.size() - 1 else ""])
		lines.append("}," if part[0] == "monsters" else "}")
	lines.append("}")
	var f = FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("%d Vorlagen in den Spawns: %d Monster, %d NPCs, %d unbekannt %s -> %s" % [ids.size(), monsters.size(),
		npcs.size(), missing.size(), missing.slice(0, 20), OUT])
	quit(0)

# Vorlagen-IDs aller Spawn-Gebiete in Server/data/*/npcgen.data
func _spawn_ids() -> Array:
	var ids = {}
	var data_dir = PLUGIN + "Server/data"
	for folder in DirAccess.get_directories_at(data_dir):
		var p = data_dir.path_join(folder).path_join("npcgen.data")
		if not FileAccess.file_exists(p):
			continue
		var d = NpcGen.new().read(p)
		if d.has("error"):
			print("%s: %s" % [p, d["error"]])
			continue
		for a in d["areas"]:
			for g in a["gens"]:
				ids[int(g["id"])] = true
	var out = ids.keys()
	out.sort()
	return out

func _monster(r: Dictionary) -> Dictionary:
	var m = {"name": str(r["name"]), "level": r["level"], "level_p": r["level_probability"]}
	for k in MONSTER_FIELDS:
		m[k] = r[MONSTER_FIELDS[k]]
	var up = {}
	for k in LVLUP_FIELDS:
		up[k] = r["lvlup_" + k]
	up["exp"] = r["lvlup_mainprof_exp"]
	up["money"] = r["lvlup_money_average"]
	m["lvlup"] = up
	return m

func _npc(r: Dictionary) -> Dictionary:
	var n = {"name": str(r["name"]), "monster": int(r["id_src_monster"])}
	for k in NPC_FIELDS:
		n[k] = r[NPC_FIELDS[k]]
	var services = {}
	for k in r:
		if str(k).begins_with("id_") and str(k).ends_with("_service") and r[k] is int and r[k] != 0:
			services[str(k).trim_prefix("id_").trim_suffix("_service")] = r[k]
	n["services"] = services
	return n
