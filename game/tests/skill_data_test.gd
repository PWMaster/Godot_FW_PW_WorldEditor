extends SceneTree

# ====================================================
# Test der Fertigkeiten-Daten (Fertigkeiten-Fahrplan F1), ohne Server:
#   godot --headless --path <Projekt> -s res://game/tests/skill_data_test.gd
# Prüft: jede Formel in Server/skill_templates.json lässt sich übersetzen (server/skill_expr.gd), Rechen-
# regeln wie C (ganzzahlige Division, %, ?:, Zuweisungen), jeder Effekt der Fertigkeiten steht in
# Server/state_templates.json; die Startfertigkeiten aller Startvorlagen (Server/start_roles.json) gibt es,
# und ihre Werte auf Stufe 1 (Mana, Zauberzeit = Summe der Prozeduren, Abklingzeit, Reichweite ohne die von
# der Waffe abhängige; Talente t0..t15 gerechnet) stimmen mit der Beschreibung des Clients überein (Lua SkillDesc, Plugin Data/angelica_skills.gd, deutsche Texte). Der Dump ist älter als
# der Client: bekannte Abweichungen stehen in KNOWN und werden nur gemeldet.
# Ende: "FERTIGKEITEN-TEST OK" (Exit 0) oder "FERTIGKEITEN-TEST FEHLER" (Exit 1).
# ====================================================

const Expr = preload("../server/skill_expr.gd")
const SkillCast = preload("../server/skill_cast.gd")
const PLUGIN = "res://addons/PWE-Manager/"
const DATA_ROOT = "res://Stock-PWE-Client"
# "ID Wert" -> Grund (Abweichung Dump 2013 / Client v297; der Server folgt dem Dump)
const KNOWN = {"134 mp": "Spieltext: keine Kosten", "274 mp": "Spieltext: keine Kosten", "1581 mp": "Spieltext: keine Kosten",
	"166 time": "Spieltext 1 s, Prozeduren 1,35 s", "364 time": "Spieltext 1 s, Prozeduren 1,35 s",
	"4252 time": "Spieltext 1 s, Prozeduren 1,35 s"}

var checks = 0
var failures = 0


func _initialize() -> void:
	_run()

