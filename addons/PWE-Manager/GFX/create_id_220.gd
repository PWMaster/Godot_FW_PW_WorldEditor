@tool
extends "create_id_130.gd"

# ====================================================
# GFXELEMENTID 220 = ID_ELE_TYPE_PHYS_EMITTER (A3DPhysEmitter)
# ====================================================
# Ein PhysX-Fluid als Partikelsystem. Die Physik-Werte stehen nicht in der .gfx, sondern in der
# .gphy daneben (A3DGFXPhysDataMan, Eintrag "PhysDesc: <Name>"):
#   "yhpg", Version, Anzahl, je Eintrag: Typ (0 = Fluid), Name (Länge + Text),
#   APhysXFluidParameters (132 Byte), APhysXFluidEmitterParameters (104 Byte),
#   Fluid-Objekt-Typ (0 = normal, 1 = orientiert + 16 Byte).
# Aus der .gfx: ParHeight / ParWidth (halbe Größe), ScaleMin / Max, RotMin / Max (Bogenmaß),
# ColorMin / Max (je Kanal zufällig), IsFaceToView (0 = Welt-Quad, 1 = zur Kamera, 2 = PhysX-Drehung).
# PhysX gibt es in Godot nicht: gfx_phys_220.gd rechnet die Partikel selbst nach (siehe dort),
# ein MultiMesh zeichnet sie mit dem Shader von hier.
# Nicht umgesetzt: SPH-Wechselwirkung zwischen Partikeln (die Bibliothek nutzt sie nicht),
# Affektoren (erst ab Dateiversion 117), Dummy-Elemente an den Partikeln, PhysX-Drehung (Typ 2).
# ====================================================

const Parser = preload("gfx_parser.gd")
const PHYS_NODE_NAME = "PhysParticles_GFX"
const PHYS_DRIVER_SCRIPT = "gfx_phys_220.gd"
const GPHY_MAGIC = "yhpg"
const FLUID_PARAM_BYTES = 132
const EMITTER_PARAM_BYTES = 104
const ORIENT_CREATOR_BYTES = 16
const MAX_POOL = 1024 # A3DPhysEmitter::s_MaxSupportParticleNum

# PhysX-Flags (NxFluidDesc.h / NxFluidEmitterDesc.h)
const NX_F_SPH = 1
const NX_F_STATIC = 1
const NX_FF_DISABLE_GRAVITY = 2
const NX_FEF_ADD_BODY_VELOCITY = 8
const NX_FEF_ENABLED = 16


func _element_id() -> String:
	return "220"

func _node_name() -> String:
	return PHYS_NODE_NAME

func _node_label() -> String:
	return "Physik-Partikel"

func build_node(parent_node: Node, max_group_time: float) -> Node3D:
	return build_phys_node(parent_node, max_group_time)


# ====================================================
# BAUT DAS PARTIKELSYSTEM (ohne Szene / UndoRedo -> auch für Tests nutzbar)
# ====================================================
func build_phys_node(parent_node: Node, max_group_time: float) -> Node3D:
	var parsed_data = parent_node.get("parsed_data")
	if typeof(parsed_data) != TYPE_DICTIONARY:
		return null

	var node = MultiMeshInstance3D.new()
	node.name = PHYS_NODE_NAME
	node.set_script(load(_driver_path(PHYS_DRIVER_SCRIPT)))
	_apply_time_settings(node, parsed_data, max_group_time)

	# Werte roh aus parsed_data; fehlende Zeilen = Standardwerte aus A3DPhysEmitter()
	node.Par_Width = float(parsed_data.get("ParWidth", 1.0))
	node.Par_Height = float(parsed_data.get("ParHeight", 1.0))
	node.Scale_Min = float(parsed_data.get("ScaleMin", 1.0))
	node.Scale_Max = float(parsed_data.get("ScaleMax", 1.0))
	node.Rot_Min = float(parsed_data.get("RotMin", 0.0))
	node.Rot_Max = float(parsed_data.get("RotMax", 0.0))
	node.Color_Min = _argb_to_color(str(parsed_data.get("ColorMin", "-1")))
	node.Color_Max = _argb_to_color(str(parsed_data.get("ColorMax", "-1")))
	node.Par_Type = clampi(int(str(parsed_data.get("IsFaceToView", "1"))), 0, 2)
	node.Random_Seed = hash(str(parent_node.name)) & 0xFFFF
	node.keypoints = _build_keypoints(parent_node, parsed_data)

	var desc_name = str(parsed_data.get("PhysDesc", "")).strip_edges()
	node.Phys_Desc = desc_name
	var gphy = _find_gphy(parent_node)
	var phys = read_gphy(gphy, desc_name) if gphy != "" else {}
	if phys.is_empty():
		push_warning("GFX Phys: " + desc_name + " nicht gefunden (" + (gphy if gphy != "" else ".gphy fehlt") + ") -> PhysX-Standardwerte")
	else:
		node.Phys_File = gphy
	_apply_phys(node, phys)

	node.material_override = _build_material(parsed_data, preload("gfx_parser.gd").z_test_enabled(parent_node, parsed_data))
	node.multimesh = _build_multimesh(node)
	return node


