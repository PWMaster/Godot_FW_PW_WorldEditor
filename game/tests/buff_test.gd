extends SceneTree

# ====================================================
# Test der Statuseffekte (server/buffs.gd, Fertigkeiten-Fahrplan F3) ohne Server, mit eigener Uhr:
#   godot --headless --path <Projekt> -s res://game/tests/buff_test.gd
# Prüft mit den echten Effekt-Vorlagen (Plugin Server/state_templates.json): Brennen (583) aus dem Feuerball
# tickt fünfmal 30 Schaden im Sekundentakt und endet nach 5 s, Meldungen buffs / hit an einen Zuschauer;
# "unabhängig" (583): je Zaubernder ein Effekt; Vorzeichen (646 Abwehr -10 mit Parameter 0) und with_mods;
# Stapeln (Regel 6) bis max_stack; sofortige Heilung (120) ohne bleibenden Effekt; Höchst-Leben (871) und
# zurück beim Ablauf; verzögerter Beginn (869); Zeit < 500 ms, Erfolg 0 %, Immunität, -1 (wie zuletzt);
# Tod entfernt OVER_DEATH-Effekte; Brennen tötet und gibt den Abschuss dem Zaubernden.
# Ende: "STATUSEFFEKTE-TEST OK" (Exit 0) oder "STATUSEFFEKTE-TEST FEHLER" (Exit 1).
# ====================================================

const Buffs = preload("../server/buffs.gd")
const Proto = preload("../common/protocol.gd")

class FakeNet:
	var pushed: Array = []
	func push(peer, what, data) -> void:
		pushed.append([peer, what, data])

class FakeWorld:
	var players = {}

class FakeCombat:
	var killed: Array = [] # [Opfer, Zaubernder]
	func player_killed(p) -> void:
		killed.append([int(p["id"]), 0])
	func monster_killed(src, _map_name, o) -> void:
		killed.append([int(o["id"]), int(src)])

var checks = 0
var failures = 0
var now = 1000000
var net = FakeNet.new()
var world = FakeWorld.new()
var combat = FakeCombat.new()
var buffs


func _initialize() -> void:
	buffs = Buffs.new(world, net, func(_s): pass)
	buffs.combat = combat
	buffs.clock = func(): return now
	var err = buffs.load_templates()
	_check("Vorlagen geladen (%d Effekte) %s" % [buffs.states.size(), err], err == "" and buffs.states.size() > 3000)
	if err != "":
		_end()
		return
	world.players[7] = {"id": 7, "map": "s9", "pos": Vector3.ZERO} # Zuschauer
	var mage = {"id": 11, "name": "Magier", "map": "s9", "pos": Vector3.ZERO}
	var other = {"id": 12, "name": "Zweiter", "map": "s9", "pos": Vector3.ZERO}
	_burn(mage, other)
	_modifiers(mage)
	_stack(mage)
	_instant_and_hp(mage)
	_rules(mage)
	_kill(mage)
	_end()

func _monster(hp: int) -> Dictionary:
	return {"id": Proto.NPC_ID_BASE + randi() % 100000, "hp": hp, "max_hp": hp, "mp": 0, "max_mp": 0, "level": 1,
		"pos": Vector3(1, 0, 0), "fight": false, "target": 0}

func _advance(ms: int) -> void:
	var end = now + ms
	while now < end:
		now = mini(end, now + 100)
		buffs.tick()

func _pushes(what: String, from: int) -> Array:
	return net.pushed.slice(from).filter(func(e): return e[1] == what).map(func(e): return e[2])

