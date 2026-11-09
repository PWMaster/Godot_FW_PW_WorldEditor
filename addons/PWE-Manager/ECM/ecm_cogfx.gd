@tool
extends RefCounted

# ====================================================
# CoGfx der .ecm: GFX, die dauerhaft am Modell hängen (CECModel::ShowCoGfx / TickCoGfx), z.B.
# die Blitze am Bastler. Jede GFX wird beim Import wie die Unter-GFX eines Containers (ID 200)
# komplett aufgebaut - Datei-Node, Elemente und deren Godot-Nodes - und mit der Szene gespeichert:
#   Lage   SetParentTM(matTran * Hook.GetAbsoluteTM()):
#          Hook (HookName, ohne Groß/Klein wie A3DSkeleton::GetHook) -> BoneAttachment3D
#          "CoGfx_<Hook>" am Hook-Bone des Skeletts; ohne oder unbekannter Hook -> am Modell.
#          matTran = FX_BASE_INFO::BuildTranMat: Drehung A3DQUATERNION(HookPitch, HookYaw, HookRot)
#          (EulerAngleToQuad = Rot um Z * Yaw um Y * Pitch um X), Position HookOffset
#   Scale  GfxScale * DedaultScale der GFX, Tempo GfxSpeed (Play_Speed), Alpha GfxAlpha (Alpha)
#   GfxParam  Blitz-Endpunkte an Hooks (InnerUpdateCoGfxParam, ID_PARAM_LTN_POS1/2): Node
#          "CoGfx_Param" (ecm_cogfx_param.gd) unter der GFX setzt StartPos / EndPos jeden Frame
# Die .gfx samt Texturen, Unter-GFX und Modellen kommt aus den Spieldaten (gfx_sources.gd,
# ecm_importer.gd), wie Angelica aus gfx\<FxFilePath>.
# Noch nicht umgesetzt: GfxDelayTime (verzögertes Folgen), GfxRotWithModel = 0 ohne Hook,
# UseModelAlpha.
# ====================================================

const Parser = preload("../GFX/gfx_parser.gd")
const Sources = preload("../GFX/gfx_sources.gd")
const ParamLink = preload("ecm_cogfx_param.gd")
const EVENT_TYPE_GFX = 100
const ATTACH_PREFIX = "CoGfx_"
const PARAM_NODE = "CoGfx_Param"
# GfxParam-ID -> Uniform des Blitz-Shaders (create_id_150.gd)
const LTN_UNIFORMS = {200: "StartPos", 201: "EndPos"}
const LTN_ELEMENT_ID = "150" # A3DGFXLightning
const LTN_MESH = "Lightning_GFX"

var files # angelica_files.gd, root = Spielordner der .ecm
var warnings: Array


func _init(p_files, p_warnings: Array) -> void:
	files = p_files
	warnings = p_warnings

func _warn(msg: String) -> void:
	if not msg in warnings:
		warnings.append(msg)

# cogfx: Einträge aus read_ecm() ({"type", "files", "params", "HookName", ...}).
# Hängt die GFX unter root (Owner) bzw. die Hooks von sk, liefert die Anzahl.
func build(root: Node3D, sk: Skeleton3D, hook_bones: Dictionary, cogfx: Array) -> int:
	var parser = Parser.new()
	var creator = load(get_script().resource_path.get_base_dir().path_join("../GFX/create_id_200.gd").simplify_path()).new()
	var count = 0
	for info in cogfx:
		if int(info["type"]) != EVENT_TYPE_GFX or info["files"].is_empty():
			continue
		var rel: String = info["files"][0]
		var gfx_file = find_gfx(rel)
		if gfx_file == "":
			continue # meldet der Importer
		var skipped = []
		var node = parser.build_file_node(gfx_file, _node_name(gfx_file.get_file().get_basename()), skipped)
		for raw_id in skipped:
			_warn("CoGfx " + gfx_file.get_file() + ": unbekannte Element-ID " + str(raw_id) + " übersprungen")
		creator.build_elements(node)
		node.transform = tran_matrix(info, node.scale.x * _float(info, "GfxScale", 1.0))
		node.Play_Speed = _float(info, "GfxSpeed", 1.0)
		node.Alpha = _float(info, "GfxAlpha", 1.0)
		_parent(info, root, sk, hook_bones).add_child(node, true)
		_set_owner(node, root)
		count += 1
		_link_params(info.get("params", []), node, root, sk, hook_bones, gfx_file.get_file())
		if int(_float(info, "GfxDelayTime", 0.0)) != 0:
			_warn("CoGfx " + gfx_file.get_file() + ": GfxDelayTime (verzögertes Folgen) noch nicht umgesetzt")
	creator.free()
	return count

# FxFilePath (relativ zum gfx-Ordner) -> .gfx der Spieldaten (während des ECM-Imports, gfx_sources.gd)
func find_gfx(rel: String) -> String:
	return Sources.gfx_file(rel)

# matTran mit Scale der GFX (Angelica: v * Scale * matTran * Hook)
static func tran_matrix(info: Dictionary, scale: float) -> Transform3D:
	var q = Quaternion(Vector3.BACK, _float(info, "HookRot", 0.0)) \
		* Quaternion(Vector3.UP, _float(info, "HookYaw", 0.0)) \
		* Quaternion(Vector3.RIGHT, _float(info, "HookPitch", 0.0))
	var o = str(info.get("HookOffset", "")).split(",")
	var offset = Vector3(o[0].to_float(), o[1].to_float(), o[2].to_float()) if o.size() >= 3 else Vector3.ZERO
	return Transform3D(Basis(q).scaled(Vector3.ONE * scale), offset)