# ====================================================
# .gphy (A3DGFXPhysDataMan::LoadPhys)
# ====================================================
# Liegt neben der .gfx (gleicher Name, Endung .gphy, ohne Groß/Klein-Unterscheidung)
func _find_gphy(parent_node: Node) -> String:
	var header = parent_node.get_parent()
	var header_data = header.get("parsed_data") if header != null else null
	var gfx_file = str(header_data.get("_file_path", "")) if typeof(header_data) == TYPE_DICTIONARY else ""
	if gfx_file != "":
		var found = _find_file_nocase(gfx_file.get_base_dir(), gfx_file.get_file().get_basename() + ".gphy")
		if found != "":
			return found
	# Ältere Szenen kennen den Pfad nicht: nach dem Datei-Node-Namen suchen
	if header != null:
		for dir in [Parser.LOAD_DIR]:
			var found = _search_nocase(dir.trim_suffix("/"), str(header.name) + ".gphy")
			if found != "":
				return found
	return ""

func _find_file_nocase(dir: String, file_name: String) -> String:
	var want = file_name.to_lower()
	for f in Parser._decoder().list_dir(dir)["files"]:
		if f.to_lower() == want:
			return dir.path_join(f)
	return ""

func _search_nocase(dir: String, file_name: String) -> String:
	var found = _find_file_nocase(dir, file_name)
	if found != "":
		return found
	for sub in Parser._decoder().list_dir(dir)["dirs"]:
		found = _search_nocase(dir.path_join(sub), file_name)
		if found != "":
			return found
	return ""

# Eintrag desc_name als Dictionary ({} = nicht gefunden / unlesbar)
func read_gphy(path: String, desc_name: String) -> Dictionary:
	var b = Parser._decoder().get_bytes(path)
	if b.size() < 12 or b.slice(0, 4).get_string_from_ascii() != GPHY_MAGIC:
		return {}
	var count = b.decode_u32(8)
	var o = 12
	for k in range(count):
		if o + 8 > b.size():
			return {}
		var sync_type = b.decode_u32(o)
		var name_len = b.decode_u32(o + 4)
		var entry_name = b.slice(o + 8, o + 8 + name_len).get_string_from_utf8()
		o += 8 + name_len
		if sync_type != 0 or o + FLUID_PARAM_BYTES + EMITTER_PARAM_BYTES + 4 > b.size():
			return {} # nur Fluid-Einträge bekannt
		var entry = _decode_fluid(b, o)
		o += FLUID_PARAM_BYTES
		entry.merge(_decode_emitter(b, o))
		o += EMITTER_PARAM_BYTES
		entry["object_type"] = b.decode_u32(o)
		o += 4
		if entry["object_type"] == 1:
			o += ORIENT_CREATOR_BYTES
		if entry_name == desc_name:
			return entry
	return {}

