@tool
extends Node

# ====================================================
# GfxParam einer CoGfx (CECModel::InnerUpdateCoGfxParam): setzt jeden Frame die Endpunkte von
# Blitz-Elementen (ID 150) auf Hooks des Modells, z.B. einen Blitz von HH_base bis HH_tip:
#   ID_PARAM_LTN_POS1 (200) -> StartPos, ID_PARAM_LTN_POS2 (201) -> EndPos
# Angelica setzt die Weltposition des Hooks (GetAbsoluteTM().GetRow(3)); mit Pos1Enable /
# Pos2Enable rechnet der Blitz sie ohne GFX- und KeyPoint-Matrix (UpdateVertex: matTran = Identity).
# Hier wird sie in den Raum des Blitz-Meshes umgerechnet, dessen Shader sie dann unverändert nimmt.
# Läuft nach der Animation (PROCESS_PRIORITY), damit der Blitz nicht einen Frame hinterherhängt;
# auch im Editor. Den Node legt der ECM-Import unter der GFX an (ecm_cogfx.gd).
# ====================================================

const PROCESS_PRIORITY = 100 # nach AnimationPlayer (0): Bone-Posen sind schon gesetzt

## Skelett des Modells (Hooks sind Bones darin)
@export var skeleton: NodePath
## Je Endpunkt {"mesh": NodePath zum Blitz-Mesh, "uniform": "StartPos" / "EndPos", "bone": Hook-Bone}
@export var links: Array[Dictionary] = []

var _bones = {} # Bone-Name -> Index


func _ready() -> void:
	process_priority = PROCESS_PRIORITY

func _process(_delta: float) -> void:
	update_links()

func update_links() -> void:
	var sk = get_node_or_null(skeleton) as Skeleton3D
	if sk == null or not sk.is_inside_tree():
		return
	for link in links:
		var mesh = get_node_or_null(link.get("mesh", NodePath())) as GeometryInstance3D
		var mat = mesh.material_override as ShaderMaterial if mesh != null else null
		if mat == null:
			continue
		var bone = _bone(sk, str(link.get("bone", "")))
		if bone < 0:
			continue
		var world = sk.global_transform * sk.get_bone_global_pose(bone).origin
		var local = mesh.global_transform.affine_inverse() * world
		var uniform = StringName(link.get("uniform", ""))
		if mat.get_shader_parameter(uniform) != local:
			mat.set_shader_parameter(uniform, local)

func _bone(sk: Skeleton3D, bone_name: String) -> int:
	var i = int(_bones.get(bone_name, -1))
	if i < 0 or i >= sk.get_bone_count() or sk.get_bone_name(i) != bone_name:
		i = sk.find_bone(bone_name)
		_bones[bone_name] = i
	return i