# GetGfxBindHookTransMat: Hook des Skeletts, sonst das Modell selbst
func _parent(info: Dictionary, root: Node3D, sk: Skeleton3D, hook_bones: Dictionary) -> Node3D:
	var hook = str(info.get("HookName", "")).strip_edges()
	if hook == "":
		if str(info.get("GfxRotWithModel", "1")).strip_edges() == "0":
			_warn("CoGfx ohne Hook mit GfxRotWithModel 0: dreht hier mit dem Modell")
		return root
	if not hook_bones.has(hook.to_lower()):
		_warn("CoGfx-Hook " + hook + " fehlt im Skelett, GFX am Modell")
		return root
	var bone = sk.get_bone_name(hook_bones[hook.to_lower()])
	var att_name = _node_name(ATTACH_PREFIX + bone)
	var att = sk.get_node_or_null(NodePath(att_name))
	if att == null:
		att = BoneAttachment3D.new()
		att.name = att_name
		sk.add_child(att)
		att.owner = root
		att.bone_name = bone # nach add_child: findet den Bone-Index über das Skelett
	return att

# GfxParam -> Node CoGfx_Param unter der GFX. Wie InnerUpdateCoGfxParam: Element per Name in
# derselben GFX (erstes mit dem Namen, ohne Unter-GFX), Hook ohne Groß/Klein; fehlt eins, bleibt
# der Endpunkt, wie er ist. Namen liest Angelica mit sscanf("%s"): nur bis zum ersten Leerzeichen.
func _link_params(params: Array, gfx: Node3D, root: Node3D, sk: Skeleton3D, hook_bones: Dictionary, label: String) -> void:
	var links: Array[Dictionary] = []
	for p in params:
		var id = str(p.get("ParamId", "")).to_int()
		if not LTN_UNIFORMS.has(id):
			_warn("CoGfx " + label + ": GfxParam " + str(id) + " wird nicht unterstützt")
			continue
		var ele_name = _scanf_s(p.get("ele", ""))
		var ele = _find_element(gfx, ele_name)
		if ele == null:
			_warn("CoGfx " + label + ": Element " + ele_name + " für Blitz-Endpunkt fehlt in der GFX")
			continue
		var data: Dictionary = ele.get("parsed_data")
		if str(data.get("_system_id", "")) != LTN_ELEMENT_ID or ele.get_node_or_null(LTN_MESH) == null:
			_warn("CoGfx " + label + ": Element " + ele_name + " (ID " + str(data.get("_system_id", "")) + ") ist kein Blitz, Endpunkt nicht gesetzt")
			continue
		if not (_as_bool(data.get("Pos1Enable", "0")) or _as_bool(data.get("Pos2Enable", "0"))):
			_warn("CoGfx " + label + ": Blitz " + ele_name + " ohne Pos1Enable / Pos2Enable, Endpunkt nicht gesetzt")
			continue
		var mat = ele.get_node(LTN_MESH).get("material_override")
		if not (mat is ShaderMaterial and mat.shader != null and mat.shader.code.contains("uniform vec3 " + LTN_UNIFORMS[id] + ";")):
			_warn("CoGfx " + label + ": Blitz " + ele_name + " ohne " + LTN_UNIFORMS[id] + " in der .gfx, Endpunkt nicht gesetzt")
			continue
		# Bei ParamDataIsCmd steht der Befehl im selben Feld (m_strHook) und wird als Hook gesucht
		var hook = _scanf_s(p.get("ParamDataCmd" if _as_bool(p.get("ParamDataIsCmd", "0")) else "ParamDataHook", ""))
		if not hook_bones.has(hook.to_lower()):
			_warn("CoGfx " + label + ": Hook " + hook + " für Blitz-Endpunkt fehlt im Skelett")
			continue
		links.append({"mesh": ele.get_node(LTN_MESH), "uniform": LTN_UNIFORMS[id], "bone": sk.get_bone_name(hook_bones[hook.to_lower()])})
	if links.is_empty():
		return
	var node = ParamLink.new()
	node.name = PARAM_NODE
	gfx.add_child(node, true)
	node.owner = root
	node.skeleton = node.get_path_to(sk)
	for link in links:
		link["mesh"] = node.get_path_to(link["mesh"])
	node.links = links

func _find_element(gfx: Node, ele_name: String) -> Node:
	if ele_name == "":
		return null
	for child in gfx.get_children():
		var data = child.get("parsed_data")
		if typeof(data) == TYPE_DICTIONARY and data.has("_system_id") and _scanf_s(data.get("Name", "")) == ele_name:
			return child
	return null

static func _scanf_s(value) -> String:
	var parts = str(value).replace("\t", " ").strip_edges().split(" ", false)
	return parts[0] if parts.size() > 0 else ""

static func _as_bool(value) -> bool:
	return str(value).strip_edges().to_int() != 0

func _set_owner(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		_set_owner(child, owner)

static func _float(info: Dictionary, key: String, def: float) -> float:
	return str(info[key]).to_float() if info.has(key) else def

static func _node_name(n: String) -> String:
	for c in [".", ":", "@", "/", "\"", "%"]:
		n = n.replace(c, "_")
	return n if n != "" else "GFX"
