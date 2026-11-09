@tool
extends RefCounted

# ====================================================
# Wegekarten einer Map (maps\<map>\movemaps, AutoMove des Spiels: CMoveMap / CLayerMap) und
# Wegfindung darauf - für die Autoroute des Clients (und später die Wege der NPCs).
# Dateien (little endian; Binärdateien des Spiels beginnen oft mit "MOXB", das wird übersprungen):
#   pfmap.cfg  "fgfc" (PFMAP_CFG_FILE_MAGIC), Version 1, Anzahl Ebenen, je Ebene: Name (Länge + Text),
#              Merker .prmap / .pdhmap / .isl vorhanden; danach Name der .mlu (Cluster über alle
#              Ebenen) und optional preprocess.dat - beides braucht die Suche hier nicht
#   <Ebene>.prmap   Begehbarkeit (CBitImage): "fpmb", Version 3, Puffergröße, Breite in Bytes, Zeilen,
#              Breite / Länge in Feldern, Feldgröße (float, 1 m), dann die Bits zeilenweise (Bit u & 7
#              von Byte v * Breite + u >> 3)
#   <Ebene>.pdhmap  Höhe über dem Gelände je Feld (CBlockImage<FIX16>): Version 2, Puffergröße,
#              Größe von T (2), Standardwert (2 Byte), Blöcke breit / lang, 2er-Exponent der
#              Blockgröße (16), Breite / Länge, Feldgröße, Block-IDs (-1 = Standard), Anzahl Blöcke,
#              die Blöcke zeilenweise; Wert (mit Vorzeichen) / 64 = Meter. So in Forsaken World: die
#              Shenmo-Quellen haben den Standardwert als int und die Anzahl vor den IDs
# Lage: der Mittelpunkt der Karte ist der Weltursprung, Feld u = floor(x + Breite / 2), v = floor(z +
# Länge / 2) (CMoveMap::TransWld2Map). Ebene 0 = Boden, weitere Ebenen = Brücken, Gebäude ...; eine
# Figur ist auf der Ebene, deren Höhe über dem Gelände zu ihrer passt (WhichLayer, 1 m), ein Ziel ohne
# Höhe auf der untersten begehbaren (GetMinPassableLayer).
# Suche: A* über (u, v, Ebene) mit 8 Nachbarn (schräg nur, wenn beide geraden Nachbarn begehbar sind),
# Wechsel der Ebene an einem Feld, wo beide begehbar sind und höchstens LAYER_DH auseinanderliegen;
# ist Start oder Ziel nicht begehbar, das nächste begehbare Feld (bis SNAP_RADIUS). Danach geglättet:
# gerade Stücke, solange alle überquerten Felder derselben Ebene begehbar sind.
#   load(files, Ordner movemaps) -> "" oder Fehlertext
#   find_path(von, nach, dh_von, nach_ohne_höhe) -> PackedVector3Array (x, Höhe über Gelände, z), leer =
#   kein Weg; state / expanded nach der Suche
# ====================================================

const CFG_MAGIC = 0x63666766 # "fgfc"
const BIT_MAGIC = 0x626d7066 # "fpmb"
const MOXB = 0x42584f4d
const LAYER_DH = 1.0 # SAME_LAYER_DH
const SNAP_RADIUS = 8
const MAX_EXPANDED = 400000
const DIAG = 1.41421356

var layers: Array = [] # [{name, w, l, row, bits: PackedByteArray, dh: PackedFloat32Array oder leer}]
var width = 0 # Felder
var length = 0
var pixel = 1.0 # m je Feld
var state = "" # "", "gefunden", "kein Weg", "Start ungültig", "Ziel ungültig", "zu weit"
var expanded = 0