func _run() -> void:
	var sk = _json(PLUGIN + "Server/skill_templates.json")
	var st = _json(PLUGIN + "Server/state_templates.json")
	var roles = _json(PLUGIN + "Server/start_roles.json")
	if sk.is_empty() or st.is_empty() or roles.is_empty():
		_check("Daten da (skill_templates / state_templates / start_roles)", false)
		_end()
		return
	_rules()
	var skills = {}
	for s in sk["skills"]:
		skills[int(s["id"])] = s
	var states = {}
	for s in st["states"]:
		states[int(s["id"])] = s
	# alle Formeln
	var n = 0
	var bad = []
	var missing = []
	for s in sk["skills"]:
		for src in _formulas(s):
			n += 1
			if Expr.compile(src) == null:
				bad.append("%d: %s (%s)" % [s["id"], src, Expr.error])
		for e in s["states"]:
			if not states.has(int(e["id"])):
				missing.append("%d -> %d" % [s["id"], e["id"]])
	_check("%d Formeln von %d Fertigkeiten übersetzt%s" % [n, skills.size(), (" - FEHLER: " + "; ".join(bad.slice(0, 5))) if not bad.is_empty() else ""],
		n > 10000 and bad.is_empty())
	_check("%d Effekte, jeder Effekt der Fertigkeiten vorhanden%s" % [states.size(), (" - FEHLT: " + ", ".join(missing.slice(0, 10))) if not missing.is_empty() else ""],
		states.size() > 3000 and missing.is_empty())
	# Startfertigkeiten
	var start = {}
	for r in roles["roles"]:
		for e in _start_skills(str(r.get("skills_raw", ""))):
			start[e] = "%s %s" % [r.get("race_name", ""), r.get("class_name", "")]
	start[120] = "alle"
	var absent = start.keys().filter(func(id): return not skills.has(id))
	_check("%d Startfertigkeiten (mit Stadtportal) in den Daten%s" % [start.size(), (" - FEHLT: " + str(absent)) if not absent.is_empty() else ""],
		start.size() >= 20 and absent.is_empty())
	var hieb = skills.get(122, {})
	var ctx = {"level": 1, "range": 4.0}
	Expr.value(str(hieb.get("procs", [{}, {"calc": ""}])[1]["calc"]), ctx)
	_check("Hieb Stufe 1: ratio %s, damage %s (Spieltext: 100 %% Angriff plus 242)" % [ctx.get("ratio"), ctx.get("damage")],
		is_equal_approx(float(ctx.get("ratio", 0)), 1.0) and int(ctx.get("damage", 0)) == 242)
	# Abgleich mit der Beschreibung des Clients
	var desc = load(PLUGIN + "Data/angelica_skills.gd").new(load(PLUGIN + "Data/angelica_files.gd").new(DATA_ROOT), "Deu")
	var err = desc.open()
	_check("Lua-Beschreibungen geladen %s" % err, err == "")
	if err != "":
		_end()
		return
	var ids = start.keys()
	ids.sort()
	var wrong = []
	var known = []
	var compared = 0
	for id in ids:
		var s: Dictionary = skills[id]
		var text = desc.desc(id, 1, 0)
		var lua = _parse(text)
		var c = {"level": 1, "range": 4.0}
		for i in 16:
			if s["talents"].has("t%d" % i):
				c["t%d" % i] = int(Expr.value(str(s["talents"]["t%d" % i]), c))
		var mine = {"mp": int(Expr.value(str(s["mp"]), c)), "time": SkillCast.total_time(s, c) / 1000.0,
			"cool": int(Expr.value(str(s["cool"]), c)) / 1000.0, "range": float(Expr.value(str(s["pray_max"]), c))}
		var line = []
		for k in ["mp", "time", "cool", "range"]:
			if not lua.has(k) or (k == "range" and str(s["pray_max"]).contains("range")): # Weite der Waffe
				continue
			compared += 1
			var ok = absf(float(mine[k]) - float(lua[k])) <= {"mp": 0.0, "time": 0.2, "cool": 0.5, "range": 0.5}[k]
			line.append("%s %s/%s%s" % [k, str(mine[k]), str(lua[k]), "" if ok else " !"])
			if not ok:
				var key = "%d %s" % [id, k]
				(known if KNOWN.has(key) else wrong).append("%d %s %s: Daten %s, Spiel %s" % [id, desc.skill_name(id), k, str(mine[k]), str(lua[k])])
		print("FERTIGKEITEN-TEST:          %5d %-16s %-14s %s" % [id, desc.skill_name(id), start[id], ", ".join(line)])
	desc.close()
	if not known.is_empty():
		print("FERTIGKEITEN-TEST: bekannte Abweichungen: ", "; ".join(known))
	_check("%d Werte der Startfertigkeiten wie im Spieltext%s" % [compared, (" - ABWEICHUNG: " + "; ".join(wrong)) if not wrong.is_empty() else ""],
		compared >= 50 and wrong.is_empty())
	_check("Aktion aus der Formel (Rasse 0 / 2): %s / %s" % [SkillCast.action_name(str(hieb["actions"]["0"]), 0),
		SkillCast.action_name(str(hieb["actions"]["0"]), 2)], SkillCast.action_name(str(hieb["actions"]["0"]), 0) == "战士_斩击"
		and SkillCast.action_name(str(hieb["actions"]["0"]), 2) == "魔族_战士_斩击")
	_end()

