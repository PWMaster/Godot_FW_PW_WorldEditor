@tool
extends RefCounted

# ====================================================
# Spielfigur aus den Spieldaten zusammensetzen, zur Laufzeit ohne Speichern (wie
# PlayerUtil::LoadPlayerModel): Körper-.ecm je Rasse / Geschlecht nur als Skelett und Aktionen
# (LSF_NOSKIN), dazu die Skins
#   head   Kopf  <Rasse><m/w>头<Gesicht + 1>-<Maske>.ski
#   hair   Haare <Rasse><m/w>头发<Frisur + 1>.ski
#   body / leg / foot / wrist  Standardkleidung der Klasse (默认_...), fehlt sie: Standard-Mode
# Tabellen in angelica_player_data.json (tools/player_data/). Haut- und Haarfarbe färben wie
# body.sdr / hair.sdr (Textur * Farbfaktor) die Flächen mit der ersten Textur eines Skins:
# Hautfarbe Kopf und Kleidung, Haarfarbe die Haare.
#   var p = PlayerModel.new("res://Stock-PWE-Client")
#   p.build(Rasse, Geschlecht 0 / 1, Klasse, {face, mask, hair, skin, hair_color}[, Aktionen, Ausrüstung])
#         -> "" / Fehler
#   p.root (Node3D mit Skeleton3D und AnimationPlayer), p.set_appearance(...), p.play(Aktion)
# Rasse 1 Mensch, 2 Elf, 3 Zwerg, 4 Steinmensch, 5 Kindred, 6 Wolf; Klasse wie clsconfig.
# Nur die genannten Aktionen werden gebaut (die .smd hat über 300), Standard: Stehen und Leerlauf;
# MOVE_ACTIONS für Figuren in der Welt (Stehen, Gehen, Rennen, Springen), combat_actions(Waffenart)
# dazu Angriff / Treffer / Sterben (PlayerUtil: "普通攻击<1-3>_<Endung>"); die Wurzel trägt als Meta
# ecm_path, smd_path, attack_points ({Aktion: [[ms, .att]]}, Angriffspunkte der .ecm) und action_events
# ({Aktion: [GFX- / Klang-Ereignis]}, ecm_importer.action_events). detach() gibt die fertige Figur ab,
# damit derselbe Bauer (mit seinen gelesenen .smd / .ski) weitere baut; add_actions(Figur, Aktionen)
# baut später weitere Aktionen dazu (Fertigkeiten).
# Ausrüstung (set_equipment, wie PlayerUtil::ChangeEquips): {EQUIP_INDEX: Pfad} mit dem Modell der
# Ausrüstung für Rasse / Klasse / Geschlecht (EQUIPMENT_ESSENCE models[]); .ski an Handgelenk (1),
# Körper (3), Beinen (5), Füßen (7) ersetzt die Standardkleidung dieses Platzes (Hautfarbe wie dort).
# Die Waffe (0) ist {model, left, type}: rechte und linke Waffe (models[] file_model_male / _l, z.B.
# zwei Dolche des Assassinen) und Waffenart (action_type); sie hängen wie CECPlayer::ChangeEquips mit
# ihrem Hook CC_weapon an HH_righthandweapon / HH_lefthandweapon der Figur (AddChildModel) - so drehen
# die Angriffs-Aktionen sie mit (Knochen 右武器 / 左武器, z.B. der wirbelnde Dolch). Außerhalb des
# Kampfes hängen sie an den Ruhe-Haken des Skeletts: HH_背_<Waffenart> (Rücken: Großschwert, Stab,
# Zepter, Harfe, Gewehr, Hammer, Kreuz, Sense), sonst HH_腰_右 / HH_腰_左<Waffenart> (Gürtel: Dolche);
# hat das Skelett keinen, bleibt die Waffe in der Hand. place_weapons(Figur, im Kampf) schaltet um
# (neu gebaut: Ruhe). Gebaute Waffen bleiben im Speicher des Bauers.
# ====================================================