func load(files, dir: String) -> String:
	layers = []
	var cfg_path: String = files.resolve("pfmap.cfg", dir)
	if cfg_path == "":
		return dir + "/pfmap.cfg fehlt"
	var b: PackedByteArray = files.get_bytes(cfg_path)
	var p = _skip_moxb(b)
	if b.size() < p + 12 or b.decode_u32(p) != CFG_MAGIC or b.decode_u32(p + 4) != 1:
		return "pfmap.cfg: unbekanntes Format"
	var count = b.decode_s32(p + 8)
	p += 12
	for i in count:
		var n = b.decode_s32(p)
		var layer_name = b.slice(p + 4, p + 4 + n).get_string_from_ascii()
		p += 4 + n
		var has_r = b.decode_u32(p) == 1
		var has_dh = b.decode_u32(p + 4) == 1
		p += 12 # .isl wird nicht gebraucht
		var layer = {"name": layer_name, "bits": PackedByteArray(), "dh": PackedFloat32Array()}
		if has_r:
			var err = _load_rmap(files, dir, layer_name + ".prmap", layer)
			if err != "":
				return err
		if has_dh:
			var err = _load_dhmap(files, dir, layer_name + ".pdhmap", layer)
			if err != "":
				return err
		layers.append(layer)
	if layers.is_empty() or layers[0]["bits"].is_empty():
		return "pfmap.cfg: keine Ebene"
	width = layers[0]["w"]
	length = layers[0]["l"]
	pixel = layers[0]["pixel"]
	return ""

static func _skip_moxb(b: PackedByteArray) -> int:
	return 4 if b.size() >= 4 and b.decode_u32(0) == MOXB else 0

func _load_rmap(files, dir: String, file: String, layer: Dictionary) -> String:
	var path: String = files.resolve(file, dir)
	var b: PackedByteArray = files.get_bytes(path) if path != "" else PackedByteArray()
	var p = _skip_moxb(b)
	if b.size() < p + 12:
		return file + " fehlt"
	if b.decode_u32(p) == BIT_MAGIC:
		p += 8 # Kennung, Version
	else:
		p += 4 # alte Version ohne Kennung
	var size = b.decode_u32(p)
	p += 4
	if b.size() < p + size or size < 20:
		return file + ": zu kurz"
	layer["row"] = b.decode_s32(p)
	var lines = b.decode_s32(p + 4)
	layer["w"] = b.decode_s32(p + 8)
	layer["l"] = b.decode_s32(p + 12)
	layer["pixel"] = b.decode_float(p + 16)
	layer["bits"] = b.slice(p + 20, p + 20 + layer["row"] * lines)
	return ""

func _load_dhmap(files, dir: String, file: String, layer: Dictionary) -> String:
	var path: String = files.resolve(file, dir)
	var b: PackedByteArray = files.get_bytes(path) if path != "" else PackedByteArray()
	var p = _skip_moxb(b)
	if b.size() < p + 44:
		return file + " fehlt"
	var version = b.decode_u32(p)
	p += 8 # Version, Puffergröße
	var t_size = 2
	var def_val = 0
	if version == 2:
		t_size = b.decode_s32(p)
		def_val = b.decode_s16(p + 4)
		p += 6
	var bw = b.decode_s32(p)
	var bl = b.decode_s32(p + 4)
	var exp = b.decode_s32(p + 8)
	var iw = b.decode_s32(p + 12)
	var il = b.decode_s32(p + 16)
	p += 24 # dazu die Feldgröße
	if t_size != 2 or bw <= 0 or bl <= 0 or b.size() < p + bw * bl * 4 + 4:
		return file + ": unbekanntes Format"
	var bs = 1 << exp
	var ids = b.slice(p, p + bw * bl * 4).to_int32_array()
	p += bw * bl * 4
	var nblocks = b.decode_s32(p)
	p += 4
	var dh = PackedFloat32Array()
	dh.resize(iw * il)
	dh.fill(def_val / 64.0)
	for by in bl:
		for bx in bw:
			var id = ids[by * bw + bx]
			if id < 0 or id >= nblocks:
				continue
			var base = p + id * bs * bs * 2
			for y in bs:
				var v = by * bs + y
				if v >= il:
					break
				for x in bs:
					var u = bx * bs + x
					if u < iw:
						dh[v * iw + u] = b.decode_s16(base + (y * bs + x) * 2) / 64.0
	layer["dh"] = dh
	return ""


# ====================================================
# ABFRAGEN
# ====================================================
func cell_of(x: float, z: float) -> Vector2i:
	return Vector2i(floori((x + width * pixel * 0.5) / pixel), floori((z + length * pixel * 0.5) / pixel))

func world_of(c: Vector2i) -> Vector2:
	return Vector2((c.x + 0.5) * pixel - width * pixel * 0.5, (c.y + 0.5) * pixel - length * pixel * 0.5)

func passable(layer: int, u: int, v: int) -> bool:
	if u < 0 or v < 0 or u >= width or v >= length or layer < 0 or layer >= layers.size():
		return false
	var L: Dictionary = layers[layer]
	var bits: PackedByteArray = L["bits"]
	if bits.is_empty():
		return false
	return (bits[v * L["row"] + (u >> 3)] & (1 << (u & 7))) != 0

