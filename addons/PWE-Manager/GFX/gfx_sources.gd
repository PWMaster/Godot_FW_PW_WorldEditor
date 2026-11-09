@tool
extends RefCounted

# ====================================================
# Woher die GFX-Elemente Texturen, Unter-GFX, Modelle und Klänge holen: immer aus den Spieldaten,
# Pfade wie in Angelica: gfx\textures\<TexFile>, gfx\<GfxPath>, gfx\models\<ModelPath> (.smd ->
# Szene wie beim ECM-Import), ECMPath relativ zum Spielordner, sfx\<Path> (.wav).
#  - Während eines Imports (Leiste ECM-GFX-MAP; ecm_importer.gd ruft begin() / end()) über diesen
#    Import: Hinweise landen dort.
#  - Sonst ("GFX Ausführen" aus res://GFX_Load, Erstell-Knöpfe, "Unter-GFX neu laden") über einen
#    eigenen Importer auf dem Spieldaten-Ordner der Leiste ECM-GFX-MAP (Projekt-Metadaten
#    ecm_gfx_panel / root, Standard DEFAULT_ROOT); take_written() / take_warnings() holen seine
#    geschriebenen Dateien und Hinweise ab, release() gibt ihn frei (Plugin beenden).
# Was dabei entsteht (Texturen, Modell-Szenen ...), liegt wie beim Import unter res://ECM_Import/.
# ====================================================

const DEFAULT_ROOT = "res://Stock-PWE-Client"
const IMPORTER = "res://addons/PWE-Manager/ECM/ecm_importer.gd"

static var _importer: WeakRef = null
static var _default = null # eigener Importer außerhalb eines Imports


static func begin(importer) -> void:
	_importer = weakref(importer)

static func end() -> void:
	_importer = null

# Eigenen Importer freigeben (sonst hielte er Skripte und Ressourcen bis zum Beenden fest)
static func release() -> void:
	_default = null

# Spieldaten-Ordner der Leiste ECM-GFX-MAP (außerhalb des Editors DEFAULT_ROOT)
static func data_root() -> String:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var settings = Engine.get_singleton(&"EditorInterface").get_editor_settings()
		return str(settings.get_project_metadata("ecm_gfx_panel", "root", DEFAULT_ROOT)).trim_suffix("/")
	return DEFAULT_ROOT

static func _running():
	return _importer.get_ref() if _importer != null else null

# Laufender Import, sonst der eigene Importer; null, wenn der Spieldaten-Ordner fehlt
static func importer():
	var imp = _running()
	if imp != null:
		return imp
	var root = data_root()
	if _default == null or _default.data_root != root:
		_default = load(IMPORTER).new(root) if DirAccess.dir_exists_absolute(root) else null
	return _default

static func active() -> bool:
	return importer() != null

# Vom eigenen Importer geschriebene Dateien (für EditorFileSystem.update_file) und Hinweise
static func take_written() -> Array:
	if _default == null:
		return []
	var out = _default.written.duplicate()
	_default.written.clear()
	return out

static func take_warnings() -> Array:
	if _default == null:
		return []
	var out = _default.warnings.duplicate()
	_default.warnings.clear()
	return out

# TexFile der .gfx -> Textur, null = fehlt (Hinweis)
static func texture(tex_path) -> Texture2D:
	var raw = str(tex_path).strip_edges()
	if raw == "":
		return null
	var imp = importer()
	if imp == null:
		warn("Textur " + raw + ": keine Spieldaten (" + data_root() + ")")
		return null
	return imp.source_texture(raw)

# GfxPath (relativ zum gfx-Ordner) -> .gfx-Datei, "" = fehlt
static func gfx_file(gfx_path: String) -> String:
	var imp = importer()
	return imp.source_gfx(gfx_path) if imp != null else ""

# ModelPath (relativ zu gfx\Models) -> Szene des Modells, null = fehlt
static func model(model_path: String) -> PackedScene:
	var imp = importer()
	return imp.source_model(model_path) if imp != null else null

# ECMPath -> {"scene": Szene oder null, "ecm": .ecm-Pfad oder ""}
static func ecm(ecm_path: String) -> Dictionary:
	var imp = importer()
	return imp.source_ecm(ecm_path) if imp != null else {"scene": null, "ecm": ""}

# Path (relativ zu sfx\) -> AudioStream, null = fehlt
static func sound(sound_path: String) -> AudioStream:
	var imp = importer()
	return imp.source_sound(sound_path) if imp != null else null

# Hinweis in den laufenden Import, sonst als Warnung
static func warn(msg: String) -> void:
	var imp = _running()
	if imp != null:
		imp.warn(msg)
	else:
		push_warning(msg)