# APhysXFluidParameters
func _decode_fluid(b: PackedByteArray, o: int) -> Dictionary:
	var f = func(i: int) -> float: return b.decode_float(o + 4 * i)
	var u = func(i: int) -> int: return b.decode_u32(o + 4 * i)
	return {
		"max_particles": u.call(0), "rest_per_meter": f.call(2), "motion_limit_mult": f.call(5),
		"collision_dist_mult": f.call(6), "damping": f.call(11), "fade_in": f.call(12),
		"ext_acc": Vector3(f.call(13), f.call(14), f.call(15)),
		"restitution": f.call(20), "dyn_friction": f.call(21),
		"sim_method": u.call(29), "collision_method": u.call(30), "fluid_flags": u.call(32),
	}

# APhysXFluidEmitterParameters (NxMat34: Zeilen der Drehung, dann Position)
func _decode_emitter(b: PackedByteArray, o: int) -> Dictionary:
	var f = func(i: int) -> float: return b.decode_float(o + 4 * i)
	var u = func(i: int) -> int: return b.decode_u32(o + 4 * i)
	var basis = Basis(Vector3(f.call(0), f.call(3), f.call(6)), Vector3(f.call(1), f.call(4), f.call(7)), Vector3(f.call(2), f.call(5), f.call(8)))
	return {
		"pose": Transform3D(basis, Vector3(f.call(9), f.call(10), f.call(11))),
		"emitter_type": u.call(12), "emitter_max": u.call(13), "shape": u.call(14),
		"dim": Vector2(f.call(15), f.call(16)), "random_pos": Vector3(f.call(17), f.call(18), f.call(19)),
		"random_angle": f.call(20), "velocity": f.call(21), "rate": f.call(22), "lifetime": f.call(23),
		"emitter_flags": u.call(25),
	}

# Fehlende .gphy: A3DPhysFluidSyncData::SetInitParameters + PhysX-Standardwerte
func _apply_phys(node: Node, p: Dictionary) -> void:
	var rest_spacing = 1.0 / maxf(0.001, float(p.get("rest_per_meter", 10.0)))
	node.Max_Particles = mini(int(p.get("max_particles", 1000)), MAX_POOL)
	node.Motion_Limit = float(p.get("motion_limit_mult", 3.6)) * rest_spacing
	node.Collision_Distance = float(p.get("collision_dist_mult", 0.12)) * rest_spacing
	node.Damping = float(p.get("damping", 0.0))
	node.External_Acceleration = p.get("ext_acc", Vector3.ZERO)
	node.Restitution = float(p.get("restitution", 0.5))
	node.Dynamic_Friction = float(p.get("dyn_friction", 0.05))
	node.Disable_Gravity = (int(p.get("fluid_flags", 9)) & NX_FF_DISABLE_GRAVITY) != 0
	node.Ground_Collision = (int(p.get("collision_method", 3)) & NX_F_STATIC) != 0
	if (int(p.get("sim_method", 2)) & NX_F_SPH) != 0:
		push_warning("GFX Phys: " + node.Phys_Desc + " nutzt SPH (Partikel-Wechselwirkung) -> ohne Wechselwirkung gerechnet")
	node.Emitter_Pose = p.get("pose", Transform3D.IDENTITY)
	node.Emitter_Shape = 1 if int(p.get("shape", 2)) == 1 else 2
	node.Emitter_Dimension = p.get("dim", Vector2(0.25, 0.25))
	node.Random_Pos = p.get("random_pos", Vector3(0.05, 0.05, 0.05))
	node.Random_Angle = float(p.get("random_angle", 0.5))
	node.Velocity = float(p.get("velocity", 5.0))
	node.Rate = float(p.get("rate", 100.0))
	node.Emitter_Max_Particles = int(p.get("emitter_max", 0))
	node.Lifetime = float(p.get("lifetime", 10.0))
	var e_flags = int(p.get("emitter_flags", NX_FEF_ENABLED | NX_FEF_ADD_BODY_VELOCITY))
	node.Emitter_Enabled = (e_flags & NX_FEF_ENABLED) != 0
	node.Add_Body_Velocity = (e_flags & NX_FEF_ADD_BODY_VELOCITY) != 0


