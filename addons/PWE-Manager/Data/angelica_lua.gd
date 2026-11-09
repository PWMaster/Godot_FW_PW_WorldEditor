@tool
extends RefCounted

# ====================================================
# Lua-Skripte der Spieldaten lesen (<Sprache>/script/*.lua, Lua 5.1 Bytecode "\x1bLuaQ" wie luac):
# die Skripte des Clients sind fast nur Daten (Tabellen, z.B. InstanceWorld.lua mit den Karten-
# Bildern der Minimap, InstanceStr.lua mit den Map-Namen, NPCTaskInfo.lua). Statt einer Lua-
# Laufzeit führt ein kleiner Interpreter den Hauptteil des Skripts aus und liefert die globalen
# Variablen als Godot-Werte:
#   nil -> null, boolean -> bool, number -> int (ganzzahlig) bzw. float, string -> String (UTF-8,
#   sonst GBK), table -> Dictionary (Schlüssel 1, 2 ... als int; Lua-Referenzen bleiben geteilt),
#   function -> LuaClosure bzw. Callable (eingebaute)
#   run_file(Pfad) -> "" oder Fehlertext    globals / value("Instance.Str.name_9")
#   close() nach Gebrauch: entfernt die Funktionen aus allen Tabellen und Selbstbezüge
#   (M.__index = M) - sonst halten Kreise alles im Speicher; herausgeholte Daten bleiben gültig
# Chunk (lundump.c 5.1): Kopf 12 Bytes (Version 0x51, little endian, int / size_t / Befehl 4 Byte,
# Zahl 8 Byte double), dann die Hauptfunktion: Quelle, Zeilen, Upvalues / Parameter / Vararg /
# Stapel, Befehle, Konstanten (nil, bool, Zahl, String), Unterfunktionen, Debug-Daten.
# Befehle (lopcodes.h 5.1): 6 Bit Op, A 8, C 9, B 9 Bit; Bx 18, sBx = Bx - 131071; RK >= 256 =
# Konstante. Alle 38 Befehle; Funktionen des Skripts laufen mit (Upvalues als Wert beim Anlegen
# der Funktion erfasst - für Datenskripte genügt das). Eingebaut: LuaInclude (Skript aus demselben
# Ordner, einmal), pairs / ipairs / next, type, tostring / tonumber, select, unpack, setmetatable
# (ohne Wirkung), rawget / rawset, assert, print / error (nur gemerkt), table.insert / remove /
# getn / concat, math.floor / ceil / max / min / abs / huge, string.format / len / sub / upper /
# lower / rep. Unbekannte Aufrufe liefern nil (in errors gemerkt). Abbruch nach MAX_STEPS Befehlen.
# ====================================================

const HEADER = [0x1b, 0x4c, 0x75, 0x61, 0x51, 0x00, 0x01, 0x04, 0x04, 0x04, 0x08, 0x00]
const FIELDS_PER_FLUSH = 50
const MAX_STEPS = 20000000
const MAX_DEPTH = 120

class LuaProto:
	var source = ""
	var nups = 0
	var numparams = 0
	var is_vararg = 0
	var maxstack = 0
	var code = PackedInt64Array()
	var k: Array = []
	var p: Array = []

class LuaClosure:
	var proto: LuaProto
	var upvals: Array = []

var globals = {}
var errors: Array = []
var files # angelica_files.gd (Lesen über die Spieldaten / Pakete), sonst FileAccess
var _b: PackedByteArray
var _pos = 0
var _steps = 0
var _depth = 0
var _dirs: Array = [] # Ordner der laufenden Skripte (LuaInclude)
var _included = {}
var _closures: Array = [] # alle angelegten Funktionen und Tabellen (für close())
var _tables: Array = []


