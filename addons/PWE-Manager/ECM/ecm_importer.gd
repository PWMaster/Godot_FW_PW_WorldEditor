@tool
extends RefCounted

# ====================================================
# Import aus den Spieldaten (Leiste ECM-GFX-MAP) als Szenen unter res://ECM_Import/, im selben
# Ordnerpfad wie im Spielordner (z.B. models/npcs/... oder gfx/人物/...). Einzige Quelle sind die
# Spieldaten (Standard res://Stock-PWE-Client, .pck direkt gelesen über angelica_files.gd), auch für
# Texturen, Unter-GFX und Modelle der GFX:
#   .ecm  SkinModelPath -> .smd (auf .fbx umbenannte Pfade werden auf die .smd zurückgeführt)
#         Skins: die der .smd und AddiSkinPath ("Models\" + Pfad, wie CECModel::Load)
#         CoGfx: die GFX, die dauerhaft an Hooks des Modells hängen, samt Blitz-Endpunkten an Hooks
#                (ecm_cogfx.gd, ecm_cogfx_param.gd)
#   .gfx  Datei-Node samt Elementen (gfx_parser.gd, create_id_200.gd) als Wurzel der Szene
#   .smd  Modelle der GFX (Element 160) wie das Modell einer .ecm, als <SMD>_model.tscn
#   .trn2 Map (maps\<map>\): Terrain, Gebäude (litmodels\<map>\), Wasser und Objekte (Effekte,
#         ECModelle, Sounds aus <map>.ecwld), als <map>.tscn
#         (angelica_terrain.gd, angelica_buildings.gd, angelica_world.gd)
# Die GFX-Elemente holen Texturen, Unter-GFX, Modelle, ECModelle und Klänge über gfx_sources.gd
# von hier (source_*), wie Angelica: gfx\textures\<TexFile>, gfx\<GfxPath>,
# gfx\models\<ModelPath>, ECMPath relativ zum Spielordner, sfx\<Path>.
# Spielordner = Ordner mit "models" / "gfx" / "textures" / "building" / "litmodels" / "maps" / "sfx" darin. Die Daten können mehrere haben (z.B.
# res://.resources mit gfx und res://.resources/resources mit models und gfx): ein Pfad gilt
# zuerst im Spielordner der Datei, die ihn nennt, dann in den anderen.
# Gespeichert werden <ECM>.tscn / <GFX>.tscn, <SMD>_actions.res (Animationen, von allen ECMs der
# .smd geteilt), <SKI>_mesh.res und die Texturen (.dds unverändert kopiert).
# Aktions-Ereignisse liest read_ecm (actions[].events: GFX 100, Sound 101, Angriffspunkt 104), der
# Import setzt sie noch nicht um; Kind-Modelle der .ecm fehlen noch.
# build_ecm() baut eine .ecm ohne zu speichern (Laufzeit, z.B. NPCs ohne importierte Szene).
# runtime = true (Spiel zur Laufzeit): nichts wird geschrieben, Texturen, Klänge und Unter-Szenen
# bleiben im Speicher; gfx_scene() liefert dann eine GFX als PackedScene (z.B. Angriffs-Effekte).
# ====================================================

const OUT_ROOT = "res://ECM_Import"
# Abschnitte nach den CoGfx (CECModelStaticData::LoadData): ab hier sind Ereignisse keine CoGfx mehr
const AFTER_COGFX = ["CombineActName", "ECMHookCount", "AddiSkinCount", "ChildCount", "ScriptCount", "PhysFileName"]
const ACTION_EVENTS = [100, 101, 104] # GFX, Sound, Angriffspunkt (EVENT_TYPE_*)
const ROOT_MARKERS = ["models", "gfx", "textures", "building", "litmodels", "maps", "sfx"]
const SMD_SCENE_SUFFIX = "_model.tscn"
const Sources = preload("../GFX/gfx_sources.gd")
const Builder = preload("angelica_model_builder.gd")
const Parser = preload("../GFX/gfx_parser.gd")