const Importer = preload("ecm_importer.gd")
const Builder = preload("angelica_model_builder.gd")
const DATA_FILE = "angelica_player_data.json"
const SKIN_SLOTS = ["head", "body", "leg", "foot", "wrist"] # Hautfarbe
const IDLE_ACTIONS = ["站立_通用", "休闲_通用"]
const MOVE_ACTIONS = ["站立_通用", "休闲_通用", "行走_通用", "奔跑_通用", "跳跃起_通用", "跳跃循环_通用", "跳跃落地_通用"]
const ONCE_ACTIONS = ["跳跃起_通用", "跳跃落地_通用"] # laufen nicht in Schleife
const ONCE_PREFIXES = ["普通攻击", "受伤", "死亡_"] # ebenso: Angriffe, Treffer, Sterben (死亡循环 = liegen, Schleife)
# Kampf-Aktionen (combat_actions): Endung je Waffenart action_type wie configs\actions_player.txt ("suffix")
const ACTION_SUFFIXES = ["空手", "巨剑", "巨锤", "匕首", "火枪", "法杖", "权杖", "竖琴", "十字", "镰刀", "三叉"]
const FASHION_SLOT = {"body": "upper", "leg": "lower", "foot": "shoe"}
const EQUIP_SKIN_SLOTS = {1: "wrist", 3: "body", 5: "leg", 7: "foot"} # EQUIP_INDEX_* -> Skin-Platz
const WEAPON_INDEX = 0
const WEAPON_HOOK = "HH_righthandweapon"
const WEAPON_LEFT_HOOK = "HH_lefthandweapon"
const WEAPON_CC = "CC_weapon"
const REST_BACK = "HH_背_%s" # Waffenart (ACTION_SUFFIXES)
const REST_WAIST = "HH_腰_%s%s" # Seite (右 / 左), Waffenart

var importer
var data: Dictionary
var warnings: Array = []
var root: Node3D
var skeleton: Skeleton3D
var animation: AnimationPlayer
var race = 0
var gender = 0
var profession = 0
var appearance = {}
var equipment = {} # EQUIP_INDEX -> Pfad (set_equipment)
var weapon: Node3D # BoneAttachment3D mit der Waffe
var weapon_left: Node3D # BoneAttachment3D mit der linken Waffe
var _builder
var _bon: Dictionary
var _meshes = {} # Platz -> MeshInstance3D
var _paths = {} # Platz -> Skin-Pfad
var _smd_cache = {} # .smd-Pfad -> read_smd
var _ski_cache = {} # .ski-Pfad -> read_ski
var _weapon_cache = {} # .ecm-Pfad -> PackedScene oder null
var _bon_cache = {} # .bon-Pfad -> read_bon (add_actions)
var _ecm_cache = {} # .ecm-Pfad -> read_ecm (add_actions)


func _init(data_root: String = "res://Stock-PWE-Client") -> void:
	importer = Importer.new(data_root)
	var script: Script = get_script()
	var d = JSON.parse_string(FileAccess.get_file_as_string(script.resource_path.get_base_dir().path_join(DATA_FILE)))
	data = d if d is Dictionary else {}

func _warn(msg: String) -> void:
	if not msg in warnings:
		warnings.append(msg)

# Gültige Kombinationen (Standardkleidung vorhanden): "<Rasse>_<Klasse>_<m/w>"
func has_class(p_race: int, p_profession: int, p_gender: int) -> bool:
	return data.get("default_skins", {}).has("%d_%d_%s" % [p_race, p_profession, _g(p_gender)])