# ====================================================
# MULTIMESH + SHADER
# ====================================================
func _build_multimesh(node: Node) -> MultiMesh:
	# Quad -1..1 (die Ecke ist die Richtung, Größe / Drehung / UV rechnet der Shader)
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-1, -1, 0), Vector3(-1, 1, 0), Vector3(1, -1, 0), Vector3(1, 1, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 2, 1, 3])
	var quad = ArrayMesh.new()
	quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = node.pool_size()
	mm.visible_instance_count = 0
	return mm

func _build_material(parsed_data: Dictionary, z_test: bool) -> ShaderMaterial:
	var mat = ShaderMaterial.new()
	var shader = Shader.new()
	shader.code = preload("gfx_parser.gd").add_gfx_alpha(_build_shader_code(parsed_data, z_test))
	mat.shader = shader
	var tex_path_raw = str(parsed_data.get("TexFile", "")).strip_edges()
	if tex_path_raw != "":
		# Textur aus den Spieldaten (gfx_sources.gd)
		var loaded_tex = preload("gfx_sources.gd").texture(tex_path_raw)
		if loaded_tex != null:
			mat.set_shader_parameter("TexFile", loaded_tex)
	mat.set_shader_parameter("TexRow", maxi(1, int(parsed_data.get("TexRow", 1))))
	mat.set_shader_parameter("TexCol", maxi(1, int(parsed_data.get("TexCol", 1))))
	mat.set_shader_parameter("TexInterval", maxi(1, int(parsed_data.get("TexInterval", 50))))
	mat.set_shader_parameter("TileMode", _as_bool(parsed_data.get("TileMode", "0")))
	mat.set_shader_parameter("TexSpeed_1", float(parsed_data.get("TexSpeed_1", 0.0)))
	mat.set_shader_parameter("TexSpeed_2", float(parsed_data.get("TexSpeed_2", 0.0)))
	mat.set_shader_parameter("UReverse", _as_bool(parsed_data.get("UReverse", "0")))
	mat.set_shader_parameter("VReverse", _as_bool(parsed_data.get("VReverse", "0")))
	mat.set_shader_parameter("UVExchg", _as_bool(parsed_data.get("UVExchg", "0")))
	mat.render_priority = clampi(int(parsed_data.get("Priority", 0)), Material.RENDER_PRIORITY_MIN, Material.RENDER_PRIORITY_MAX)
	return mat