var files # angelica_files.gd, root = Spielordner des Modells, das gerade gebaut wird
var reader # angelica_model_reader.gd
var data_root = "res://Stock-PWE-Client"
var warnings: Array = [] # Hinweise des laufenden Imports (samt verschachtelter)
var written: Array = [] # geschriebene Dateien des laufenden Imports (für EditorFileSystem.update_file)
var _game_roots: Array = []
var _context_root = "" # Spielordner der Datei, die gerade importiert wird
var _stack: Array = [] # verschachtelte Importe: [Datei, Spielordner davor, files.root davor]
var _cache = {} # je Import einmal gebaut: Quelle -> PackedScene / Texture2D
var _tex_builder = null # lädt die Texturen der GFX
var runtime = false # nichts schreiben (siehe oben)


func _init(p_data_root: String = "res://Stock-PWE-Client") -> void:
	data_root = p_data_root.trim_suffix("/")
	files = preload("../Data/angelica_files.gd").new(data_root)
	reader = preload("angelica_model_reader.gd").new(files)

func warn(msg: String) -> void:
	if not msg in warnings:
		warnings.append(msg)


# ====================================================
# SPIELORDNER + ZIELPFADE
# ====================================================
# Zielpfad im Projekt für eine Datei der Spieldaten ("" = außerhalb der Spieldaten)
func out_path(src: String, new_ext: String = "") -> String:
	var root = root_of(src)
	if root == "":
		return ""
	var rel = src.substr(root.length() + 1)
	return OUT_ROOT.path_join(rel.get_basename() + new_ext if new_ext != "" else rel)

# Spielordner einer Datei: der Ordner über dem ersten Eintrag aus ROOT_MARKERS in ihrem Pfad, sonst der
# Datenordner (fallback = false: ""). "" auch außerhalb der Daten.
func root_of(path: String, fallback: bool = true) -> String:
	if not path.begins_with(data_root + "/"):
		return ""
	var dir = data_root
	var parts = path.substr(data_root.length() + 1).split("/")
	for i in parts.size() - 1:
		if parts[i].to_lower() in ROOT_MARKERS:
			return dir
		dir = dir.path_join(parts[i])
	return data_root if fallback else ""

# Alle Spielordner der Daten: der Datenordner und seine Unterordner mit einem ROOT_MARKERS-Ordner darin
# (nicht etwa "gfx" selbst, in dem gfx\models liegt)
func game_roots() -> Array:
	if _game_roots.is_empty():
		var dirs = [data_root]
		for d in files.list_dir(data_root)["dirs"]:
			if not d.to_lower() in ROOT_MARKERS:
				dirs.append(data_root.path_join(d))
		for dir in dirs:
			for marker in ROOT_MARKERS:
				var sub = files.resolve(marker, dir)
				if sub != "" and files.dir_exists(sub):
					_game_roots.append(dir)
					break
	return _game_roots

# Angelica-Pfad relativ zum Spielordner -> Datei, zuerst im Spielordner der laufenden Datei
func find_game_file(rel: String) -> String:
	var roots = []
	for r in [_context_root] + game_roots():
		if r != "" and not r in roots:
			roots.append(r)
	for r in roots:
		var p = files.resolve(rel, r)
		if p != "" and files.file_exists(p):
			return p
	return ""

# Wie find_game_file, aber für einen Ordner
func find_game_dir(rel: String) -> String:
	var roots = []
	for r in [_context_root] + game_roots():
		if r != "" and not r in roots:
			roots.append(r)
	for r in roots:
		var p = files.resolve(rel, r)
		if p != "" and files.dir_exists(p):
			return p
	return ""

# Verschachtelte Importe (GFX -> Modell / ECModel): der äußerste setzt die Quelle für die
# GFX-Elemente (gfx_sources.gd) und sammelt alle Hinweise
func _enter(path: String) -> void:
	if _stack.is_empty():
		warnings = []
		written = []
		_cache.clear()
		_tex_builder = null
		Sources.begin(self)
	_stack.append([path, _context_root, files.root])
	_context_root = root_of(path)