# Brennen: 5 Ticks à 30, Ende nach 5 s; unabhängig je Zaubernder
func _burn(mage: Dictionary, other: Dictionary) -> void:
	var o = _monster(500)
	var n0 = net.pushed.size()
	var ok = buffs.apply(o, "s9", 583, [30.0], 5000, 100, mage)
	var lst = buffs.list_of(o)
	_check("Brennen (583) angelegt: %s (Sichtbar-Index 8 = Flammen-GFX), Meldung buffs an den Zuschauer" % str(lst), ok
		and lst.size() == 1 and lst[0][0] == 583 and lst[0][2] == 5000 and lst[0].size() == 5 and lst[0][4] == 8
		and _pushes("buffs", n0).size() == 1 and int(_pushes("buffs", n0)[0]["id"]) == int(o["id"]))
	_advance(999)
	var hp_before = int(o["hp"])
	_advance(1)
	var hits = _pushes("hit", n0)
	_check("nach 1 s ein Tick: 30 Schaden (hit mit buff 583, src Magier) - %d HP" % int(o["hp"]), hp_before == 500 and int(o["hp"]) == 470
		and hits.size() == 1 and int(hits[0]["buff"]) == 583 and int(hits[0]["dmg"]) == 30 and int(hits[0]["src"]) == 11)
	_check("getroffenes Monster greift den Zaubernden an? (kein Spieler online: target bleibt 0)", int(o["target"]) == 0)
	_advance(3999)
	var still = buffs.list_of(o).size()
	_advance(1)
	hits = _pushes("hit", n0)
	var last: Dictionary = _pushes("buffs", n0)[-1]
	_check("nach 5 s: 5 Ticks (%d HP), Effekt weg (%d vorher), letzte Meldung leer" % [int(o["hp"]), still], int(o["hp"]) == 350
		and hits.size() == 5 and still == 1 and buffs.list_of(o).is_empty() and last["list"].is_empty())
	# unabhängig (Regel 5): je Zaubernder einer
	buffs.apply(o, "s9", 583, [30.0], 5000, 100, mage)
	buffs.apply(o, "s9", 583, [20.0], 5000, 100, other)
	buffs.apply(o, "s9", 583, [30.0], 5000, 100, mage)
	_check("Regel 5 (unabhängig): zwei Zaubernde -> zwei Brände, derselbe ersetzt seinen (%d)" % buffs.list_of(o).size(),
		buffs.list_of(o).size() == 2)
	var hp0 = int(o["hp"])
	_advance(1000)
	_check("beide Brände ticken (%d -> %d)" % [hp0, int(o["hp"])], hp0 - int(o["hp"]) == 50)
	buffs.on_death(o)
	_check("Tod entfernt OVER_DEATH-Effekte", buffs.list_of(o).is_empty())

# Werte: 646 (modifyPhyDefense, Parameter 0) zieht ab
func _modifiers(mage: Dictionary) -> void:
	var o = _monster(500)
	var ok = buffs.apply(o, "s9", 646, [10.0, 0.0], 20000, 100, mage)
	var m = Buffs.mods_of(o)
	var w = Buffs.with_mods({"dmg": [100, 120], "def": 100, "hit": 50, "eva": 10, "crit": 5.0}, o)
	_check("646 Abwehr -10 (Vorzeichen über den Parameter): mods %s, with_mods def %s" % [str(m), str(w.get("def"))], ok
		and is_equal_approx(float(m.get("def", 0)), -10.0) and is_equal_approx(float(w["def"]), 90.0))

# Stapeln (Regel 6): erster Effekt mit Regel 6, max_stack >= 3 und einer Werte-Wirkung
func _stack(mage: Dictionary) -> void:
	var sid = 0
	for id in buffs.states:
		var st: Dictionary = buffs.states[id]
		if int(st["cover"]) == 6 and int(st["max_stack"]) >= 3 and int(st["time_type"]) == 1 and str(st["begin"][0]) == "1" \
				and not st["effects"].is_empty() and Buffs.MODS.has(buffs.kinds.get(int(st["effects"][0]["hs"]), {}).get("name", "")):
			sid = id
			break
	if sid == 0:
		_check("Effekt mit Regel 6 gefunden", false)
		return
	var st: Dictionary = buffs.states[sid]
	var o = _monster(500)
	o["level"] = maxi(1, int(st["min_level"]))
	for i in int(st["max_stack"]) + 1:
		buffs.apply(o, "s9", sid, [5.0, 5.0, 5.0, 5.0, 5.0], 10000, 100, mage)
	var lst = buffs.list_of(o)
	var key = Buffs.MODS[buffs.kinds[int(st["effects"][0]["hs"])]["name"]]
	var v = absf(float(Buffs.mods_of(o).get(key, 0)))
	var unit = 100.0 if key in Buffs.TO_PERCENT else (1000.0 if key in Buffs.PERMILLE else 1.0)
	_check("Regel 6 (stapeln) %d %s: %d x angelegt -> Stapel %s von %d, Wert %s" % [sid, st["name"], int(st["max_stack"]) + 1,
		str(lst[0][1]) if not lst.is_empty() else "-", int(st["max_stack"]), str(v)], lst.size() == 1 and int(lst[0][1]) == int(st["max_stack"])
		and is_equal_approx(v, 5.0 * unit * int(st["max_stack"])))

