extends RefCounted

# ====================================================
# Formeln der Fertigkeiten (Server/skill_templates.json, Sprache des Fertigkeiten-Editors wie wskill
# expr / CodeGen): C-Ausdrücke mit Zuweisungen, getrennt durch ";".
#   Zahlen, Variablen (level, t0..t15, range, damage ... , player.<Wert>, victim.<Wert>),
#   Felder player.skilllevel[ID], player.bufflevel[ID], player.buffnum[ID], player.rune[a,b],
#   Funktionen INT / Int / int (abschneiden), norm, zabs, zrand,
#   Operatoren ?: || && == != < > <= >= + - * / % ! und Vorzeichen, Zuweisung "name = Ausdruck".
# Typen wie in C (skill.og): ganzzahlige Variablen und Zahlen ohne Punkt rechnen ganzzahlig (7 / 2 = 3,
# % wie C), sobald ein Wert gebrochen ist, gebrochen; ?: mit gemischten Zweigen gibt eine gebrochene Zahl.
#   var code = Expr.compile("ratio=1+0.1*t6;damage=INT(...)") -> Array (oder Expr.error gesetzt)
#   Expr.run(code, ctx) -> letzter Wert; Zuweisungen schreiben in ctx (z.B. ctx["damage"])
#   Expr.value("1000*level", ctx) -> übersetzt (zwischengespeichert) und rechnet; leer / Fehler -> default
# ctx: Dictionary Name -> Zahl ("level", "t3", "player.maxmp"), Felder als Dictionary ("player.skilllevel"
# -> {ID: Stufe}, "player.rune" -> {"1,0": Wert}); fehlende Namen sind 0.
# ====================================================

enum { NUM, VAR, IDX, NEG, NOT, BIN, TERN, CALL, SET, SEQ }
enum { T_INT, T_FLOAT }

# Gebrochene Variablen laut skill.og (alles andere ganzzahlig)
const FLOATS = ["ratio", "damage", "crit", "critdamage", "toukonratio", "charging", "range",
	"player.probability", "player.ratio", "player.amount", "player.value", "player.critrate", "player.critdmg",
	"player.runspeed", "player.mountspeed", "player.distance", "player.healcritrate", "player.flyspeed",
	"victim.probability", "victim.ratio", "victim.amount", "victim.value", "victim.critrate", "victim.critdmg",
	"victim.runspeed", "victim.mountspeed", "victim.distance", "victim.healcritrate", "victim.flyspeed"]
const FUNCS = ["INT", "Int", "int", "norm", "zabs", "zrand"]

static var error = ""
static var _cache = {}

# ----------------------------------------------------
# Übersetzen
# ----------------------------------------------------
static func compile(src: String):
	error = ""
	var toks = _tokens(src)
	if toks == null:
		return null
	var p = {"t": toks, "i": 0}
	var stmts = []
	while p["i"] < toks.size():
		if _take(p, ";"):
			continue
		var n = _statement(p)
		if n == null:
			return null
		stmts.append(n)
		if p["i"] < toks.size() and not _take(p, ";"):
			return _fail("';' erwartet bei '%s'" % str(_peek(p)))
	if stmts.size() == 1:
		return stmts[0]
	return [SEQ, stmts[-1][1] if not stmts.is_empty() else T_INT, stmts]

static func value(src: String, ctx: Dictionary, default = 0):
	if src.strip_edges() == "":
		return default
	var code = _cache.get(src)
	if code == null:
		code = compile(src)
		if code == null:
			push_warning("Formel '%s': %s" % [src, error])
			code = []
		_cache[src] = code
	if code.is_empty():
		return default
	return run(code, ctx)

static func _fail(msg: String):
	if error == "":
		error = msg
	return null