func dh(layer: int, u: int, v: int) -> float:
	var d: PackedFloat32Array = layers[layer]["dh"] if layer >= 0 and layer < layers.size() else PackedFloat32Array()
	return d[v * width + u] if not d.is_empty() and u >= 0 and v >= 0 and u < width and v < length else 0.0

# Ebene, deren Höhe über dem Gelände am besten zu height_over_ground passt (WhichLayer)
func which_layer(c: Vector2i, height_over_ground: float) -> int:
	var best = -1
	var best_d = INF
	for i in layers.size():
		if passable(i, c.x, c.y):
			var d = absf(dh(i, c.x, c.y) - height_over_ground)
			if d < LAYER_DH:
				return i
			if d < best_d:
				best_d = d
				best = i
	return best

func min_passable_layer(c: Vector2i) -> int:
	for i in layers.size():
		if passable(i, c.x, c.y):
			return i
	return -1


# ====================================================
# SUCHE
# ====================================================
# Weg von from (Figur, dh_from m über dem Gelände) nach to; goal_any_layer: Ziel auf der untersten
# begehbaren Ebene (Klick auf Karte / NPC ohne Höhe) -> Wegpunkte (x, Höhe über Gelände, z)
func find_path(from: Vector3, to: Vector3, dh_from: float = 0.0, goal_any_layer: bool = true, dh_to: float = 0.0) -> PackedVector3Array:
	state = ""
	expanded = 0
	if layers.is_empty():
		state = "keine Wegekarte"
		return PackedVector3Array()
	var s = _snap(cell_of(from.x, from.z), -1, dh_from)
	if s.is_empty():
		state = "Start ungültig"
		return PackedVector3Array()
	var g = _snap(cell_of(to.x, to.z), -1 if goal_any_layer else -2, dh_to)
	if g.is_empty():
		state = "Ziel ungültig"
		return PackedVector3Array()
	var cells = _astar(s[0], s[1], g[0], g[1])
	if cells.is_empty():
		return PackedVector3Array()
	var pts = _smooth(cells)
	var out = PackedVector3Array()
	for i in pts.size():
		var c: Vector3i = pts[i]
		var w = world_of(Vector2i(c.x, c.y))
		out.append(Vector3(w.x, dh(c.z, c.x, c.y), w.y))
	# letzter Punkt genau am Ziel, wenn das Ziel selbst begehbar ist
	if g[0] == cell_of(to.x, to.z) and out.size() > 0:
		out[out.size() - 1] = Vector3(to.x, out[out.size() - 1].y, to.z)
	state = "gefunden"
	return out

# Nächstes begehbares Feld um c -> [Feld, Ebene] oder []; mode -1: Ebene nach Höhe dh (Start) bzw.
# unterste (Ziel), -2: nach Höhe dh
func _snap(c: Vector2i, mode: int, height: float) -> Array:
	for r in SNAP_RADIUS + 1:
		var best = []
		var best_d = INF
		for dv in range(-r, r + 1):
			for du in range(-r, r + 1):
				if maxi(absi(du), absi(dv)) != r:
					continue
				var cc = Vector2i(c.x + du, c.y + dv)
				var layer = which_layer(cc, height) if mode == -2 or height != 0.0 else min_passable_layer(cc)
				if layer < 0:
					continue
				var d = du * du + dv * dv
				if d < best_d:
					best_d = d
					best = [cc, layer]
		if not best.is_empty():
			return best
	return []