func _leave() -> void:
	var top = _stack.pop_back()
	_context_root = top[1]
	files.root = top[2]
	if _stack.is_empty():
		Sources.end()
		Parser.release_decoder()
		_cache.clear()
		_tex_builder = null # hält über texture_dest den Importer: Zyklus auflösen

func _in_progress(path: String) -> bool:
	for s in _stack:
		if s[0] == path:
			return true
	return false


# ====================================================
# .ecm (Textform, CECModelStaticData::LoadData)
# ====================================================
func read_ecm(path: String) -> Dictionary:
	if files.get_bytes(path).slice(0, 4).get_string_from_ascii() == "MOXB":
		return {"error": path.get_file() + ": binäre .ecm wird noch nicht unterstützt"}
	# CoGfx: die ersten CoGfxNum Ereignisse (je ab "EventType:") vor den Aktionen,
	# je {"type": EventType, "files": [FxFilePath], "params": [GfxParam], Schlüssel: Wert (erster Wert)},
	# GfxParam (ModActParam::Load) = {"ele": ParamEleName, "ParamId": ..., "ParamDataHook": ...}
	# actions: kombinierte Aktionen [{"name": CombineActName, "base": [BaseActName], "events": [...]}],
	# events: {"type": 100 GFX / 101 Sound / 104 Angriffspunkt, "start": StartTime ms, "files":
	# [FxFilePath], "hook": HookName, "atk": AtkPath (relativ zu gfx\SkillAttack\), dazu die übrigen
	# Schlüssel als Text (erster Wert): TimeSpan, HookOffset, BindParent, FadeOut, GfxScale, VolMin ...}
	var out = {"path": path, "skin_model": "", "addi_skins": [], "cogfx": [], "actions": []}
	var cogfx_num = 0
	var ev = null
	var aev = null # Ereignis der laufenden kombinierten Aktion
	for line in files.read_lines(path):
		var colon = line.find(":")
		if colon < 0:
			continue
		var key = line.substr(0, colon).strip_edges()
		var value = line.substr(colon + 1).strip_edges()
		if key in AFTER_COGFX:
			cogfx_num = 0
			ev = null
			aev = null
		match key:
			"SkinModelPath":
				out["skin_model"] = value
			"AddiSkinPath":
				out["addi_skins"].append(value)
			"CoGfxNum":
				cogfx_num = value.to_int()
			"CombineActName":
				out["actions"].append({"name": value, "base": [], "events": []})
				aev = null
			"BaseActName":
				if not out["actions"].is_empty():
					out["actions"][-1]["base"].append(value)
			"EventType":
				ev = null
				aev = null
				if out["cogfx"].size() < cogfx_num:
					ev = {"type": value.to_int(), "files": [], "params": []}
					out["cogfx"].append(ev)
				elif not out["actions"].is_empty() and value.to_int() in ACTION_EVENTS:
					aev = {"type": value.to_int(), "start": 0, "files": [], "hook": "", "atk": ""}
					out["actions"][-1]["events"].append(aev)
			"FxFilePath":
				if ev != null:
					ev["files"].append(value)
				elif aev != null:
					aev["files"].append(value)
			"StartTime":
				if aev != null:
					aev["start"] = value.to_int()
				elif ev != null and not ev.has(key):
					ev[key] = value
			"HookName":
				if aev != null:
					aev["hook"] = value
				elif ev != null and not ev.has(key):
					ev[key] = value
			"AtkPath":
				if aev != null:
					aev["atk"] = value
			"ParamEleName":
				if ev != null:
					ev["params"].append({"ele": value})
			_:
				if aev != null:
					if not aev.has(key): # TimeSpan, HookOffset, BindParent, FadeOut, GfxScale, VolMin ... (Text)
						aev[key] = value
				elif ev == null:
					pass
				elif key == "ParamId" or key.begins_with("ParamData"):
					if not ev["params"].is_empty():
						ev["params"][-1][key] = value
				elif not ev.has(key):
					ev[key] = value
	return out