static func _tokens(src: String):
	var out = []
	var i = 0
	var n = src.length()
	while i < n:
		var c = src[i]
		if c == " " or c == "\t" or c == "\r" or c == "\n":
			i += 1
		elif (c >= "0" and c <= "9") or (c == "." and i + 1 < n and src[i + 1] >= "0" and src[i + 1] <= "9"):
			var j = i
			while j < n and ((src[j] >= "0" and src[j] <= "9") or src[j] == "."):
				j += 1
			var s = src.substr(i, j - i)
			out.append([NUM, s.to_float() if s.contains(".") else s.to_int(), T_FLOAT if s.contains(".") else T_INT])
			i = j
		elif c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z"):
			var j = i
			while j < n and (src[j] == "_" or src[j] == "." or (src[j] >= "a" and src[j] <= "z") or (src[j] >= "A" and src[j] <= "Z") or (src[j] >= "0" and src[j] <= "9")):
				j += 1
			out.append([VAR, src.substr(i, j - i)])
			i = j
		else:
			var two = src.substr(i, 2)
			if two in ["==", "!=", "<=", ">=", "&&", "||"]:
				out.append(two)
				i += 2
			elif c in "+-*/%?:<>=!(),;[]":
				out.append(c)
				i += 1
			else:
				return _fail("Zeichen '%s'" % c)
	return out

static func _peek(p: Dictionary):
	return p["t"][p["i"]] if p["i"] < p["t"].size() else null

static func _take(p: Dictionary, what: String) -> bool:
	if _peek(p) is String and _peek(p) == what:
		p["i"] += 1
		return true
	return false

# Zuweisung "name = Ausdruck" (nicht "==")
static func _statement(p: Dictionary):
	var t = _peek(p)
	if t is Array and t[0] == VAR and p["i"] + 1 < p["t"].size() and p["t"][p["i"] + 1] is String and p["t"][p["i"] + 1] == "=":
		p["i"] += 2
		var e = _ternary(p)
		if e == null:
			return null
		var ty = T_FLOAT if t[1] in FLOATS else T_INT
		return [SET, ty, t[1], e]
	return _ternary(p)

static func _ternary(p: Dictionary):
	var c = _binary(p, 0)
	if c == null:
		return null
	if not _take(p, "?"):
		return c
	var a = _ternary(p)
	if a == null or not _take(p, ":"):
		return _fail("':' erwartet")
	var b = _ternary(p)
	if b == null:
		return null
	return [TERN, T_FLOAT if a[1] == T_FLOAT or b[1] == T_FLOAT else T_INT, c, a, b]

const LEVELS = [["||"], ["&&"], ["==", "!="], ["<", ">", "<=", ">="], ["+", "-"], ["*", "/", "%"]]

static func _binary(p: Dictionary, lv: int):
	if lv >= LEVELS.size():
		return _unary(p)
	var a = _binary(p, lv + 1)
	while a != null:
		var t = _peek(p)
		if not (t is String and t in LEVELS[lv]):
			break
		p["i"] += 1
		var b = _binary(p, lv + 1)
		if b == null:
			return null
		var ty = T_INT if lv <= 3 else (T_FLOAT if a[1] == T_FLOAT or b[1] == T_FLOAT else T_INT)
		a = [BIN, ty, t, a, b]
	return a

static func _unary(p: Dictionary):
	if _take(p, "-"):
		var a = _unary(p)
		return null if a == null else [NEG, a[1], a]
	if _take(p, "+"):
		return _unary(p)
	if _take(p, "!"):
		var a = _unary(p)
		return null if a == null else [NOT, T_INT, a]
	return _primary(p)

