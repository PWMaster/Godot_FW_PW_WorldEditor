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

func use_imported_pw_client_if_missing() -> void:
	if section != "client":
		return
	var current = str(value("data_root"))
	var absolute = ProjectSettings.globalize_path(current) if current.begins_with("res://") else current
	if DirAccess.dir_exists_absolute(absolute):
		return
	var manifest_path = "res://addons/PWE-Manager/Server/pw_server_import.json"
	if not FileAccess.file_exists(manifest_path):
		return
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	var client_root = str(manifest.get("client_root", "")) if manifest is Dictionary else ""
	if client_root != "" and DirAccess.dir_exists_absolute(client_root):
		set_value("data_root", client_root)
		save()

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

static func server_data_dir() -> String:
	var profile = str(user_args().get("data-profile", "")).strip_edges()
	var root = "res://addons/PWE-Manager/Server"
	return root.path_join(profile) if profile != "" else root

static func server_data_path(file_name: String) -> String:
	return server_data_dir().path_join(file_name)
