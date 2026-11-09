@tool
extends RefCounted

# ====================================================
# Terrain-Höhen des Spielservers (Server/data/<Ordner>/terrain.cfg + map/<n>.hmap, wie
# CTerrain::GetHeightAt des gs): nRow * nCol Teilkarten mit je nAreaWidth * nAreaHeight Feldern
# von vGridSize Metern; jede .hmap enthält (nAreaWidth + 1) * (nAreaHeight + 1) float, Werte 0 - 1
# zwischen vHeightMin und vHeightMax, zeilenweise von +Z nach -Z, in der Zeile von -X nach +X.
# Teilkarte <n> = Zeile * nCol + Spalte + 1, Zeile 0 oben (+Z), Nachbarn teilen ihre Randzeile.
# Die Map ist um den Ursprung zentriert (Koordinaten wie die importierten Maps des Clients).
# Höhe dazwischen bilinear; außerhalb gilt der nächste Rand.
# Geprüft: die Startpositionen von s9 / s10 / s31 liegen auf diesen Höhen (± 0,01 m).
# load_like(): Raster einer anderen Karte, Höhen aus fremden .hmap-Daten (Abgleich mit dem Client).
# ====================================================

const CFG_FILE = "terrain.cfg"

var rows = 0
var cols = 0
var area_w = 0 # Felder je Teilkarte
var area_h = 0
var grid = 2.0
var h_min = 0.0
var h_max = 800.0
var _maps: Array = [] # PackedFloat32Array je Teilkarte
var _x0 = 0.0 # linker Rand (-X)
var _z0 = 0.0 # oberer Rand (+Z)


# Ordner mit terrain.cfg und map/ -> "" oder Fehlertext
func load_dir(dir: String) -> String:
	var cfg = FileAccess.get_file_as_string(dir.path_join(CFG_FILE))
	if cfg == "":
		return dir.path_join(CFG_FILE) + " fehlt"
	var v = {}
	for line in cfg.split("\n"):
		var eq = line.find("=")
		if eq > 0:
			v[line.substr(0, eq).strip_edges()] = line.substr(eq + 1).strip_edges()
	rows = int(v.get("nRow", "0"))
	cols = int(v.get("nCol", "0"))
	area_w = int(v.get("nAreaWidth", "0"))
	area_h = int(v.get("nAreaHeight", "0"))
	grid = float(v.get("vGridSize", "2"))
	h_min = float(v.get("vHeightMin", "0"))
	h_max = float(v.get("vHeightMax", "800"))
	if rows <= 0 or cols <= 0 or area_w <= 0 or area_h <= 0 or grid <= 0.0:
		return dir.path_join(CFG_FILE) + ": unbrauchbar"
	var samples = (area_w + 1) * (area_h + 1)
	_maps = []
	for i in rows * cols:
		var p = dir.path_join("map").path_join("%d.hmap" % (i + 1))
		var b = FileAccess.get_file_as_bytes(p)
		if b.size() != samples * 4:
			_maps = []
			return "%s: %d Bytes statt %d" % [p, b.size(), samples * 4]
		_maps.append(b.to_float32_array())
	_x0 = -cols * area_w * grid / 2.0
	_z0 = rows * area_h * grid / 2.0
	return ""

# Raster von other (z.B. der Server-Map), Höhen aus anderen .hmap-Daten (z.B. movemaps\<n>.hmap des
# Clients, gleicher Aufbau) -> "" oder Fehlertext
func load_like(other, hmaps: Array) -> String:
	rows = other.rows
	cols = other.cols
	area_w = other.area_w
	area_h = other.area_h
	grid = other.grid
	h_min = other.h_min
	h_max = other.h_max
	var samples = (area_w + 1) * (area_h + 1)
	_maps = []
	if hmaps.size() != rows * cols:
		return "%d Teilkarten statt %d" % [hmaps.size(), rows * cols]
	for b in hmaps:
		if b.size() != samples * 4:
			_maps = []
			return "%d Bytes statt %d" % [b.size(), samples * 4]
		_maps.append(b.to_float32_array())
	_x0 = other._x0
	_z0 = other._z0
	return ""

func is_loaded() -> bool:
	return not _maps.is_empty()

# Ausdehnung in Metern [min x, min z, max x, max z]
func bounds() -> Array:
	return [_x0, _z0 - rows * area_h * grid, _x0 + cols * area_w * grid, _z0]

func height(x: float, z: float) -> float:
	if _maps.is_empty():
		return 0.0
	var gx = clampf((x - _x0) / grid, 0.0, float(cols * area_w))
	var gz = clampf((_z0 - z) / grid, 0.0, float(rows * area_h))
	var ix = mini(int(gx), cols * area_w - 1)
	var iz = mini(int(gz), rows * area_h - 1)
	var fx = gx - ix
	var fz = gz - iz
	var a = _sample(ix, iz)
	var b = _sample(ix + 1, iz)
	var c = _sample(ix, iz + 1)
	var d = _sample(ix + 1, iz + 1)
	var t = lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fz)
	return h_min + t * (h_max - h_min)

# Wert am Rasterpunkt (gx, gz) der ganzen Map
func _sample(gx: int, gz: int) -> float:
	var col = mini(gx / area_w, cols - 1)
	var row = mini(gz / area_h, rows - 1)
	var lx = gx - col * area_w
	var lz = gz - row * area_h
	var m: PackedFloat32Array = _maps[row * cols + col]
	return m[lz * (area_w + 1) + lx]