func build(p_race: int, p_gender: int, p_profession: int, look: Dictionary, actions: Array = IDLE_ACTIONS, equip: Dictionary = {}) -> String:
	free_model()
	race = p_race
	gender = p_gender
	profession = p_profession
	var ecm_rel = data.get("ecm", {}).get(str(race), {}).get(_g(gender), "")
	var ecm_path = importer.find_game_file(ecm_rel) if ecm_rel != "" else ""
	if ecm_path == "":
		return "Modell für Rasse %d / %s fehlt (%s)" % [race, _g(gender), ecm_rel]
	var ecm = importer.read_ecm(ecm_path)
	if ecm.has("error"):
		return ecm["error"]
	var smd_path = importer._find_model(ecm["skin_model"], ecm_path, importer._model_roots(ecm_path))
	if smd_path == "":
		return ecm_path.get_file() + ": Modell " + ecm["skin_model"] + " nicht gefunden"
	if not _smd_cache.has(smd_path):
		_smd_cache[smd_path] = importer.reader.read_smd(smd_path)
	var smd: Dictionary = _smd_cache[smd_path]
	if smd.has("error"):
		return smd["error"]
	var bon_path = importer.files.resolve(smd["bon"], smd_path.get_base_dir())
	_bon = importer.reader.read_bon(bon_path) if bon_path != "" else {"error": "Skelett fehlt"}
	if _bon.has("error"):
		return _bon["error"]
	var only = smd.duplicate()
	only["skins"] = []
	only["actions"] = smd["actions"].filter(func(a): return a["name"] in actions)
	_builder = Builder.new(importer.files, importer.reader, func(_src): return "") # nichts kopieren
	_builder.extra_roots = importer.game_roots()
	var built = _builder.build("Player", only, [])
	if built.has("error"):
		return built["error"]
	root = built["root"]
	skeleton = root.get_node("Skeleton3D")
	animation = root.get_node("AnimationPlayer")
	# Angriffspunkte (Ereignis 104) der gebauten Aktionen, für die Angriffs-Effekte des Spiels
	var points = Importer.attack_points(ecm)
	for a in points.keys():
		if not a in actions:
			points.erase(a)
	root.set_meta("ecm_path", ecm_path)
	root.set_meta("smd_path", smd_path)
	root.set_meta("attack_points", points)
	root.set_meta("action_events", _events_of(ecm, actions))
	for a in actions:
		if animation.has_animation(a):
			animation.get_animation(a).loop_mode = Animation.LOOP_NONE if _once(a) else Animation.LOOP_LINEAR
	for slot in ["body", "leg", "foot", "wrist"]:
		set_skin(slot, _default_skin(slot))
	set_appearance(look)
	if not equip.is_empty():
		set_equipment(equip)
	_take_warnings()
	return ""

# Weitere Aktionen an eine fertige Figur (build / detach) hängen, z.B. die der Fertigkeiten (einmal
# abgespielt): baut nur die fehlenden, ergänzt attack_points / action_events -> Anzahl neu gebaut
func add_actions(figure: Node3D, actions: Array) -> int:
	var ap = figure.get_node_or_null("AnimationPlayer") as AnimationPlayer if figure != null else null
	var sk = figure.get_node_or_null("Skeleton3D") as Skeleton3D if figure != null else null
	var smd_path = str(figure.get_meta("smd_path", "")) if figure != null else ""
	var ecm_path = str(figure.get_meta("ecm_path", "")) if figure != null else ""
	if ap == null or sk == null or smd_path == "" or ecm_path == "":
		return 0
	var missing = actions.filter(func(a): return a != "" and not ap.has_animation(a))
	if missing.is_empty():
		return 0
	if not _smd_cache.has(smd_path):
		_smd_cache[smd_path] = importer.reader.read_smd(smd_path)
	var smd: Dictionary = _smd_cache[smd_path]
	if smd.has("error"):
		return 0
	var bon_path = importer.files.resolve(smd["bon"], smd_path.get_base_dir())
	if not _bon_cache.has(bon_path):
		_bon_cache[bon_path] = importer.reader.read_bon(bon_path) if bon_path != "" else {"error": "Skelett fehlt"}
	var bon: Dictionary = _bon_cache[bon_path]
	if bon.has("error"):
		return 0
	var only = smd.duplicate()
	only["skins"] = []
	only["actions"] = smd["actions"].filter(func(a): return a["name"] in missing)
	if only["actions"].is_empty():
		return 0
	if _builder == null:
		_builder = Builder.new(importer.files, importer.reader, func(_src): return "")
		_builder.extra_roots = importer.game_roots()
	var lib: AnimationLibrary = _builder.build_actions(only, bon, sk)
	var own: AnimationLibrary = ap.get_animation_library("")
	var n = 0
	for a in lib.get_animation_list():
		if not own.has_animation(a):
			var anim = lib.get_animation(a)
			anim.loop_mode = Animation.LOOP_NONE
			own.add_animation(a, anim)
			n += 1
	if not _ecm_cache.has(ecm_path):
		_ecm_cache[ecm_path] = importer.read_ecm(ecm_path)
	var ecm: Dictionary = _ecm_cache[ecm_path]
	var points: Dictionary = figure.get_meta("attack_points", {})
	var all_points = Importer.attack_points(ecm)
	for a in missing:
		if all_points.has(a):
			points[a] = all_points[a]
	figure.set_meta("attack_points", points)
	var events: Dictionary = figure.get_meta("action_events", {})
	events.merge(_events_of(ecm, missing))
	figure.set_meta("action_events", events)
	return n