func _init(p_files = null) -> void:
	files = p_files
	var g = globals
	g["LuaInclude"] = _lua_include
	g["pairs"] = _pairs
	g["ipairs"] = func(a): return [_inext, _arg(a, 0), 0]
	g["next"] = _next
	g["type"] = func(a): return [_type(_arg(a, 0))]
	g["tostring"] = func(a): return [_tostring(_arg(a, 0))]
	g["tonumber"] = func(a): return [_tonumber(_arg(a, 0))]
	g["select"] = func(a): return [a.size() - 1] if _arg(a, 0) is String and _arg(a, 0) == "#" else a.slice(int(_arg(a, 0)))
	g["unpack"] = func(a): return _unpack(a)
	g["setmetatable"] = func(a): return [_arg(a, 0)]
	g["getmetatable"] = func(_a): return [null]
	g["rawget"] = func(a): return [_index(_arg(a, 0), _arg(a, 1))]
	g["rawset"] = func(a): _setindex(_arg(a, 0), _arg(a, 1), _arg(a, 2)); return [_arg(a, 0)]
	g["assert"] = func(a): return a
	g["print"] = func(_a): return []
	g["error"] = func(a): errors.append("error(%s)" % _tostring(_arg(a, 0))); return []
	g["table"] = {"insert": _table_insert, "remove": _table_remove, "getn": func(a): return [_len(_arg(a, 0))],
		"concat": _table_concat}
	g["math"] = {"floor": func(a): return [_num(floor(float(_arg(a, 0))))], "ceil": func(a): return [_num(ceil(float(_arg(a, 0))))],
		"max": func(a): return [_num(a.reduce(func(m, x): return maxf(m, float(x)), -INF))],
		"min": func(a): return [_num(a.reduce(func(m, x): return minf(m, float(x)), INF))],
		"abs": func(a): return [_num(absf(float(_arg(a, 0))))], "huge": INF}
	g["string"] = {"format": _string_format, "len": func(a): return [str(_arg(a, 0)).to_utf8_buffer().size()],
		"sub": _string_sub, "upper": func(a): return [str(_arg(a, 0)).to_upper()],
		"lower": func(a): return [str(_arg(a, 0)).to_lower()], "rep": func(a): return [str(_arg(a, 0)).repeat(int(_arg(a, 1)))]}
	g["_G"] = g

# Skript ausführen (Pfad in den Spieldaten oder echte Datei) -> "" oder Fehlertext
func run_file(path: String) -> String:
	var b = files.get_bytes(path) if files != null else FileAccess.get_file_as_bytes(path)
	if b.is_empty():
		return path.get_file() + " nicht lesbar"
	_included[path.to_lower()] = true
	return run_bytes(b, path.get_base_dir())

func run_bytes(b: PackedByteArray, dir: String = "") -> String:
	var proto = load_chunk(b)
	if proto == null:
		return errors.back() if not errors.is_empty() else "kein Lua-Bytecode"
	var cl = LuaClosure.new()
	cl.proto = proto
	_dirs.append(dir)
	var before = errors.size()
	_call(cl, [])
	_dirs.pop_back()
	return "" if errors.size() == before or not errors[before].begins_with("Abbruch") else errors[before]

func close() -> void:
	for cl in _closures:
		cl.upvals.clear()
	_closures.clear()
	for t in _tables:
		for key in t.keys():
			var v = t[key]
			if v is LuaClosure or v is Callable or (v is Dictionary and is_same(v, t)):
				t.erase(key)
	_tables.clear()
	globals.clear()
	_dirs.clear()
	_included.clear()

# Wert über einen Punkt-Pfad ("Instance.Str.name_9"); Zahlen als Schlüssel ("Instance.9.path")
func value(dotted: String) -> Variant:
	var v = globals
	for part in dotted.split("."):
		if not v is Dictionary:
			return null
		v = v.get(int(part)) if part.is_valid_int() else v.get(part)
	return v


# ====================================================
# CHUNK LESEN
# ====================================================
func load_chunk(b: PackedByteArray) -> LuaProto:
	if b.size() < HEADER.size():
		errors.append("zu kurz für Lua-Bytecode")
		return null
	for i in HEADER.size():
		if b[i] != HEADER[i]:
			errors.append("kein Lua-5.1-Bytecode (Byte %d = 0x%02x)" % [i, b[i]])
			return null
	_b = b
	_pos = HEADER.size()
	var f = _function()
	_b = PackedByteArray()
	return f