static func _primary(p: Dictionary):
	var t = _peek(p)
	if t == null:
		return _fail("Отсутствует выражение")
	if _take(p, "("):
		var e = _ternary(p)
		if e == null or not _take(p, ")"):
			return _fail("')' erwartet")
		return e
	if t is Array and t[0] == NUM:
		p["i"] += 1
		return [NUM, t[2], t[1]]
	if t is Array and t[0] == VAR:
		p["i"] += 1
		var name: String = t[1]
		if _take(p, "("):
			if not name in FUNCS:
				return _fail("Funktion '%s'" % name)
			var arg = _ternary(p)
			if arg == null or not _take(p, ")"):
				return _fail("')' erwartet")
			return [CALL, T_FLOAT if name == "zabs" and arg[1] == T_FLOAT else T_INT, name, arg]
		if _take(p, "["):
			var args = []
			while true:
				var e = _ternary(p)
				if e == null:
					return null
				args.append(e)
				if _take(p, ","):
					continue
				if not _take(p, "]"):
					return _fail("']' erwartet")
				break
			return [IDX, T_INT, name, args]
		return [VAR, T_FLOAT if name in FLOATS else T_INT, name]
	return _fail("unerwartet '%s'" % str(t))

# ----------------------------------------------------
# Rechnen
# ----------------------------------------------------
static func run(n: Array, ctx: Dictionary):
	match n[0]:
		NUM:
			return n[2]
		VAR:
			var v = ctx.get(n[2], 0)
			return float(v) if n[1] == T_FLOAT else _int(v)
		IDX:
			var key
			if n[3].size() == 1:
				key = _int(run(n[3][0], ctx))
			else:
				key = "%d,%d" % [_int(run(n[3][0], ctx)), _int(run(n[3][1], ctx))]
			var arr = ctx.get(n[2], {})
			return _int(arr.get(key, 0)) if arr is Dictionary else 0
		NEG:
			return -run(n[2], ctx)
		NOT:
			return 0 if _truth(run(n[2], ctx)) else 1
		TERN:
			var v = run(n[3], ctx) if _truth(run(n[2], ctx)) else run(n[4], ctx)
			return float(v) if n[1] == T_FLOAT else v
		BIN:
			return _bin(n, ctx)
		CALL:
			var a = run(n[3], ctx)
			match n[2]:
				"zabs":
					return absf(a) if n[1] == T_FLOAT else absi(_int(a))
				"norm":
					return 1 if (float(a) + 0.00001 >= 1.0 if a is float else int(a) >= 1) else 0
				"zrand":
					return randi() % _int(a) if _int(a) > 0 else 0
			return _int(a)
		SET:
			var v = run(n[3], ctx)
			v = float(v) if n[1] == T_FLOAT else _int(v)
			ctx[n[2]] = v
			return v
		SEQ:
			var v = 0
			for s in n[2]:
				v = run(s, ctx)
			return v
	return 0

static func _bin(n: Array, ctx: Dictionary):
	var op: String = n[2]
	if op == "&&":
		return 1 if _truth(run(n[3], ctx)) and _truth(run(n[4], ctx)) else 0
	if op == "||":
		return 1 if _truth(run(n[3], ctx)) or _truth(run(n[4], ctx)) else 0
	var a = run(n[3], ctx)
	var b = run(n[4], ctx)
	if n[1] == T_FLOAT:
		a = float(a)
		b = float(b)
	match op:
		"+": return a + b
		"-": return a - b
		"*": return a * b
		"/":
			if a is int and b is int:
				return a / b if b != 0 else 0
			return a / b if b != 0.0 else 0.0
		"%":
			var ia = _int(a)
			var ib = _int(b)
			return ia % ib if ib != 0 else 0
		"==": return 1 if a == b else 0
		"!=": return 1 if a != b else 0
		"<": return 1 if a < b else 0
		">": return 1 if a > b else 0
		"<=": return 1 if a <= b else 0
		">=": return 1 if a >= b else 0
	return 0

static func _int(v) -> int:
	if v is int:
		return v
	if v is float:
		return int(v) # abschneiden wie (int) in C
	if v is bool:
		return 1 if v else 0
	return 0

static func _truth(v) -> bool:
	return (v != 0.0) if v is float else (_int(v) != 0)