func _build_shader_code(parsed_data: Dictionary, z_test: bool) -> String:
	# Blend wie bei den anderen Elementen: DestBlend ONE / INVSRCCOLOR = additiv
	var dest_blend = str(parsed_data.get("DestBlend", ""))
	var blend = "blend_add" if dest_blend in ["2", "4"] else "blend_mix"
	var c = "shader_type spatial;\n"
	c += "render_mode " + blend + ", depth_draw_opaque, cull_disabled, unshaded"
	# ZEnable des Elements und 2DRender der GFX
	if not z_test:
		c += ", depth_test_disabled"
	c += ";\n\n"
	c += "// Partikel von gfx_phys_220.gd: Instanz-Position = Welt-Position, COLOR = Partikelfarbe,\n"
	c += "// INSTANCE_CUSTOM.x = Scale (GFX * KeyPoint * Partikel), .y = 2D-Drehung\n"
	c += "uniform sampler2D TexFile : hint_default_white" + (", repeat_enable" if _as_bool(parsed_data.get("TileMode", "0")) else "") + ";\n"
	c += "group_uniforms Particles; // setzt gfx_phys_220.gd\n"
	c += "uniform float Par_Width = 1.0;\n"
	c += "uniform float Par_Height = 1.0;\n"
	c += "uniform int Par_Type = 1;\n"
	c += "uniform float Element_Time = 0.0; // ms seit StartTime (Textur-Animation)\n"
	c += "group_uniforms;\n"
	c += "group_uniforms Texture;\n"
	c += "uniform int TexRow = 1;\n"
	c += "uniform int TexCol = 1;\n"
	c += "uniform int TexInterval = 50;\n"
	c += "uniform bool TileMode = false;\n"
	c += "uniform float TexSpeed_1 = 0.0;\n"
	c += "uniform float TexSpeed_2 = 0.0;\n"
	c += "uniform bool UReverse = false;\n"
	c += "uniform bool VReverse = false;\n"
	c += "uniform bool UVExchg = false;\n"
	c += "group_uniforms;\n\n"
	c += "varying vec4 v_color;\n\n"
	c += "void vertex() {\n"
	c += "\tvec2 corner = VERTEX.xy; // (-1, -1) links unten .. (1, 1) rechts oben\n"
	c += "\tvec2 off = corner * vec2(Par_Width, Par_Height) * INSTANCE_CUSTOM.x;\n"
	c += "\tfloat rot = INSTANCE_CUSTOM.y;\n"
	c += "\toff = vec2(off.x * cos(rot) - off.y * sin(rot), off.x * sin(rot) + off.y * cos(rot));\n"
	c += "\tif (Par_Type == 1) {\n"
	c += "\t\t// Update_2D: Quad parallel zum Bildschirm in Tiefe der Mitte\n"
	c += "\t\tvec4 view_c = VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0);\n"
	c += "\t\tview_c.xy += off;\n"
	c += "\t\tPOSITION = PROJECTION_MATRIX * view_c;\n"
	c += "\t} else {\n"
	c += "\t\t// Update_3D: Quad in der X / Y-Ebene, Drehung um Z\n"
	c += "\t\t// (schreibt der Shader POSITION, gilt es immer -> hier selbst projizieren)\n"
	c += "\t\tVERTEX = vec3(off, 0.0);\n"
	c += "\t\tPOSITION = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));\n"
	c += "\t}\n"
	c += "\tv_color = COLOR;\n\n"
	c += "\t// A3DGFXElement::TexAnimation + exchangeUV\n"
	c += "\tfloat cols = float(max(1, TexCol));\n"
	c += "\tfloat rows = float(max(1, TexRow));\n"
	c += "\tvec2 tex_uv = vec2(0.0);\n"
	c += "\tvec2 tex_wh = vec2(1.0);\n"
	c += "\tif (TileMode) {\n"
	c += "\t\ttex_wh = vec2(cols, rows);\n"
	c += "\t\ttex_uv = Element_Time / 1000.0 * vec2(TexSpeed_1, TexSpeed_2);\n"
	c += "\t} else if (cols * rows > 1.0) {\n"
	c += "\t\tfloat frame = mod(floor(Element_Time / float(max(1, TexInterval))), cols * rows);\n"
	c += "\t\ttex_wh = 1.0 / vec2(cols, rows);\n"
	c += "\t\ttex_uv = vec2(mod(frame, cols), floor(frame / cols)) * tex_wh;\n"
	c += "\t}\n"
	c += "\tvec4 r = vec4(tex_uv.x, tex_uv.x + tex_wh.x, tex_uv.y, tex_uv.y + tex_wh.y); // U0, U1, V0, V1\n"
	c += "\tif (UReverse) r.xy = r.yx;\n"
	c += "\tif (VReverse) r.zw = r.wz;\n"
	c += "\tif (UVExchg) r = r.zwxy;\n"
	c += "\tUV = vec2(corner.x < 0.0 ? r.x : r.y, corner.y > 0.0 ? r.z : r.w);\n"
	c += "}\n\n"
	c += "void fragment() {\n"
	c += "\tvec4 tex_color = texture(TexFile, UV) * v_color;\n"
	if blend == "blend_mix":
		c += "\t// Alpha leicht dämpfen, damit Mix-Sprites nicht zu massiv wirken (wie ID_100)\n"
		c += "\ttex_color.a *= 0.70;\n"
	c += "\tALBEDO = tex_color.rgb;\n"
	c += "\tALPHA = tex_color.a;\n"
	c += "}\n"
	return c