# GFX- / Klang-Ereignisse der genannten Aktionen
static func _events_of(ecm: Dictionary, actions: Array) -> Dictionary:
	var ev = Importer.action_events(ecm)
	for a in ev.keys():
		if not a in actions:
			ev.erase(a)
	return ev

static func _once(a: String) -> bool:
	if a in ONCE_ACTIONS:
		return true
	for p in ONCE_PREFIXES:
		if a.begins_with(p):
			return true
	return false

# Aktionen einer Figur in der Welt mit Kampf: Bewegung, Treffer, Sterben, Normalangriff 1 - 3,
# Kampfhaltung und Rennen im Kampf (CECPlayer::GetMoveStandAction) unbewaffnet und mit der Waffenart
static func combat_actions(action_type: int) -> Array:
	var out = MOVE_ACTIONS.duplicate()
	out.append_array(["受伤_通用", "死亡_通用", "死亡循环_通用"])
	for suffix in ["空手", suffix_of(action_type)]:
		for a in ["普通攻击1_%s", "普通攻击2_%s", "普通攻击3_%s", "战斗站立_%s", "战斗奔跑_%s"]:
			if not (a % suffix) in out:
				out.append(a % suffix)
	return out

static func suffix_of(action_type: int) -> String:
	return ACTION_SUFFIXES[action_type] if action_type >= 0 and action_type < ACTION_SUFFIXES.size() else ACTION_SUFFIXES[0]

# Standardkleidung der Klasse für einen Platz (fehlt sie: Standard-Mode)
func _default_skin(slot: String) -> String:
	var clothes: Dictionary = data.get("default_skins", {}).get("%d_%d_%s" % [race, profession, _g(gender)], {})
	var p = clothes.get(slot, "")
	if p == "" and FASHION_SLOT.has(slot):
		p = data["fashion"][FASHION_SLOT[slot]].get(str(race), {}).get(_g(gender), "")
	return p

# Ausrüstung anlegen ({EQUIP_INDEX: Pfad}, Waffe {model, left, type} oder nur der Pfad); fehlende
# Plätze bekommen die Standardkleidung zurück
func set_equipment(equip: Dictionary) -> void:
	equipment = equip.duplicate()
	for idx in EQUIP_SKIN_SLOTS:
		var slot: String = EQUIP_SKIN_SLOTS[idx]
		var rel = str(equip.get(idx, ""))
		if not rel.to_lower().ends_with(".ski"):
			rel = _default_skin(slot)
		if rel != _paths.get(slot, ""):
			set_skin(slot, rel)
	set_appearance(appearance)
	var w = equip.get(WEAPON_INDEX, "")
	if not w is Dictionary:
		w = {"model": str(w), "left": "", "type": -1}
	for n in [weapon, weapon_left]:
		if n != null:
			_free(n)
	var suffix = suffix_of(int(w.get("type", -1))) if int(w.get("type", -1)) >= 0 else ""
	weapon = _attach_weapon(str(w.get("model", "")), WEAPON_HOOK, _rest_hook(suffix, "右"), "Waffe")
	weapon_left = _attach_weapon(str(w.get("left", "")), WEAPON_LEFT_HOOK, _rest_hook(suffix, "左"), "Waffe links")
	place_weapons(root, false)
	_take_warnings()

# Ruhe-Haken der Waffenart für eine Seite (右 / 左), "" wenn das Skelett keinen hat
func _rest_hook(suffix: String, side: String) -> String:
	if suffix == "" or skeleton == null:
		return ""
	var hooks = [REST_WAIST % [side, suffix]]
	if side == "右":
		hooks.push_front(REST_BACK % suffix)
	for h in hooks:
		var b = _bone(skeleton, h)
		if b >= 0:
			return skeleton.get_bone_name(b)
	return ""