func _function() -> LuaProto:
	var f = LuaProto.new()
	f.source = _string()
	_pos += 8 # erste / letzte Zeile
	f.nups = _b[_pos]
	f.numparams = _b[_pos + 1]
	f.is_vararg = _b[_pos + 2]
	f.maxstack = _b[_pos + 3]
	_pos += 4
	var n = _int()
	f.code.resize(n)
	for i in n:
		f.code[i] = _b.decode_u32(_pos)
		_pos += 4
	n = _int()
	for i in n:
		var t = _b[_pos]
		_pos += 1
		match t:
			0:
				f.k.append(null)
			1:
				f.k.append(_b[_pos] != 0)
				_pos += 1
			3:
				f.k.append(_num(_b.decode_double(_pos)))
				_pos += 8
			4:
				f.k.append(_string())
			_:
				errors.append("Konstante vom Typ %d unbekannt" % t)
				f.k.append(null)
	n = _int()
	for i in n:
		f.p.append(_function())
	n = _int() # Zeilennummern
	_pos += n * 4
	n = _int() # lokale Variablen
	for i in n:
		_string()
		_pos += 8
	n = _int() # Upvalue-Namen
	for i in n:
		_string()
	return f

func _int() -> int:
	var v = _b.decode_s32(_pos)
	_pos += 4
	return v

func _string() -> Variant:
	var n = _b.decode_u32(_pos)
	_pos += 4
	if n == 0:
		return null
	var s = _b.slice(_pos, _pos + n - 1) # ohne die abschließende 0
	_pos += n
	if files != null and not files.is_utf8(s):
		return files.gbk_decode(s)
	return s.get_string_from_utf8()


# ====================================================
# AUSFÜHREN
# ====================================================
func _call(fn, args: Array) -> Array:
	if fn is Callable:
		var r = fn.call(args)
		return r if r is Array else []
	if fn is LuaClosure:
		if _depth >= MAX_DEPTH:
			errors.append("Abbruch: Aufrufe zu tief")
			return []
		_depth += 1
		var r = _exec(fn, args)
		_depth -= 1
		return r
	errors.append("Aufruf von %s" % _type(fn))
	return []

