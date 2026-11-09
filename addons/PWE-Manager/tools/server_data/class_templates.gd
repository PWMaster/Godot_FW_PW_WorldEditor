extends SceneTree

# ====================================================
# Erzeugt Server/class_templates.json: Grundwerte der Klassen (CHARRACTER_CLASS_CONFIG), die
# EXP-Kurve (PLAYER_LEVELEXP_CONFIG exp) und die Stufen-Zuschläge (LEVELUP_MODIFY_CONFIG
# hp_mp_modify) aus der elements.data des Spielservers (FW_496 server-fw/gamed/config/elements.data,
# Version 0x10000253; Felder wie exptypes.h, angelica_elements.gd).
# Aufruf in einem Projekt mit dem Plugin unter res://addons/PWE-Manager:
#   godot --headless --path <Projekt> -s res://addons/PWE-Manager/tools/server_data/class_templates.gd
#         -- --elements=<.../config/elements.data>
# Werte wie der gs (player_template::BuildBaseProp):
#   max. HP = hp + lvlup_hp * (Stufe - require_level) + hp_mp_modify[Stufe - 1], MP ebenso
#   EXP bis zur nächsten Stufe = level_exp[Stufe]
# Mensch / Krieger Stufe 1: 1445 + 55 + 0 = 1500 HP, 475 + 25 = 500 MP (wie clsconfig).
# Kampfwerte (Charakter-Fenster, später Kampf): dmg / defense / attack (Treffer) / armor (Ausweichen) /
# crit_rate / crit_damage / anti_crit_rate / anti_crit_damage, je + lvlup_* * (Stufe - require_level).
# ====================================================

const PLUGIN = "res://addons/PWE-Manager/"
const Elements = preload("../../Data/angelica_elements.gd")
const OUT = PLUGIN + "Server/class_templates.json"
const CLASS_FIELDS = {
	"require_level": "require_level", "hp": "hp", "mp": "mp", "lvlup_hp": "lvlup_hp", "lvlup_mp": "lvlup_mp",
	"walk": "walk_speed", "run": "run_speed", "attack_range": "attack_range", "attack_skill": "attack_skill_id",
	"faction": "faction", "enemy_faction": "enemy_faction", "xp_gen": "xp_gen",
	"dmg": "dmg", "defense": "defense", "attack": "attack", "armor": "armor", "crit_rate": "crit_rate",
	"crit_damage": "crit_damage", "anti_crit_rate": "anti_crit_rate", "anti_crit_damage": "anti_crit_damage",
	"lvlup_dmg": "lvlup_dmg", "lvlup_defense": "lvlup_defense", "lvlup_attack": "lvlup_attack", "lvlup_armor": "lvlup_armor",
	"lvlup_crit_rate": "lvlup_crit_rate", "lvlup_crit_damage": "lvlup_crit_damage", "lvlup_anti_crit_rate": "lvlup_anti_crit_rate",
	"lvlup_anti_crit_damage": "lvlup_anti_crit_damage",
}


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
	var classes = {}
	var level_exp = []
	var modify = []
	for t in ["CHARRACTER_CLASS_CONFIG", "PLAYER_LEVELEXP_CONFIG", "LEVELUP_MODIFY_CONFIG"]:
		var li = el.list_of(t)
		if li < 0 or not el.lists[li]["layout"] in [Elements.FULL, Elements.SHIFTED]:
			print("FEHLER: %s in Version 0x%x nicht lesbar" % [t, el.version])
			quit(1)
			return
		for i in el.lists[li]["count"]:
			var r = el.record(li, i)
			match t:
				"CHARRACTER_CLASS_CONFIG":
					var cls = int(r["character_class_id"])
					# ein Eintrag je Klasse (der gs nimmt den letzten; "00-..." ist ein Durchschnitt für die Bewertung)
					if str(r["name"]).begins_with("00-"):
						continue
					var c = {"name": str(r["name"]), "id": int(r["id"])}
					for k in CLASS_FIELDS:
						c[k] = r[CLASS_FIELDS[k]]
					c["hp_gen"] = [r["hp_gen1"], r["hp_gen2"], r["hp_gen3"], r["hp_gen4"]]
					c["mp_gen"] = [r["mp_gen1"], r["mp_gen2"], r["mp_gen3"], r["mp_gen4"]]
					classes[str(cls)] = c
				"PLAYER_LEVELEXP_CONFIG":
					if level_exp.is_empty():
						for v in r["exp"]:
							level_exp.append(int(v))
				"LEVELUP_MODIFY_CONFIG":
					if modify.is_empty():
						modify = r["hp_mp_modify"].duplicate()
	var keys = classes.keys()
	keys.sort_custom(func(a, b): return int(a) < int(b))
	var lines = ["{", "\"source\": %s," % JSON.stringify("%s 0x%x" % [path.get_file(), el.version]),
		"\"note\": \"tools/server_data/class_templates.gd, Formeln siehe dort\",", "\"classes\": {"]
	for i in keys.size():
		lines.append("%s: %s%s" % [JSON.stringify(keys[i]), JSON.stringify(classes[keys[i]], "", false), "," if i < keys.size() - 1 else ""])
	lines.append("},")
	lines.append("\"level_exp\": %s," % JSON.stringify(level_exp))
	lines.append("\"hp_mp_modify\": %s" % JSON.stringify(modify))
	lines.append("}")
	var f = FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("%d Klassen %s, EXP-Kurve %d Stufen -> %s" % [classes.size(), keys, level_exp.size(), OUT])
	quit(0)