# Waffen einer Figur an die Hand (im Kampf) oder an ihre Ruhe-Haken hängen
static func place_weapons(figure: Node3D, fighting: bool) -> void:
	var sk = figure.get_node_or_null("Skeleton3D") if figure != null else null
	if sk == null:
		return
	for n in sk.get_children():
		if n is BoneAttachment3D and n.has_meta("hand_bone"):
			var rest = str(n.get_meta("rest_bone", ""))
			n.bone_name = rest if not fighting and rest != "" else str(n.get_meta("hand_bone"))

# Waffen-Modell (.ecm) mit seinem CC_weapon am Hand-Haken -> BoneAttachment3D oder null
func _attach_weapon(rel: String, hand_hook: String, rest_bone: String, node_name: String) -> Node3D:
	if rel == "" or skeleton == null or not rel.to_lower().ends_with(".ecm"):
		return null
	var hook = _bone(skeleton, hand_hook)
	if hook < 0:
		_warn("Hook %s fehlt im Skelett der Figur" % hand_hook)
		return null
	var p = importer.find_game_file(rel)
	if p == "":
		_warn("Waffe fehlt: " + rel)
		return null
	if not _weapon_cache.has(p):
		var r = importer.build_ecm(p)
		var packed = null
		if r.has("error"):
			_warn(r["error"])
		else:
			packed = PackedScene.new()
			if packed.pack(r["root"]) != OK:
				packed = null
			r["root"].free()
		_weapon_cache[p] = packed
	if _weapon_cache[p] == null:
		return null
	var w: Node3D = _weapon_cache[p].instantiate()
	var wsk = w.get_node_or_null("Skeleton3D") as Skeleton3D
	var cc = _bone(wsk, WEAPON_CC) if wsk != null else -1
	if cc >= 0:
		w.transform = wsk.get_bone_global_rest(cc).affine_inverse()
	else:
		_warn("%s ohne Hook %s" % [rel.get_file(), WEAPON_CC])
	var at = BoneAttachment3D.new()
	at.name = node_name
	at.bone_name = skeleton.get_bone_name(hook)
	at.set_meta("hand_bone", skeleton.get_bone_name(hook))
	at.set_meta("rest_bone", rest_bone)
	skeleton.add_child(at)
	at.add_child(w)
	return at

# Bone eines Hooks (ohne Groß / Klein wie A3DSkeleton::GetHook), -1 wenn keiner
static func _bone(sk: Skeleton3D, hook: String) -> int:
	var want = hook.to_lower()
	for i in sk.get_bone_count():
		if sk.get_bone_name(i).to_lower() == want:
			return i
	return -1

# Gesicht / Maske / Frisur tauschen und Farben setzen
func set_appearance(look: Dictionary) -> void:
	appearance = look.duplicate()
	var g = _g(gender)
	var head_pattern: String = data["head"].get(str(race), {}).get(g, "")
	var hair_pattern: String = data["hair"].get(str(race), {}).get(g, "")
	var head = head_pattern % [int(look.get("face", 0)) + 1, int(look.get("mask", 0))] if head_pattern != "" else ""
	var hair = hair_pattern % [int(look.get("hair", 0)) + 1] if hair_pattern != "" else ""
	if head != _paths.get("head", ""):
		set_skin("head", head)
	if hair != _paths.get("hair", ""):
		set_skin("hair", hair)
	var skin_colors: Array = data.get("skin_colors", {}).get(str(race), [])
	var si = int(look.get("skin", 0))
	var skin_color = _color(skin_colors[si]) if si >= 0 and si < skin_colors.size() else Color.WHITE
	for slot in SKIN_SLOTS:
		_tint(slot, skin_color)
	var hc = int(look.get("hair_color", _rgb(data.get("default_hair_color", [255, 255, 255]))))
	_tint("hair", Color8((hc >> 16) & 0xFF, (hc >> 8) & 0xFF, hc & 0xFF))
	_take_warnings()