# Rechenregeln wie C
func _rules() -> void:
	var c = {"t1": 13, "player.skilllevel": {830: 2}, "player.rune": {"1,0": 5}}
	var r = [Expr.value("7/2", {}), Expr.value("7/2.0", {}), Expr.value("-7%3", {}), Expr.value("1>0?3:0.5", {}),
		Expr.value("t1%10", c), Expr.value("player.skilllevel[830]*10", c), Expr.value("player.rune[1,0]>4?1:2", c),
		Expr.value("INT(2.9)+int(-2.9)", {}), Expr.value("unbekannt+1", {})]
	var ctx = {}
	Expr.value("ratio=1+0.5;damagetype=3;player.perform=1;", ctx)
	_check("Rechenregeln: 7/2 = %s, 7/2.0 = %s, -7%%3 = %s, 1>0?3:0.5 = %s, t1%%10 = %s, Felder %s / %s, INT %s, unbekannt %s; Zuweisungen %s" % (r + [str(ctx)]),
		r[0] == 3 and is_equal_approx(r[1], 3.5) and r[2] == -1 and r[3] is float and is_equal_approx(r[3], 3.0) and r[4] == 3
		and r[5] == 20 and r[6] == 1 and r[7] == 0 and r[8] == 1 and is_equal_approx(float(ctx.get("ratio", 0)), 1.5)
		and ctx.get("damagetype") == 3 and ctx.get("player.perform") == 1)
	_check("Fehler werden erkannt ('1+' / '(2' / 'foo(1)')", Expr.compile("1+") == null and Expr.compile("(2") == null and Expr.compile("foo(1)") == null)

# Werte aus dem Spieltext: Mana, Zauberzeit s, Abklingzeit s, Reichweite m
func _parse(text: String) -> Dictionary:
	var out = {}
	var t = text.replace("\r", "\n")
	var m = RegEx.create_from_string("(\\d+) Mana").search(t)
	if m != null:
		out["mp"] = m.get_string(1).to_int()
	elif t.contains("Keine Kosten"):
		out["mp"] = 0
	m = RegEx.create_from_string("Zauberzeit: ([\\d.]+) Sekunde").search(t)
	if m != null:
		out["time"] = m.get_string(1).to_float()
	m = RegEx.create_from_string("Abkühlung: ([\\d.]+) (Sekunde|Minute)").search(t)
	if m != null:
		out["cool"] = m.get_string(1).to_float() * (60.0 if m.get_string(2) == "Minute" else 1.0)
	m = RegEx.create_from_string("Reichweite: (?:([\\d.]+)-)?([\\d.]+) Meter").search(t)
	if m != null:
		out["range"] = m.get_string(2).to_float()
	return out

func _formulas(s: Dictionary) -> Array:
	var out = []
	for k in ["mp", "exe_time", "cast_dist", "pray_min", "pray_max", "cool", "hate", "mp_reduce", "other_value", "action_value",
			"fight_usable", "dizzy_usable", "handfree_usable"]:
		out.append(str(s[k]))
	for k in s["range"]:
		if k != "approach":
			out.append(str(s["range"][k]))
	for p in s["procs"]:
		for k in p:
			out.append(str(p[k]))
	for k in s["talents"]:
		out.append(str(s["talents"][k]))
	for e in s["states"]:
		for d in e["data"]:
			out.append(str(d))
		out.append(str(e["time"]))
		out.append(str(e["chance"]))
	return out.filter(func(f): return f.strip_edges() != "")

static func _start_skills(raw: String) -> Array:
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
		out.append(b.decode_u32(p))
		p += 5
	return out

func _json(path: String) -> Dictionary:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	return d if d is Dictionary else {}

func _check(what: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("FERTIGKEITEN-TEST: ", "ok      " if ok else "FEHLER  ", what)

func _end() -> void:
	print("FERTIGKEITEN-TEST %s (%d Prüfungen)" % ["OK" if failures == 0 else "FEHLER", checks])
	quit(0 if failures == 0 else 1)