# Angriffspunkte der kombinierten Aktionen einer read_ecm(): {Aktion: [[StartTime ms, AtkPath], ...]}
# (nur Aktionen mit Angriffspunkt, zeitlich sortiert)
static func attack_points(ecm: Dictionary) -> Dictionary:
	var out = {}
	for a in ecm.get("actions", []):
		var pts = []
		for e in a.get("events", []):
			if int(e["type"]) == 104 and str(e["atk"]) != "":
				pts.append([int(e["start"]), str(e["atk"])])
		if not pts.is_empty():
			pts.sort_custom(func(x, y): return x[0] < y[0])
			out[a["name"]] = pts
	return out

# GFX- und Klang-Ereignisse (100 / 101) der kombinierten Aktionen einer read_ecm(): {Aktion: [Ereignis, ...]}
static func action_events(ecm: Dictionary) -> Dictionary:
	var out = {}
	for a in ecm.get("actions", []):
		var evs = a.get("events", []).filter(func(e): return int(e["type"]) in [100, 101] and not e["files"].is_empty())
		if not evs.is_empty():
			out[a["name"]] = evs
	return out


# ====================================================
# IMPORT
# ====================================================
# -> {"scene": res://-Pfad, "warnings": [...]} oder {"error": ...}
func import_ecm(ecm_path: String) -> Dictionary:
	if _in_progress(ecm_path):
		return {"error": ecm_path.get_file() + " enthält sich selbst"}
	_enter(ecm_path)
	var res = _import_ecm(ecm_path)
	_leave()
	return res

func _import_ecm(ecm_path: String) -> Dictionary:
	var scene_path = out_path(ecm_path, ".tscn")
	if scene_path == "":
		return {"error": ecm_path + " liegt nicht in den Spieldaten " + data_root}
	var builder = _new_builder()
	var model = prepare(ecm_path, builder.warnings)
	if model.has("error"):
		return model
	var smd_path = model["smd"]["path"]
	var built = builder.build(_node_name(ecm_path.get_file().get_basename()), model["smd"], model["skins"])
	_take_warnings(builder)
	if built.has("error"):
		return built
	var root: Node3D = built["root"]
	root.set_meta("ecm_path", ecm_path)
	root.set_meta("smd_path", smd_path)
	var cogfx = preload("ecm_cogfx.gd").new(files, warnings)
	cogfx.build(root, root.get_node("Skeleton3D"), builder.hook_bones, model["ecm"]["cogfx"])
	return _save_model(root, built, smd_path, scene_path)

# .ecm nur im Speicher bauen (schreibt nichts, Texturen direkt aus den Spieldaten), für Figuren zur
# Laufzeit, deren Szene nicht importiert ist. Ohne CoGfx (die bräuchten importierte GFX).
# -> {"root": Node3D mit Skeleton3D und AnimationPlayer, Owner gesetzt} oder {"error": ...}
func build_ecm(ecm_path: String) -> Dictionary:
	var builder = Builder.new(files, reader, func(_src): return "")
	builder.extra_roots = game_roots()
	var model = prepare(ecm_path, builder.warnings)
	if model.has("error"):
		return model
	var built = builder.build(_node_name(ecm_path.get_file().get_basename()), model["smd"], model["skins"])
	_take_warnings(builder)
	if built.has("error"):
		return built
	built["root"].set_meta("ecm_path", ecm_path)
	return {"root": built["root"]}

# Modell einer GFX (A3DGFXModel: gfx\Models\<ModelPath>) -> Szene <SMD>_model.tscn
func import_smd(smd_path: String) -> Dictionary:
	if _in_progress(smd_path):
		return {"error": smd_path.get_file() + " enthält sich selbst"}
	_enter(smd_path)
	var res = _import_smd(smd_path)
	_leave()
	return res