func _exec(cl: LuaClosure, args: Array) -> Array:
	var f: LuaProto = cl.proto
	var code: PackedInt64Array = f.code
	var k: Array = f.k
	var r: Array = []
	r.resize(maxi(f.maxstack, args.size()) + 2)
	for i in f.numparams:
		r[i] = args[i] if i < args.size() else null
	var varargs: Array = args.slice(f.numparams) if f.is_vararg != 0 else []
	var pc = 0
	var top = 0
	while pc < code.size():
		_steps += 1
		if _steps > MAX_STEPS:
			errors.append("Abbruch: mehr als %d Befehle" % MAX_STEPS)
			return []
		var ins = code[pc]
		pc += 1
		var op = ins & 0x3F
		var a = (ins >> 6) & 0xFF
		var c = (ins >> 14) & 0x1FF
		var b = (ins >> 23) & 0x1FF
		var bx = (ins >> 14) & 0x3FFFF
		match op:
			0: # MOVE
				r[a] = r[b]
			1: # LOADK
				r[a] = k[bx]
			2: # LOADBOOL
				r[a] = b != 0
				if c != 0:
					pc += 1
			3: # LOADNIL
				for i in range(a, b + 1):
					r[i] = null
			4: # GETUPVAL
				r[a] = cl.upvals[b] if b < cl.upvals.size() else null
			5: # GETGLOBAL
				r[a] = globals.get(k[bx])
			6: # GETTABLE
				r[a] = _index(r[b], k[c - 256] if c >= 256 else r[c])
			7: # SETGLOBAL
				if r[a] == null:
					globals.erase(k[bx])
				else:
					globals[k[bx]] = r[a]
			8: # SETUPVAL
				if b < cl.upvals.size():
					cl.upvals[b] = r[a]
			9: # SETTABLE
				_setindex(r[a], k[b - 256] if b >= 256 else r[b], k[c - 256] if c >= 256 else r[c])
			10: # NEWTABLE
				var nt = {}
				_tables.append(nt)
				r[a] = nt
			11: # SELF
				r[a + 1] = r[b]
				r[a] = _index(r[b], k[c - 256] if c >= 256 else r[c])
			12, 13, 14, 15, 16, 17: # ADD SUB MUL DIV MOD POW
				r[a] = _arith(op, k[b - 256] if b >= 256 else r[b], k[c - 256] if c >= 256 else r[c])
			18: # UNM
				r[a] = _num(-float(_tonumber(r[b]) if _tonumber(r[b]) != null else 0))
			19: # NOT
				r[a] = not _truthy(r[b])
			20: # LEN
				r[a] = _len(r[b])
			21: # CONCAT
				var s = ""
				for i in range(b, c + 1):
					s += _tostring(r[i])
				r[a] = s
			22: # JMP
				pc += bx - 131071
			23, 24, 25: # EQ LT LE
				var x = k[b - 256] if b >= 256 else r[b]
				var y = k[c - 256] if c >= 256 else r[c]
				var res = _eq(x, y) if op == 23 else _less(x, y, op == 25)
				if res != (a != 0):
					pc += 1
			26: # TEST
				if _truthy(r[a]) != (c != 0):
					pc += 1
			27: # TESTSET
				if _truthy(r[b]) == (c != 0):
					r[a] = r[b]
				else:
					pc += 1
			28, 29: # CALL TAILCALL
				var nargs = b - 1 if b != 0 else top - a - 1
				var res = _call(r[a], r.slice(a + 1, a + 1 + nargs))
				if op == 29:
					return res
				if c == 0:
					if r.size() < a + res.size() + 2:
						r.resize(a + res.size() + 2)
					for j in res.size():
						r[a + j] = res[j]
					top = a + res.size()
				else:
					for j in c - 1:
						r[a + j] = res[j] if j < res.size() else null
			30: # RETURN
				return r.slice(a, top) if b == 0 else r.slice(a, a + b - 1)
			31: # FORLOOP
				var step = float(r[a + 2])
				var idx = float(r[a]) + step
				r[a] = _num(idx)
				if (step > 0.0 and idx <= float(r[a + 1])) or (step <= 0.0 and idx >= float(r[a + 1])):
					pc += bx - 131071
					r[a + 3] = r[a]
			32: # FORPREP
				r[a] = _num(float(_tonumber(r[a])) - float(_tonumber(r[a + 2])))
				r[a + 1] = _tonumber(r[a + 1])
				r[a + 2] = _tonumber(r[a + 2])
				pc += bx - 131071
			33: # TFORLOOP
				var res = _call(r[a], [r[a + 1], r[a + 2]])
				if r.size() < a + 3 + c + 1:
					r.resize(a + 3 + c + 1)
				for j in c:
					r[a + 3 + j] = res[j] if j < res.size() else null
				if r[a + 3] != null:
					r[a + 2] = r[a + 3]
				else:
					pc += 1
			34: # SETLIST
				var n = b if b != 0 else top - a - 1
				var block = c
				if block == 0:
					block = code[pc]
					pc += 1
				var t = r[a]
				if t is Dictionary:
					var base = (block - 1) * FIELDS_PER_FLUSH
					for j in range(1, n + 1):
						if r[a + j] != null:
							t[base + j] = r[a + j]
			35: # CLOSE
				pass
			36: # CLOSURE
				var np: LuaProto = f.p[bx]
				var ncl = LuaClosure.new()
				ncl.proto = np
				_closures.append(ncl)
				for j in np.nups:
					var pi = code[pc]
					pc += 1
					var pb = (pi >> 23) & 0x1FF
					ncl.upvals.append(r[pb] if (pi & 0x3F) == 0 else (cl.upvals[pb] if pb < cl.upvals.size() else null))
				r[a] = ncl
			37: # VARARG
				var n = b - 1 if b != 0 else varargs.size()
				if r.size() < a + n + 2:
					r.resize(a + n + 2)
				for j in n:
					r[a + j] = varargs[j] if j < varargs.size() else null
				if b == 0:
					top = a + n
			_:
				errors.append("Abbruch: Befehl %d unbekannt" % op)
				return []
	return []


