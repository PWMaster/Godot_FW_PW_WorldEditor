extends RefCounted

# ====================================================
# Werte der Figuren wie der gs (player_template::BuildBaseProp, npc_template::BuildBaseProp), aus
# dem Plugin: Server/class_templates.json (Klassen, EXP-Kurve, Stufen-Zuschläge) und den
# Monster-Vorlagen in Server/npc_templates.json.
#   Spieler  max. HP = hp + lvlup_hp * (Stufe - require_level) + hp_mp_modify[Stufe - 1], MP ebenso
#            EXP bis zur nächsten Stufe = level_exp[Stufe]
#   Monster  max. HP = hp + lvlup.hp * (Stufe - level[0]), MP ebenso (NPCs: ihr Quell-Monster)
# Ohne class_templates.json gelten die Werte der Startvorlage (hp / mp) als Maximum.
#   Kampfwerte (attributes, Charakter-Fenster): Grundwert + lvlup_* * (Stufe - require_level) der
#            Klasse, dazu die Ausrüstung (inventory.gd bonus): Angriff dmg + min_dmg .. dmg + min_dmg +
#            dmg_val, Verteidigung + defence, Treffer + attack; Krit-Werte in Prozent
# ====================================================

const PLUGIN_SERVER = "res://addons/PWE-Manager/Server/"
const Settings = preload("../common/settings.gd")

var classes = {} # Klasse (String) -> Werte
var level_exp: Array = []
var hp_mp_modify: Array = []


func _init() -> void:
	var path = Settings.server_data_path("class_templates.json")
	var d = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if d is Dictionary:
		classes = d.get("classes", {})
		level_exp = d.get("level_exp", [])
		hp_mp_modify = d.get("hp_mp_modify", [])

func loaded() -> bool:
	return not classes.is_empty()

func max_hp(cls: int, level: int, fallback: int = 1) -> int:
	return _player(cls, level, "hp", fallback)

func max_mp(cls: int, level: int, fallback: int = 1) -> int:
	return _player(cls, level, "mp", fallback)

# EXP bis zur nächsten Stufe (0 = höchste Stufe)
func exp_next(level: int) -> int:
	return int(level_exp[level]) if level >= 0 and level < level_exp.size() else 0

func _player(cls: int, level: int, key: String, fallback: int) -> int:
	var c = classes.get(str(cls))
	if c == null:
		return maxi(1, fallback)
	var modify = int(hp_mp_modify[level - 1]) if level >= 1 and level <= hp_mp_modify.size() else 0
	return maxi(1, int(float(c[key]) + float(c["lvlup_" + key]) * (level - int(c["require_level"])) + 1e-5) + modify)

# Kampfwerte: {dmg: [min, max], def, hit, eva, crit, crit_dmg, anti_crit, anti_crit_dmg}
func attributes(cls: int, level: int, bonus: Dictionary) -> Dictionary:
	var c = classes.get(str(cls), {})
	var up = level - int(c.get("require_level", 0))
	var v = func(key: String) -> float: return float(c.get(key, 0.0)) + float(c.get("lvlup_" + key, 0.0)) * up
	var dmg = v.call("dmg")
	var d: Array = bonus.get("dmg", [0, 0])
	return {"dmg": [int(dmg + d[0] + 1e-5), int(dmg + d[1] + 1e-5)], "def": int(v.call("defense") + 1e-5) + int(bonus.get("def", 0)),
		"hit": int(v.call("attack") + 1e-5) + int(bonus.get("hit", 0)), "eva": int(v.call("armor") + 1e-5),
		"crit": snappedf(v.call("crit_rate"), 0.1), "crit_dmg": snappedf(v.call("crit_damage"), 0.1),
		"anti_crit": snappedf(v.call("anti_crit_rate"), 0.1), "anti_crit_dmg": snappedf(v.call("anti_crit_damage"), 0.1)}

# Monster-Vorlage (npc_templates.json "monsters") auf Stufe level: [max. HP, max. MP]
static func monster_hp_mp(t: Dictionary, level: int) -> Array:
	if t.is_empty():
		return [1, 0]
	var levels: Array = t.get("level", [level])
	var base_level = int(levels[0]) if not levels.is_empty() else level
	var up: Dictionary = t.get("lvlup", {})
	var hp = int(float(t.get("hp", 1)) + float(up.get("hp", 0)) * (level - base_level))
	var mp = int(float(t.get("mp", 0)) + float(up.get("mp", 0)) * (level - base_level))
	return [maxi(1, hp), maxi(0, mp)]