func _import_smd(smd_path: String) -> Dictionary:
	var scene_path = out_path(smd_path, SMD_SCENE_SUFFIX)
	if scene_path == "":
		return {"error": smd_path + " liegt nicht in den Spieldaten " + data_root}
	files.root = root_of(smd_path)
	var builder = _new_builder()
	var model = prepare_smd(smd_path, [], builder.warnings)
	if model.has("error"):
		return model
	var built = builder.build(_node_name(smd_path.get_file().get_basename()), model["smd"], model["skins"])
	_take_warnings(builder)
	if built.has("error"):
		return built
	built["root"].set_meta("smd_path", smd_path)
	return _save_model(built["root"], built, smd_path, scene_path)

# .gfx -> Szene <GFX>.tscn: der Datei-Node (gfx_data_node.gd) ist die Wurzel, darunter die Elemente
func import_gfx(gfx_path: String) -> Dictionary:
	var scene_path = out_path(gfx_path, ".tscn")
	if scene_path == "":
		return {"error": gfx_path + " liegt nicht in den Spieldaten " + data_root}
	if not files.file_exists(gfx_path):
		return {"error": gfx_path + " nicht gefunden"}
	_enter(gfx_path)
	var node = build_gfx(gfx_path, _node_name(gfx_path.get_file().get_basename()))
	for child in node.get_children():
		_set_owner(child, node)
	var packed = PackedScene.new()
	var err = packed.pack(node)
	if err == OK:
		err = _save(packed, scene_path)
	node.free()
	_leave()
	if err != OK:
		return {"error": "Speichern fehlgeschlagen (%s)" % error_string(err)}
	if runtime:
		return {"packed": packed, "warnings": warnings}
	return {"scene": scene_path, "warnings": warnings, "written": written}

# GfxPath (relativ zu gfx\) -> Szene der GFX; mit runtime nur im Speicher gebaut, null = fehlt
func gfx_scene(gfx_path: String) -> PackedScene:
	var src = find_game_file("gfx/" + gfx_path.strip_edges())
	if src == "" or src.get_extension().to_lower() != "gfx":
		warn("GFX " + gfx_path + " nicht in den Spieldaten")
		return null
	var res = import_gfx(src)
	if res.has("error"):
		warn(res["error"])
		return null
	return res["packed"] if res.has("packed") else load(res["scene"]) as PackedScene

# Terrain einer Map (.trn2 in maps\<map>\) -> Szene <map>.tscn
func import_map(trn2_path: String) -> Dictionary:
	var scene_path = out_path(trn2_path, ".tscn")
	if scene_path == "":
		return {"error": trn2_path + " liegt nicht in den Spieldaten " + data_root}
	if not files.file_exists(trn2_path):
		return {"error": trn2_path + " nicht gefunden"}
	_enter(trn2_path)
	var res = preload("../MAP/angelica_terrain.gd").new(self).build(trn2_path, scene_path)
	_leave()
	if res.has("error"):
		return res
	res["warnings"] = warnings # dazu die Anzahlen (Bereiche, Gebäude, Effekte ...)
	res["written"] = written
	return res

# Datei-Node einer .gfx samt Elementen und deren Godot-Nodes (nicht in der Szene)
func build_gfx(gfx_path: String, node_name: String) -> Node3D:
	var skipped = []
	var node = Parser.new().build_file_node(gfx_path, node_name, skipped)
	for raw_id in skipped:
		warn(gfx_path.get_file() + ": unbekannte Element-ID " + str(raw_id) + " übersprungen")
	var creator = load(get_script().resource_path.get_base_dir().path_join("../GFX/create_id_200.gd")).new()
	creator.build_elements(node)
	creator.free()
	return node

func new_builder():
	return _new_builder()

func _new_builder():
	var builder = Builder.new(files, reader, (func(_src): return "") if runtime else (func(src): return out_path(src)))
	builder.extra_roots = game_roots()
	return builder