func set_skin(slot: String, rel: String) -> void:
	var old = _meshes.get(slot)
	if old != null:
		_free(old)
		_meshes.erase(slot)
	_paths[slot] = rel
	if rel == "" or skeleton == null:
		return
	var p = importer.find_game_file(rel)
	if p == "":
		_warn("Skin fehlt: " + rel)
		return
	if not _ski_cache.has(p):
		_ski_cache[p] = importer.reader.read_ski(p)
	var ski: Dictionary = _ski_cache[p]
	if ski.has("error"):
		_warn(ski["error"])
		return
	var mi = _builder.build_mesh_instance(ski, skeleton, _bon)
	if mi == null:
		return
	mi.set_meta("slot", slot)
	skeleton.add_child(mi)
	_meshes[slot] = mi

func play(action: String) -> bool:
	if animation == null or not animation.has_animation(action):
		return false
	animation.play(action)
	return true

# Begrenzung der Figur (für Kamera und Platz)
func bounds() -> AABB:
	var box = AABB()
	var first = true
	for mi in _meshes.values():
		var b: AABB = mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box

# Fertige Figur abgeben: der Aufrufer besitzt sie, der Bauer vergisst sie (nächstes build() baut neu)
func detach() -> Node3D:
	var r = root
	root = null
	skeleton = null
	animation = null
	weapon = null
	weapon_left = null
	equipment = {}
	_meshes.clear()
	_paths.clear()
	return r

func free_model() -> void:
	if root != null:
		_free(root)
	root = null
	skeleton = null
	animation = null
	weapon = null
	weapon_left = null
	equipment = {}
	_meshes.clear()
	_paths.clear()


# ====================================================
# FARBE
# ====================================================
# Flächen mit der ersten Textur des Skins einfärben (eigene Material-Kopie je Figur)
func _tint(slot: String, color: Color) -> void:
	var mi: MeshInstance3D = _meshes.get(slot)
	if mi == null:
		return
	var ski: Dictionary = _ski_cache.get(importer.find_game_file(_paths[slot]), {})
	var tex0 = _builder._texture(ski, ski["textures"][0]) if not ski.get("textures", []).is_empty() else null
	for s in mi.mesh.get_surface_count():
		var mat = mi.mesh.surface_get_material(s)
		var tex = mat.albedo_texture if mat is StandardMaterial3D else (mat.get_shader_parameter("texture_albedo") if mat is ShaderMaterial else null)
		if tex0 == null or tex != tex0:
			continue
		var own = mi.get_surface_override_material(s)
		if own == null:
			own = mat.duplicate()
			if mat is StandardMaterial3D:
				own.set_meta("base_color", mat.albedo_color)
				own.set_meta("base_emission", mat.emission)
			else:
				own.set_meta("base_color", mat.get_shader_parameter("albedo"))
				own.set_meta("base_emission", mat.get_shader_parameter("emission"))
			mi.set_surface_override_material(s, own)
		# Farbfaktor wirkt auf das ganze Ergebnis (body.sdr: Stufe 1 = Stufe 0 * TFactor), auch aufs Leuchten
		var base: Color = own.get_meta("base_color")
		var glow: Color = own.get_meta("base_emission", Color.BLACK)
		var c = Color(base.r * color.r, base.g * color.g, base.b * color.b, base.a)
		var e = Color(glow.r * color.r, glow.g * color.g, glow.b * color.b)
		if own is StandardMaterial3D:
			own.albedo_color = c
			own.emission = e
		else:
			own.set_shader_parameter("albedo", c)
			own.set_shader_parameter("emission", e)

static func _free(n: Node) -> void:
	if n.is_inside_tree():
		n.queue_free()
	else:
		n.free()

static func _color(rgb: Array) -> Color:
	return Color8(rgb[0], rgb[1], rgb[2])

static func _rgb(rgb: Array) -> int:
	return (int(rgb[0]) << 16) | (int(rgb[1]) << 8) | int(rgb[2])

static func _g(p_gender: int) -> String:
	return "w" if p_gender == 1 else "m"

func _take_warnings() -> void:
	if _builder == null:
		return
	for w in _builder.warnings:
		_warn(w)
	_builder.warnings.clear()