# Sofort-Heilung (120), Höchst-Leben (871), verzögerter Beginn (869)
func _instant_and_hp(mage: Dictionary) -> void:
	var p = {"id": 5, "name": "Priester", "map": "s9", "pos": Vector3.ZERO, "hp": 100, "max_hp": 1000, "mp": 0, "max_mp": 100,
		"level": 1, "class": 6, "race": 1}
	var n0 = net.pushed.size()
	var ok = buffs.apply(p, "s9", 120, [967.0], 0, 100, mage)
	var heals = _pushes("heal", n0)
	_check("120 sofortige Heilung: %d HP, heal %s, kein bleibender Effekt" % [int(p["hp"]), str(heals.map(func(h): return h["amount"]))],
		ok and int(p["hp"]) == 1000 and heals.size() == 1 and int(heals[0]["amount"]) == 900 and buffs.list_of(p).is_empty())
	ok = buffs.apply(p, "s9", 871, [100.0, 0.01], 2000, 100, mage)
	var hp_max = int(p["max_hp"])
	_advance(2000)
	_check("871 Höchst-Leben -100 und -1 %%: %d, nach Ablauf wieder %d" % [hp_max, int(p["max_hp"])], ok and hp_max == 890
		and int(p["max_hp"]) == 1000 and int(p["hp"]) == 890)
	var st: Dictionary = buffs.states.get(869, {})
	var delay = str(st.get("begin_param", ["0"])[0]).to_int()
	p["hp"] = 500
	ok = buffs.apply(p, "s9", 869, [30.0], 1000 + delay, 100, mage)
	var before = int(p["hp"])
	_advance(delay + 100)
	_check("869 verzögerter Beginn (%d ms): Heilung erst danach (%d -> %d)" % [delay, before, int(p["hp"])], ok and before == 500
		and int(p["hp"]) == 530)

# Bedingungen: zu kurz, 0 %, -1, Immunität
func _rules(mage: Dictionary) -> void:
	var o = _monster(500)
	var short = buffs.apply(o, "s9", 583, [30.0], 400, 100, mage)
	var zero = buffs.apply(o, "s9", 583, [30.0], 5000, 0, mage)
	var after_fail = buffs.apply(o, "s9", 583, [30.0], 5000, -1, mage)
	buffs.apply(o, "s9", 583, [30.0], 5000, 100, mage)
	var after_ok = buffs.apply(o, "s9", 583, [30.0], 5000, -1, mage)
	o["immune"] = int(buffs.states[646]["bag"])
	var immune = buffs.apply(o, "s9", 646, [10.0], 5000, 100, mage)
	_check("Zeit < 500 ms (%s), Erfolg 0 %% (%s), -1 nach Fehlschlag (%s) / nach Erfolg (%s), Immunität (%s)" % [short, zero, after_fail,
		after_ok, immune], not short and not zero and not after_fail and after_ok and (not immune or int(buffs.states[646]["bag"]) == 0))

# Brennen tötet: Abschuss für den Zaubernden
func _kill(mage: Dictionary) -> void:
	var o = _monster(20)
	buffs.apply(o, "s9", 583, [30.0], 5000, 100, mage)
	_advance(1000)
	_check("Brennen tötet (%d HP): Abschuss an den Magier %s" % [int(o["hp"]), str(combat.killed)], int(o["hp"]) == 0
		and combat.killed.has([int(o["id"]), 11]))

func _check(what: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("STATUSEFFEKTE-TEST: ", "ok      " if ok else "FEHLER  ", what)

func _end() -> void:
	print("STATUSEFFEKTE-TEST %s (%d Prüfungen)" % ["OK" if failures == 0 else "FEHLER", checks])
	quit(0 if failures == 0 else 1)