func take_builder(builder) -> void:
	_take_warnings(builder)

func _take_warnings(builder) -> void:
	for w in builder.warnings:
		warn(w)
	builder.warnings.clear()
	for f in builder.written:
		if not f in written:
			written.append(f)
	builder.written.clear()

# Geteilte Ressourcen als eigene Dateien, dann die Szene
func _save_model(root: Node3D, built: Dictionary, smd_path: String, scene_path: String) -> Dictionary:
	var err = _save(built["actions"], out_path(smd_path, "_actions.res"))
	for mi in root.get_node("Skeleton3D").get_children():
		if mi is MeshInstance3D and err == OK:
			err = _save(mi.mesh, out_path(mi.get_meta("ski_path", ""), "_mesh.res") if mi.has_meta("ski_path") else "")
	var packed = PackedScene.new()
	if err == OK:
		err = packed.pack(root)
	if err == OK:
		err = _save(packed, scene_path)
	root.free()
	if err != OK:
		return {"error": "Speichern fehlgeschlagen (%s)" % error_string(err)}
	if runtime:
		return {"packed": packed, "warnings": warnings}
	return {"scene": scene_path, "warnings": warnings, "written": written}

# .ecm -> {"ecm": read_ecm(), "smd": read_smd(), "skins": [read_ski()]} oder {"error": ...}; Hinweise in warn_list
func prepare(ecm_path: String, warn_list: Array) -> Dictionary:
	var ecm = read_ecm(ecm_path)
	if ecm.has("error"):
		return ecm
	if ecm["skin_model"] == "":
		return {"error": ecm_path.get_file() + ": kein SkinModelPath"}
	var roots = _model_roots(ecm_path)
	var smd_path = _find_model(ecm["skin_model"], ecm_path, roots)
	if smd_path == "":
		return {"error": ecm_path.get_file() + ": Modell " + ecm["skin_model"] + " nicht gefunden (gesucht in " + ", ".join(roots) + ")"}
	var model = prepare_smd(smd_path, ecm["addi_skins"], warn_list)
	if not model.has("error"):
		model["ecm"] = ecm
	return model

# .smd -> {"smd": read_smd(), "skins": [read_ski()]} oder {"error": ...}
func prepare_smd(smd_path: String, addi_skins: Array, warn_list: Array) -> Dictionary:
	var smd = reader.read_smd(smd_path)
	if smd.has("error"):
		return smd
	var skins = []
	var ski_paths = []
	for rel in smd["skins"]:
		if rel != "":
			ski_paths.append(files.resolve(rel, smd_path.get_base_dir()))
	for rel in addi_skins:
		ski_paths.append(files.resolve("Models/" + rel))
	if ski_paths.is_empty():
		# Weder .smd noch .ecm nennen einen Skin (setzt im Spiel die NPC-Vorlage): gleichnamige .ski
		var guess = files.resolve(smd_path.get_file().get_basename() + ".ski", smd_path.get_base_dir())
		if guess != "":
			ski_paths.append(guess)
			warn_list.append("kein Skin angegeben, " + guess.get_file() + " aus dem Ordner verwendet")
	var ski_names = smd["skins"].filter(func(s): return s != "") + addi_skins
	for i in ski_paths.size():
		if ski_paths[i] == "":
			warn_list.append("Skin nicht gefunden: " + ski_names[i])
			continue
		if ski_paths.find(ski_paths[i]) < i:
			continue # AddiSkin = Skin der .smd: nicht doppelt
		var ski = reader.read_ski(ski_paths[i])
		if ski.has("error"):
			warn_list.append(ski["error"])
		else:
			skins.append(ski)
	if smd["hangers"] > 0:
		warn_list.append(smd_path.get_file() + ": Hanger werden nicht unterstützt")
	return {"smd": smd, "skins": skins}