func _astar(s: Vector2i, sl: int, g: Vector2i, gl: int) -> Array:
	var plane = width * length
	var n = plane * layers.size()
	var gs = PackedFloat32Array()
	gs.resize(n)
	gs.fill(INF)
	var parent = PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	var closed = PackedByteArray()
	closed.resize(n)
	var start = sl * plane + s.y * width + s.x
	var goal = gl * plane + g.y * width + g.x
	gs[start] = 0.0
	# binärer Heap: Schlüssel f und Knoten
	var hf = PackedFloat32Array([_h(s.x, s.y, g)])
	var hn = PackedInt32Array([start])
	var dirs = [[1, 0, 1.0], [-1, 0, 1.0], [0, 1, 1.0], [0, -1, 1.0], [1, 1, DIAG], [1, -1, DIAG], [-1, 1, DIAG], [-1, -1, DIAG]]
	while hn.size() > 0:
		var cur = hn[0]
		# Wurzel entfernen
		var last = hn.size() - 1
		var lf = hf[last]
		var ln = hn[last]
		hf.resize(last)
		hn.resize(last)
		if last > 0:
			var i = 0
			while true:
				var l = 2 * i + 1
				if l >= last:
					break
				var m = l
				if l + 1 < last and hf[l + 1] < hf[l]:
					m = l + 1
				if hf[m] >= lf:
					break
				hf[i] = hf[m]
				hn[i] = hn[m]
				i = m
			hf[i] = lf
			hn[i] = ln
		if closed[cur] != 0:
			continue
		closed[cur] = 1
		expanded += 1
		if cur == goal:
			break
		if expanded > MAX_EXPANDED:
			state = "zu weit"
			return []
		var layer = cur / plane
		var rest = cur - layer * plane
		var v = rest / width
		var u = rest - v * width
		var gc = gs[cur]
		# Nachbarn in derselben Ebene
		for d in dirs:
			var nu = u + d[0]
			var nv = v + d[1]
			if not passable(layer, nu, nv):
				continue
			if d[2] > 1.0 and (not passable(layer, u + d[0], v) or not passable(layer, u, v + d[1])):
				continue
			var nb = layer * plane + nv * width + nu
			var ng = gc + d[2]
			if closed[nb] == 0 and ng < gs[nb]:
				gs[nb] = ng
				parent[nb] = cur
				_push(hf, hn, ng + _h(nu, nv, g), nb)
		# Wechsel der Ebene am selben Feld
		var here = dh(layer, u, v)
		for ol in layers.size():
			if ol == layer or not passable(ol, u, v) or absf(dh(ol, u, v) - here) > LAYER_DH:
				continue
			var nb = ol * plane + rest
			var ng = gc + 0.01
			if closed[nb] == 0 and ng < gs[nb]:
				gs[nb] = ng
				parent[nb] = cur
				_push(hf, hn, ng + _h(u, v, g), nb)
	if parent[goal] == -1 and goal != start:
		state = "kein Weg"
		return []
	var cells = []
	var c = goal
	while c != -1:
		var layer = c / plane
		var rest = c - layer * plane
		cells.append(Vector3i(rest % width, rest / width, layer))
		c = parent[c]
	cells.reverse()
	return cells

static func _push(hf: PackedFloat32Array, hn: PackedInt32Array, f: float, node: int) -> void:
	var i = hn.size()
	hf.append(f)
	hn.append(node)
	while i > 0:
		var p = (i - 1) >> 1
		if hf[p] <= f:
			break
		hf[i] = hf[p]
		hn[i] = hn[p]
		i = p
	hf[i] = f
	hn[i] = node

static func _h(u: int, v: int, g: Vector2i) -> float:
	var dx = absi(u - g.x)
	var dy = absi(v - g.y)
	return maxf(dx, dy) + (DIAG - 1.0) * minf(dx, dy)

# Gerade Stücke: vom Anker aus so weit wie möglich, solange die Linie in derselben Ebene begehbar ist
func _smooth(cells: Array) -> Array:
	if cells.size() <= 2:
		return cells
	var out = [cells[0]]
	var anchor = 0
	var i = 2
	while i < cells.size():
		var a: Vector3i = cells[anchor]
		var c: Vector3i = cells[i]
		if c.z != a.z or not _line_free(a, c):
			anchor = i - 1
			out.append(cells[anchor])
		i += 1
	out.append(cells[cells.size() - 1])
	return out

# Alle Felder auf der Linie a -> c (Ebene a.z) begehbar? (Schritte von 0,25 Feld, dazu die Ecken)
func _line_free(a: Vector3i, c: Vector3i) -> bool:
	var d = Vector2(c.x - a.x, c.y - a.y)
	var steps = int(ceil(d.length() * 4.0))
	var last = Vector2i(a.x, a.y)
	for k in range(1, steps + 1):
		var p = Vector2(a.x + 0.5, a.y + 0.5) + d * (float(k) / steps)
		var cell = Vector2i(floori(p.x), floori(p.y))
		if cell == last:
			continue
		if not passable(a.z, cell.x, cell.y):
			return false
		if cell.x != last.x and cell.y != last.y and (not passable(a.z, cell.x, last.y) or not passable(a.z, last.x, cell.y)):
			return false
		last = cell
	return true