# ====================================================
# WERTE
# ====================================================
# Ganzzahlige double -> int (Tabellen-Schlüssel 1 und 1.0 sind in Lua derselbe)
static func _num(x: float) -> Variant:
	if is_finite(x) and x == floor(x) and absf(x) < 9.0e15:
		return int(x)
	return x

static func _arg(a: Array, i: int) -> Variant:
	return a[i] if i < a.size() else null

static func _truthy(v) -> bool:
	return v != null and not (v is bool and v == false)

static func _type(v) -> String:
	if v == null:
		return "nil"
	if v is bool:
		return "boolean"
	if v is int or v is float:
		return "number"
	if v is String:
		return "string"
	if v is Dictionary:
		return "table"
	return "function"

static func _tostring(v) -> String:
	if v == null:
		return "nil"
	if v is bool:
		return "true" if v else "false"
	if v is float:
		return String.num(v, 14)
	if v is int or v is String:
		return str(v)
	return _type(v)

static func _tonumber(v) -> Variant:
	if v is int or v is float:
		return v
	if v is String and v.strip_edges().is_valid_float():
		return _num(v.strip_edges().to_float())
	return null

static func _key(k) -> Variant:
	return _num(k) if k is float else k

func _index(t, k) -> Variant:
	if t is Dictionary:
		return t.get(_key(k))
	if t is String: # s:format(...) usw.
		return globals["string"].get(k)
	return null

func _setindex(t, k, v) -> void:
	if not t is Dictionary or k == null:
		return
	if v == null:
		t.erase(_key(k))
	else:
		t[_key(k)] = v

func _len(v) -> int:
	if v is String:
		return v.to_utf8_buffer().size()
	if v is Dictionary:
		var n = 0
		while v.has(n + 1):
			n += 1
		return n
	return 0

static func _eq(x, y) -> bool:
	if (x is int or x is float) and (y is int or y is float):
		return x == y
	if typeof(x) != typeof(y):
		return false
	if x is Dictionary or x is Object or x is Callable:
		return is_same(x, y)
	return x == y

static func _less(x, y, or_equal: bool) -> bool:
	if (x is int or x is float) and (y is int or y is float):
		return x <= y if or_equal else x < y
	if x is String and y is String:
		return x <= y if or_equal else x < y
	return false

static func _arith(op: int, x, y) -> Variant:
	var a = _tonumber(x)
	var b = _tonumber(y)
	if a == null or b == null:
		return null
	var fa = float(a)
	var fb = float(b)
	match op:
		12:
			return _num(fa + fb)
		13:
			return _num(fa - fb)
		14:
			return _num(fa * fb)
		15:
			return _num(fa / fb) if fb != 0.0 else (INF if fa >= 0.0 else -INF)
		16:
			return _num(fa - floor(fa / fb) * fb) if fb != 0.0 else NAN
		_:
			return _num(pow(fa, fb))


# ====================================================
# EINGEBAUTE FUNKTIONEN (Argumente als Array, Ergebnisse als Array)
# ====================================================
func _lua_include(a: Array) -> Array:
	var name = str(_arg(a, 0)).replace("\\", "/")
	var dir: String = _dirs.back() if not _dirs.is_empty() else ""
	var path = dir.path_join(name)
	if files != null:
		var real: String = files.resolve(name, dir)
		if real != "":
			path = real
	if _included.has(path.to_lower()):
		return []
	var err = run_file(path)
	if err != "":
		errors.append("LuaInclude(%s): %s" % [name, err])
	return []

# next(t, k) in Einfüge-Reihenfolge (einzeln aufgerufen: Suche des Schlüssels)
func _next(a: Array) -> Array:
	var t = _arg(a, 0)
	if not t is Dictionary:
		return [null]
	var keys = t.keys()
	var i = 0 if _arg(a, 1) == null else keys.find(_key(_arg(a, 1))) + 1
	if i <= 0 and _arg(a, 1) != null or i >= keys.size():
		return [null]
	return [keys[i], t[keys[i]]]