# SkinModelPath ist relativ zum Spielordner: zuerst der der .ecm (liegt sie in keinem "models" /
# "gfx", die Ordner von ihr aufwärts), dann die anderen Spielordner der Daten, z.B. eine .ecm in
# .resources/gfx/models mit ihrem Modell in .resources/resources/models.
func _model_roots(ecm_path: String) -> Array:
	var roots = []
	var own = root_of(ecm_path, false)
	if own != "":
		roots.append(own)
	else:
		var dir = ecm_path.get_base_dir()
		while dir.begins_with(data_root):
			roots.append(dir)
			if dir == data_root:
				break
			dir = dir.get_base_dir()
	for r in game_roots():
		if not r in roots:
			roots.append(r)
	return roots

# Erster Spielordner, unter dem SkinModelPath (bzw. die .smd dazu) liegt; er wird files.root.
# Ein reiner Dateiname liegt sonst neben der .ecm (CECModel::Load).
func _find_model(skin_model: String, ecm_path: String, roots: Array) -> String:
	for dir in roots:
		for rel in [skin_model, skin_model.get_basename() + ".smd"]:
			var p = files.resolve(rel, dir)
			if p != "" and p.get_extension().to_lower() == "smd":
				files.root = dir
				return p
	# Nicht im Spiel, aber in den Daten: Kopien unter gfx\models nennen teils einen Models\-Pfad,
	# den es nicht gibt, die .smd liegt neben der .ecm
	var p = files.resolve(skin_model.replace("\\", "/").get_file().get_basename() + ".smd", ecm_path.get_base_dir())
	if p != "":
		files.root = root_of(ecm_path)
		if skin_model.find("\\") >= 0 or skin_model.find("/") >= 0:
			warn(ecm_path.get_file() + ": Modell " + skin_model + " fehlt, " + p.get_file() + " neben der .ecm verwendet")
		return p
	return ""


# ====================================================
# QUELLE DER GFX-ELEMENTE (gfx_sources.gd, nur während eines Imports)
# ====================================================
# GfxPath (Unter-GFX, CoGfx) -> .gfx, "" = fehlt
func source_gfx(gfx_path: String) -> String:
	var p = find_game_file("gfx/" + gfx_path.strip_edges())
	if p == "" or p.get_extension().to_lower() != "gfx":
		warn("GFX " + gfx_path + " nicht in den Spieldaten")
		return ""
	return p

# GfxPath -> importierte Szene der .gfx (je Import einmal), null = fehlt
func source_gfx_scene(gfx_path: String) -> PackedScene:
	var src = source_gfx(gfx_path)
	return null if src == "" else _scene_of(src, import_gfx)

# TexFile -> Textur (kopiert bzw. umgewandelt wie die Modell-Texturen), null = fehlt
func source_texture(tex_path: String) -> Texture2D:
	var key = "tex:" + tex_path.to_lower()
	if _cache.has(key):
		return _cache[key]
	var tex: Texture2D = null
	var src = find_game_file("gfx/textures/" + tex_path)
	if src == "":
		warn("Textur " + tex_path + " nicht in den Spieldaten (gfx\\textures)")
	elif src.get_extension().to_lower() == "sdr":
		warn("Textur " + tex_path + " ist ein Shader (.sdr), wird nicht unterstützt")
	else:
		if _tex_builder == null:
			_tex_builder = _new_builder()
		tex = _tex_builder.texture_file(src, "Textur " + tex_path)
		_take_warnings(_tex_builder)
	_cache[key] = tex
	return tex

