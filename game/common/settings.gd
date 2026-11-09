extends RefCounted

# ====================================================
# Einstellungen in user://settings.cfg, Abschnitte [client] und [server] (DEFAULTS).
# Werte von der Kommandozeile nach "--" (z.B. --port=29001 --dtls) gehen vor und gelten nur für
# diesen Start; save() schreibt nur, was mit set_value gesetzt wurde.
# ====================================================

const FILE = "user://settings.cfg"
const DEFAULTS = {
	"client": {
		"host": "127.0.0.1",
		"port": 29000,
		"language": "Deu", # Deu / Eng / Franz (Ordner der Spieldaten)
		"data_root": "res://Stock-PWE-Client", # Spieldaten (Oberfläche, Modelle)
		"maps_root": "res://ECM_Import/maps", # importierte Maps (Leiste ECM-GFX-MAP): <map>/<map>.tscn
		"account": "",
		"remember": true, # Kontoname merken (Login "Merken")
		"dtls": false,
		"dtls_cert": "", # Zertifikat des Servers (dtls.crt); leer = verschlüsselt, aber ungeprüft
		"ui_skin": 2, # Spiel-Oberfläche: 2 = <2>gameui (neuer), 1 = 1gameui ("Fenster wechseln" im Systemmenü)
	},
	"server": {
		"port": 29000,
		"bind": "*",
		"max_clients": 64,
		"dir": "user://server", # Log, Status, Stopp-Datei, DTLS-Schlüssel (Tests: eigener Ordner)
		"database": "", # leer = <dir>/game.db
		"maps": "", # Spawns nur dieser Maps laden (z.B. "s9,s10"), leer = alle
		"dtls": false,
	},
}

var section: String
var _path: String
var _cfg = ConfigFile.new()
var _args: Dictionary


func _init(p_section: String, path: String = FILE) -> void:
	section = p_section
	_path = path
	_cfg.load(path)
	_args = user_args()

func value(key: String) -> Variant:
	var def = DEFAULTS[section][key]
	if _args.has(key):
		return _convert(_args[key], def)
	return _convert(_cfg.get_value(section, key, def), def)

func set_value(key: String, v: Variant) -> void:
	_cfg.set_value(section, key, v)

func save() -> Error:
	DirAccess.make_dir_recursive_absolute(_path.get_base_dir())
	return _cfg.save(_path)

static func _convert(v: Variant, def: Variant) -> Variant:
	match typeof(def):
		TYPE_BOOL:
			if v is String:
				return v.to_lower() in ["1", "true", "ja", "yes", "on"]
			return bool(v)
		TYPE_INT:
			return v.to_int() if v is String else int(v)
		TYPE_FLOAT:
			return v.to_float() if v is String else float(v)
	return str(v)

# Kommandozeile nach "--" als {Schlüssel: Wert} (--port=29000 -> {"port": "29000"}, --dtls -> {"dtls": "true"})
static func user_args() -> Dictionary:
	var out = {}
	for a in OS.get_cmdline_user_args():
		var s: String = a.trim_prefix("--")
		var eq = s.find("=")
		if eq >= 0:
			out[s.left(eq)] = s.substr(eq + 1)
		else:
			out[s] = "true"
	return out