# pairs(t): eigener Iterator mit der Schlüsselliste vom Schleifenbeginn (schnell auch für große
# Tabellen; während der Schleife entfernte Schlüssel werden übersprungen)
func _pairs(a: Array) -> Array:
	var t = _arg(a, 0)
	var keys: Array = t.keys() if t is Dictionary else []
	var state = [0]
	var it = func(args: Array) -> Array:
		var tt = args[0]
		while state[0] < keys.size():
			var key = keys[state[0]]
			state[0] += 1
			if tt.has(key):
				return [key, tt[key]]
		return [null]
	return [it, t, null]

func _inext(a: Array) -> Array:
	var t = _arg(a, 0)
	var i = int(_arg(a, 1)) + 1
	var v = t.get(i) if t is Dictionary else null
	return [null] if v == null else [i, v]

func _unpack(a: Array) -> Array:
	var t = _arg(a, 0)
	if not t is Dictionary:
		return []
	var i = int(_arg(a, 1)) if _arg(a, 1) != null else 1
	var j = int(_arg(a, 2)) if _arg(a, 2) != null else _len(t)
	var out = []
	for n in range(i, j + 1):
		out.append(t.get(n))
	return out

func _table_insert(a: Array) -> Array:
	var t = _arg(a, 0)
	if not t is Dictionary:
		return []
	var n = _len(t)
	if a.size() >= 3:
		var pos = int(a[1])
		for i in range(n, pos - 1, -1):
			t[i + 1] = t[i]
		t[pos] = a[2]
	else:
		t[n + 1] = _arg(a, 1)
	return []

func _table_remove(a: Array) -> Array:
	var t = _arg(a, 0)
	if not t is Dictionary:
		return [null]
	var n = _len(t)
	var pos = int(_arg(a, 1)) if _arg(a, 1) != null else n
	var v = t.get(pos)
	for i in range(pos, n):
		t[i] = t[i + 1]
	t.erase(n)
	return [v]

func _table_concat(a: Array) -> Array:
	var t = _arg(a, 0)
	var sep = str(_arg(a, 1)) if _arg(a, 1) != null else ""
	var parts = PackedStringArray()
	for i in range(1, _len(t) + 1):
		parts.append(_tostring(t[i]))
	return [sep.join(parts)]

func _string_sub(a: Array) -> Array:
	var s = str(_arg(a, 0))
	var n = s.length()
	var i = int(_arg(a, 1)) if _arg(a, 1) != null else 1
	var j = int(_arg(a, 2)) if _arg(a, 2) != null else -1
	if i < 0:
		i = maxi(n + i + 1, 1)
	if j < 0:
		j = n + j + 1
	i = maxi(i, 1)
	j = mini(j, n)
	return [s.substr(i - 1, j - i + 1) if i <= j else ""]

# string.format mit %d %i %s %f %x %X %c %%  (Breite / Genauigkeit wie printf)
func _string_format(a: Array) -> Array:
	var fmt = str(_arg(a, 0))
	var out = ""
	var ai = 1
	var i = 0
	while i < fmt.length():
		var ch = fmt[i]
		if ch != "%" or i + 1 >= fmt.length():
			out += ch
			i += 1
			continue
		var j = i + 1
		while j < fmt.length() and "-+ #0123456789.".contains(fmt[j]):
			j += 1
		if j >= fmt.length():
			break
		var spec = fmt.substr(i, j - i + 1)
		var conv = fmt[j]
		var v = _arg(a, ai)
		match conv:
			"%":
				out += "%"
				ai -= 1
			"d", "i":
				out += (spec.left(-1) + "d") % int(_tonumber(v) if _tonumber(v) != null else 0)
			"f", "g", "e":
				out += (spec.left(-1) + "f") % float(_tonumber(v) if _tonumber(v) != null else 0)
			"x", "X":
				out += spec % int(_tonumber(v) if _tonumber(v) != null else 0)
			"c":
				out += String.chr(int(_tonumber(v) if _tonumber(v) != null else 32))
			_:
				out += (spec.left(-1) + "s") % _tostring(v)
		ai += 1
		i = j + 1
	return [out]