# Path eines GFX-Sounds (A3DGFXSound: sfx\<Path>) -> AudioStreamWAV (ohne Schleife), gespeichert als
# <Datei>_sfx.res (die Umgebungsklänge der Maps liegen als <Datei>.res mit Schleife daneben),
# null = fehlt; nur .wav (die Spieldaten haben nur .wav)
func source_sound(sound_path: String) -> AudioStream:
	var key = "sfx:" + sound_path.strip_edges().to_lower()
	if _cache.has(key):
		return _cache[key]
	var stream: AudioStreamWAV = null
	var src = find_game_file("sfx/" + sound_path.strip_edges())
	if src == "":
		warn("Sound sfx\\" + sound_path + " nicht in den Spieldaten")
	elif src.get_extension().to_lower() != "wav":
		warn("Sound " + sound_path + ": nur .wav wird unterstützt")
	else:
		stream = AudioStreamWAV.load_from_buffer(wav_bytes(src))
		if stream == null:
			warn("Sound " + sound_path + " nicht lesbar")
		elif _save(stream, out_path(src, "_sfx.res")) != OK:
			warn("Sound " + sound_path + " nicht gespeichert")
	_cache[key] = stream
	return stream

# .wav nur mit "fmt " und "data": Godot meldet sonst Fehler bei den Metadaten der Spieldateien
# (GBK-Text in LIST / INFO, "bext" ungerader Länge ohne Füllbyte am Dateiende)
func wav_bytes(path: String) -> PackedByteArray:
	var b = files.get_bytes(path)
	if b.size() < 12 or b.slice(0, 4).get_string_from_ascii() != "RIFF" or b.slice(8, 12).get_string_from_ascii() != "WAVE":
		return b
	var out = b.slice(0, 12)
	var p = 12
	while p + 8 <= b.size():
		var id = b.slice(p, p + 4).get_string_from_ascii()
		var n = b.decode_u32(p + 4)
		if id == "fmt " or id == "data":
			var chunk = b.slice(p, mini(p + 8 + n + (n & 1), b.size()))
			chunk.resize(8 + n + (n & 1))
			out.append_array(chunk)
		p += 8 + n + (n & 1)
	out.encode_u32(4, out.size() - 8)
	return out

# ModelPath (A3DGFXModel: gfx\Models\<ModelPath>, .smd) -> Szene, null = fehlt
func source_model(model_path: String) -> PackedScene:
	var src = find_game_file("gfx/models/" + model_path.strip_edges())
	if src == "":
		src = find_game_file("gfx/models/" + model_path.strip_edges().get_basename() + ".smd")
	if src == "" or src.get_extension().to_lower() != "smd":
		warn("GFX-Modell " + model_path + " nicht in den Spieldaten (gfx\\models)")
		return null
	return _scene_of(src, import_smd)

# ECMPath (A3DGFXECModel, relativ zum Spielordner) -> {"scene": Szene oder null, "ecm": Pfad oder ""}
func source_ecm(ecm_path: String) -> Dictionary:
	var src = find_game_file(ecm_path.strip_edges())
	if src == "" or src.get_extension().to_lower() != "ecm":
		warn("ECModel " + ecm_path + " nicht in den Spieldaten")
		return {"scene": null, "ecm": ""}
	return {"scene": _scene_of(src, import_ecm), "ecm": src}

func _scene_of(src: String, importer: Callable) -> PackedScene:
	if _cache.has(src):
		return _cache[src]
	var scene: PackedScene = null
	var res = importer.call(src)
	if res.has("error"):
		warn(res["error"])
	elif res.has("packed"):
		scene = res["packed"]
	else:
		scene = load(res["scene"]) as PackedScene
	_cache[src] = scene
	return scene


# ====================================================
# HILFEN
# ====================================================
func save_resource(res: Resource, path: String) -> int:
	return _save(res, path)

func _save(res: Resource, path: String) -> int:
	if runtime:
		return OK # bleibt im Speicher
	if path == "":
		return ERR_FILE_BAD_PATH
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	res.take_over_path(path)
	if not path in written:
		written.append(path)
	var err = ResourceSaver.save(res, path)
	if err == OK:
		Builder.register_uid(path)
	return err

func _set_owner(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		_set_owner(child, owner)

func _node_name(n: String) -> String:
	for c in [".", ":", "@", "/", "\"", "%"]:
		n = n.replace(c, "_")
	return n if n != "" else "ECM"
