@tool
extends RefCounted

# ====================================================
# Dateisystem der Spieldaten: echte Ordner und Angelica-Pakete (angelica_pck.gd) zusammen, wie
# AFilePackMan im Spiel: das Paket <Ordner>/<Name>.pck erscheint als Ordner <Ordner>/<Name>/
# (Namen im Paket sind relativ zu diesem Ordner). Pfade sehen also aus wie bei entpackten Daten,
# z.B. res://Stock-PWE-Client/resources/models/npcs/x/x.ecm aus resources/models.pck (+ .pkx).
# Eine echte Datei geht der im Paket vor (lose Dateien neben den Paketen); innerhalb der Pakete
# ohne Groß/Klein-Unterscheidung. Pakete werden beim ersten Zugriff geöffnet und bleiben offen,
# geteilt von allen Lesern (statisch; der Scan der Leiste ECM-GFX-MAP läuft in einem Thread,
# daher die Sperre). Nur lesen.
# ====================================================

const Pck = preload("angelica_pck.gd")

static var _lock = Mutex.new()
static var _packs = {} # .pck-Pfad -> angelica_pck.gd (null = nicht lesbar)
static var _pack_dir = {} # Ordner (klein) -> .pck-Pfad oder ""
static var _real = {} # echter Ordner -> {Name klein: [Name, ist Ordner]}
static var errors: Array = [] # Pakete, die sich nicht öffnen ließen


# Alles vergessen (z.B. nach dem Wechsel des Spieldaten-Ordners); Pakete schließen
static func reset() -> void:
	_lock.lock()
	for p in _packs.values():
		if p != null:
			p.close()
	_packs = {}
	_pack_dir = {}
	_real = {}
	errors = []
	_lock.unlock()

static func file_exists(path: String, decoder) -> bool:
	if FileAccess.file_exists(path):
		return true
	_lock.lock()
	var at = _locate(path, decoder)
	var ok = not at.is_empty() and at[0].has_file(at[1])
	_lock.unlock()
	return ok

static func dir_exists(path: String, decoder) -> bool:
	if DirAccess.dir_exists_absolute(path):
		return true
	_lock.lock()
	var at = _locate_dir(path, decoder)
	_lock.unlock()
	return not at.is_empty()

# Inhalt einer Datei (echt oder aus dem Paket), leer wenn sie fehlt
static func get_bytes(path: String, decoder) -> PackedByteArray:
	if FileAccess.file_exists(path):
		return FileAccess.get_file_as_bytes(path)
	_lock.lock()
	var at = _locate(path, decoder)
	var b = at[0].get_bytes(at[1]) if not at.is_empty() else PackedByteArray()
	_lock.unlock()
	return b

# Größe einer Datei, -1 wenn sie fehlt
static func file_size(path: String, decoder) -> int:
	if FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		return f.get_length() if f != null else -1
	_lock.lock()
	var at = _locate(path, decoder)
	var n = at[0].file_size(at[1]) if not at.is_empty() else -1
	_lock.unlock()
	return n

# Inhalt eines Ordners: {Name klein: [Name, ist Ordner]}; echte Einträge, Pakete als Ordner und
# der Inhalt eines Paketordners
static func list(dir: String, decoder) -> Dictionary:
	dir = dir.trim_suffix("/") if not dir.ends_with("://") else dir
	_lock.lock()
	var out = {}
	var real = _real_list(dir)
	for k in real:
		out[k] = real[k]
		if not real[k][1] and k.ends_with(".pck"):
			var folder = k.trim_suffix(".pck")
			if not out.has(folder):
				out[folder] = [real[k][0].get_basename(), true]
	var at = _locate_dir(dir, decoder)
	if not at.is_empty():
		var inner: Dictionary = at[0].list_dir(at[1])
		for k in inner:
			if not out.has(k):
				out[k] = inner[k]
	_lock.unlock()
	return out

# Geöffnete Pakete: [{path, count, algorithm}]
static func packages() -> Array:
	var out = []
	for p in _packs:
		if _packs[p] != null:
			out.append({"path": p, "count": _packs[p].count, "algorithm": _packs[p].algorithm})
	return out


# ====================================================
# INTERN (unter der Sperre)
# ====================================================
# Datei -> [Paket, Pfad im Paket] oder []
static func _locate(path: String, decoder) -> Array:
	var dir = path.get_base_dir()
	var rel = path.get_file()
	while dir != "" and not dir.ends_with("://") and dir != "/":
		var pck = _pack_for(dir, decoder)
		if pck != null:
			return [pck, rel]
		rel = dir.get_file() + "/" + rel
		dir = dir.get_base_dir()
	return []

# Ordner -> [Paket, Ordner im Paket] oder [] (auch wenn es den Ordner im Paket nicht gibt: [])
static func _locate_dir(path: String, decoder) -> Array:
	var dir = path
	var rel = ""
	while dir != "" and not dir.ends_with("://") and dir != "/":
		var pck = _pack_for(dir, decoder)
		if pck != null:
			return [pck, rel] if pck.has_dir(rel) else []
		rel = dir.get_file() if rel == "" else dir.get_file() + "/" + rel
		dir = dir.get_base_dir()
	return []

# Paket, das den Ordner dir abbildet (<Eltern>/<Name>.pck), sonst null
static func _pack_for(dir: String, decoder):
	var key = dir.to_lower()
	if not _pack_dir.has(key):
		var parent = dir.get_base_dir()
		var hit = _real_list(parent).get(dir.get_file().to_lower() + ".pck")
		_pack_dir[key] = parent.path_join(hit[0]) if hit != null and not hit[1] else ""
	var p: String = _pack_dir[key]
	if p == "":
		return null
	if not _packs.has(p):
		var pck = Pck.new()
		var err = pck.open(p, decoder)
		if err != "":
			errors.append(err)
			pck = null
		_packs[p] = pck
	return _packs[p]

static func _real_list(dir: String) -> Dictionary:
	if _real.has(dir):
		return _real[dir]
	var names = {}
	var d = DirAccess.open(dir)
	if d != null:
		for f in d.get_files():
			names[f.to_lower()] = [f, false]
		for s in d.get_directories():
			names[s.to_lower()] = [s, true]
	_real[dir] = names
	return names
