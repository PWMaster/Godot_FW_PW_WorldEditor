@tool
extends RefCounted

# ====================================================
# Baut aus einem Angelica-Modell (.smd + .bon + .ski + .stck, gelesen mit
# angelica_model_reader.gd) Godot-Nodes und -Ressourcen:
#   Skeleton3D      Bones (Ruhelage = matRelative), Hooks (HH_...) als Bones am Hook-Bone für
#                   BoneAttachment3D; Namen wie in Angelica
#   MeshInstance3D  je .ski ein ArrayMesh (Skin- und Rigid-Meshes als Flächen) mit Skin:
#                   Bind-Pose = matBoneInit (v * BoneInit * Abs), Skin-Meshes über die
#                   Bone-Namen der .ski, Rigid-Meshes über den Skelett-Bone; Index = Anzahl
#                   Skin-Bones bzw. ungültig = das Skelett selbst ("Skeleton_Root")
#   AnimationPlayer eine AnimationLibrary, je Aktion der .smd eine Animation, abgetastet im Takt
#                   der Spur wie A3DTrackData::GetKeyValue_OV; gespiegelte Bones (FLAG_FLIPPED)
#                   bekommen Scale (-1, 1, 1) wie A3DBone::Update
#   Materialien     StandardMaterial3D mit der .dds (wird kopiert, Godot lädt .dds direkt; .dds,
#                   die Godot nicht liest, DXT1 mit 1-Bit-Alpha und .tga & Co. werden ImageTexture-.res),
#                   2Sided -> ohne Culling, Textur mit Alpha -> Alpha-Test 84 / 255;
#                   Texturen "r_..." (Waffen) -> Reflexions-Shader wie Shaders\armor.sdr im Spiel
# ====================================================

const ROOT_BONE = "Skeleton_Root"
const ALPHA_REF = 84.0 / 255.0
const ALPHA_FORMATS = [Image.FORMAT_DXT3, Image.FORMAT_DXT5, Image.FORMAT_RGBA8, Image.FORMAT_RGBA4444]
const BAD_NAME_CHARS = [":", "/", ",", "[", "]", "\""]
# .dds-Kopf (DDS_HEADER)
const DDSD_MIPMAPCOUNT = 0x20000
const DDSCAPS2_VOLUME = 0x200000
const DDPF_FOURCC = 0x4
const DDS_FORMATS = {"DXT1": Image.FORMAT_DXT1, "DXT3": Image.FORMAT_DXT3, "DXT5": Image.FORMAT_DXT5}
# Texturen, deren Name mit "r_" beginnt, ersetzt das Spiel durch Shaders\armor.sdr
# (A3DSkinMan::SHADERREPLACE_REFLECTPREFIX), Pixel-Shader Shaders\ps\armorrender.txt:
#   Farbe = Textur * Licht + Glanz * Textur.a + Kugel-Map * Textur.a * Licht, Alpha = Material
# Das Alpha der Textur ist also Maske für Glanz und Reflexion, keine Transparenz. Die Kugel-Map
# wird über die Normale im Kamera-Raum gelesen (TCI_CAMERASPACENORMAL, textrans 0.5 / -0.5 + 0.5).
const REFLECT_PREFIX = "r_"
const REFLECT_MAP = "Textures/reflect/armorreflect.bmp"
const REFLECT_SHADER = """shader_type spatial;
render_mode {cull};

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D texture_reflect : source_color, filter_linear, repeat_disable;
uniform float specular : hint_range(0.0, 1.0) = 0.0;
uniform vec3 emission : source_color = vec3(0.0);

void fragment() {
	vec4 base = texture(texture_albedo, UV);
	vec3 reflection = texture(texture_reflect, normalize(NORMAL).xy * vec2(0.5, -0.5) + 0.5).rgb;
	ALBEDO = albedo.rgb * (base.rgb + reflection * base.a);
	ROUGHNESS = 1.0;
	SPECULAR = specular * base.a;
	EMISSION = emission;{alpha}
}
"""

var files # angelica_files.gd
var reader # angelica_model_reader.gd
var texture_dest: Callable # Quellpfad -> Zielpfad im Projekt ("" = nicht kopieren)
var warnings: Array = []
var written: Array = [] # kopierte / gespeicherte Texturen (für den Editor, siehe ecm_importer.gd)
var hook_bones = {} # Hook-Name in Kleinbuchstaben -> Bone-Index (GetSkeletonHook ohne Groß/Klein)
var extra_roots: Array = [] # weitere Spielordner (z.B. für die Reflexions-Map), nach files.root
var _stck_cache = {}
var _tex_cache = {}
var _reflect_shaders = {} # "<2Sided>_<transparent>" -> Shader


func _init(p_files, p_reader, p_texture_dest: Callable) -> void:
	files = p_files
	reader = p_reader
	texture_dest = p_texture_dest

func _warn(msg: String) -> void:
	if not msg in warnings:
		warnings.append(msg)


# ====================================================
# MODELL
# ====================================================
# smd: read_smd(), skins: read_ski()-Ergebnisse -> {"root": Node3D, "meshes": [ArrayMesh],
# "actions": AnimationLibrary} oder {"error": ...}
func build(model_name: String, smd: Dictionary, skins: Array) -> Dictionary:
	var bon_path = files.resolve(smd["bon"], smd["path"].get_base_dir())
	if bon_path == "":
		return {"error": "Skelett " + smd["bon"] + " nicht gefunden"}
	var bon = reader.read_bon(bon_path)
	if bon.has("error"):
		return {"error": "Skelett " + smd["bon"] + ": " + bon["error"]}
	var root = Node3D.new()
	root.name = model_name
	var sk = build_skeleton(bon)
	root.add_child(sk)
	sk.owner = root
	var meshes = []
	for ski in skins:
		var mi = build_mesh_instance(ski, sk, bon)
		if mi == null:
			continue
		sk.add_child(mi)
		mi.owner = root
		meshes.append(mi.mesh)
	var player = AnimationPlayer.new()
	player.name = "AnimationPlayer"
	var lib = build_actions(smd, bon, sk)
	player.add_animation_library("", lib)
	root.add_child(player)
	player.owner = root
	return {"root": root, "meshes": meshes, "actions": lib}


# ====================================================
# SKELETT
# ====================================================
func build_skeleton(bon: Dictionary) -> Skeleton3D:
	var sk = Skeleton3D.new()
	sk.name = "Skeleton3D"
	var bones: Array = bon["bones"]
	for b in bones:
		sk.add_bone(_unique_bone_name(sk, b["name"]))
	for i in bones.size():
		var parent = bones[i]["parent"]
		if parent >= 0 and parent < bones.size() and parent != i:
			sk.set_bone_parent(i, parent)
		sk.set_bone_rest(i, _rest(bones[i]["rel"], bon["path"].get_file() + ": Bone " + bones[i]["name"]))
	hook_bones.clear()
	for h in bon["hooks"]:
		var i = sk.add_bone(_unique_bone_name(sk, h["name"]))
		if not hook_bones.has(h["name"].to_lower()):
			hook_bones[h["name"].to_lower()] = i
		if h["bone"] >= 0 and h["bone"] < bones.size():
			sk.set_bone_parent(i, h["bone"])
		sk.set_bone_rest(i, _rest(h["tm"], bon["path"].get_file() + ": Hook " + h["name"]))
	sk.reset_bone_poses()
	return sk

# Bone-Posen in Godot sind Position / Rotation / Scale: schiefe oder fast entartete Matrizen
# (einzelne Bones / Hooks in den Spieldaten) werden gerade gerichtet, Achslängen und
# Spiegelung bleiben. Saubere Matrizen bleiben unverändert, kaputte (Achsen ~0 oder riesig)
# werden zur Einheitsmatrix.
func _rest(t: Transform3D, label: String) -> Transform3D:
	var b = t.basis
	var s = Vector3(b.x.length(), b.y.length(), b.z.length())
	if s.x < 1e-6 or s.y < 1e-6 or s.z < 1e-6 or s.x > 1e4 or s.y > 1e4 or s.z > 1e4:
		_warn(label + ": ungültige Ruhelage, ersetzt")
		return Transform3D(Basis.IDENTITY, t.origin if t.origin.length() < 1e4 else Vector3.ZERO)
	var xn = b.x / s.x
	var yn = b.y / s.y
	var zn = b.z / s.z
	if absf(xn.dot(yn)) < 1e-6 and absf(xn.dot(zn)) < 1e-6 and absf(yn.dot(zn)) < 1e-6:
		return t
	var o = b.orthonormalized()
	if o.determinant() * b.determinant() < 0.0:
		o.z = -o.z
	return Transform3D(Basis(o.x * s.x, o.y * s.y, o.z * s.z), t.origin)

func _unique_bone_name(sk: Skeleton3D, wanted: String) -> String:
	var n = _clean_name(wanted, "Bone")
	var base = n
	var k = 2
	while sk.find_bone(n) >= 0:
		n = "%s_%d" % [base, k]
		k += 1
	return n

func _clean_name(wanted: String, fallback: String) -> String:
	var n = wanted.strip_edges()
	for c in BAD_NAME_CHARS:
		n = n.replace(c, "_")
	return n if n != "" else fallback

# Das Skelett selbst als Bone (Skin-Index = Anzahl Skin-Bones, siehe A3DSkin::BindSkeleton)
func _root_bone(sk: Skeleton3D) -> int:
	var i = sk.find_bone(ROOT_BONE)
	if i < 0:
		i = sk.add_bone(ROOT_BONE)
		sk.set_bone_rest(i, Transform3D.IDENTITY)
		sk.reset_bone_pose(i)
	return i


# ====================================================
# MESH + SKIN
# ====================================================
func build_mesh_instance(ski: Dictionary, sk: Skeleton3D, bon: Dictionary) -> MeshInstance3D:
	var skin = Skin.new()
	var binds = {} # Skelett-Bone -> Bind-Index
	var by_name = {}
	for i in bon["bones"].size():
		by_name[bon["bones"][i]["name"]] = i
	# Skin-Bone-Index -> Skelett-Bone (-1 = Skelett selbst)
	var skin_bones = PackedInt32Array()
	for name in ski["bone_names"]:
		var b = by_name.get(name, -2)
		if b == -2:
			for other in by_name:
				if other.to_lower() == name.to_lower():
					b = by_name[other]
			if b == -2:
				_warn(ski["path"].get_file() + ": Bone \"" + name + "\" fehlt im Skelett")
				b = -1
		skin_bones.append(b)

	var mesh = ArrayMesh.new()
	var materials = {}
	for m in ski["skin_meshes"]:
		if m["indices"].is_empty():
			continue
		var bones: PackedInt32Array = m["bones"]
		var weights: PackedFloat32Array = m["weights"]
		var out_bones = PackedInt32Array()
		var out_weights = PackedFloat32Array()
		out_bones.resize(bones.size())
		out_weights.resize(weights.size())
		for v in bones.size() >> 2:
			var sum = 0.0
			for k in 4:
				var w = weights[v * 4 + k]
				if w <= 0.0:
					continue
				var sb = bones[v * 4 + k]
				var b = skin_bones[sb] if sb < skin_bones.size() else -1
				out_bones[v * 4 + k] = _bind(skin, binds, sk, bon, b)
				out_weights[v * 4 + k] = w
				sum += w
			if sum <= 0.0:
				out_bones[v * 4] = _bind(skin, binds, sk, bon, -1)
				out_weights[v * 4] = 1.0
			else:
				for k in 4:
					out_weights[v * 4 + k] /= sum
		_add_surface(mesh, m, out_bones, out_weights, ski, materials)
	for m in ski["rigid_meshes"]:
		if m["indices"].is_empty():
			continue
		var b = m["bone"] if m["bone"] >= 0 and m["bone"] < bon["bones"].size() else -1
		var bind = _bind(skin, binds, sk, bon, b)
		var nv = m["positions"].size()
		var out_bones = PackedInt32Array()
		var out_weights = PackedFloat32Array()
		out_bones.resize(nv * 4)
		out_weights.resize(nv * 4)
		for v in nv:
			out_bones[v * 4] = bind
			out_weights[v * 4] = 1.0
		_add_surface(mesh, m, out_bones, out_weights, ski, materials)
	if mesh.get_surface_count() == 0:
		_warn(ski["path"].get_file() + ": keine Meshes")
		return null
	var mi = MeshInstance3D.new()
	mi.name = _clean_name(ski["path"].get_file().get_basename(), "Skin")
	mi.mesh = mesh
	mi.skin = skin
	mi.skeleton = NodePath("..") # hängt unter dem Skeleton3D (in Godot 4 ist der Pfad sonst leer)
	mi.set_meta("ski_path", ski["path"])
	return mi

# Bind für einen Skelett-Bone (-1 = Skelett selbst, Bind-Pose = Einheitsmatrix)
func _bind(skin: Skin, binds: Dictionary, sk: Skeleton3D, bon: Dictionary, bone: int) -> int:
	if binds.has(bone):
		return binds[bone]
	if bone < 0:
		skin.add_named_bind(sk.get_bone_name(_root_bone(sk)), Transform3D.IDENTITY)
	else:
		skin.add_named_bind(sk.get_bone_name(bone), bon["bones"][bone]["init"])
	binds[bone] = skin.get_bind_count() - 1
	return binds[bone]

func _add_surface(mesh: ArrayMesh, m: Dictionary, bones: PackedInt32Array, weights: PackedFloat32Array, ski: Dictionary, materials: Dictionary) -> void:
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = m["positions"]
	arrays[Mesh.ARRAY_NORMAL] = m["normals"]
	arrays[Mesh.ARRAY_TEX_UV] = m["uvs"]
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = m["indices"]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var s = mesh.get_surface_count() - 1
	mesh.surface_set_name(s, _clean_name(m["name"], "Mesh_%d" % s))
	var key = "%d_%d" % [m["texture"], m["material"]]
	if not materials.has(key):
		materials[key] = _material(ski, m["texture"], m["material"])
	mesh.surface_set_material(s, materials[key])


# ====================================================
# MATERIAL + TEXTUR
# ====================================================
func _material(ski: Dictionary, tex_index: int, mat_index: int) -> Material:
	var data = ski["materials"][mat_index] if mat_index >= 0 and mat_index < ski["materials"].size() else {}
	var tex_name: String = ski["textures"][tex_index] if tex_index >= 0 and tex_index < ski["textures"].size() else ""
	var tex = _texture(ski, tex_name) if tex_name != "" else null
	if tex != null and tex_name.replace("\\", "/").get_file().to_lower().begins_with(REFLECT_PREFIX):
		var reflect_map = _reflect_map()
		if reflect_map != null:
			return _reflect_material(data, tex, reflect_map)
	var mat = StandardMaterial3D.new()
	mat.roughness = 1.0
	if not data.is_empty():
		mat.resource_name = data["name"]
		var d: Color = data.get("diffuse", Color.WHITE)
		mat.albedo_color = Color(d.r, d.g, d.b, d.a)
		mat.metallic_specular = clampf(data.get("specular", Color.BLACK).get_luminance(), 0.0, 1.0)
		var e: Color = data.get("emissive", Color.BLACK)
		if e.r + e.g + e.b > 0.0:
			mat.emission_enabled = true
			mat.emission = Color(e.r, e.g, e.b)
		if data["two_sided"]:
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		if d.a < 0.999:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if tex != null:
		mat.albedo_texture = tex
		# Emissive wirkt im Spiel (Fixed Function: Textur * (Emissive + Licht)) über die Textur, nicht flach
		if mat.emission_enabled:
			mat.emission_texture = tex
		if mat.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED and tex is ImageTexture and (tex as ImageTexture).get_format() in ALPHA_FORMATS:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			mat.alpha_scissor_threshold = ALPHA_REF
	return mat

# armor.sdr (siehe REFLECT_SHADER): deckend, Material-Farbe, -Glanz und -Leuchten wie beim
# StandardMaterial3D; Material-Alpha < 1 -> durchsichtig wie dort
func _reflect_material(data: Dictionary, tex: Texture2D, reflect_map: Texture2D) -> ShaderMaterial:
	var d: Color = data.get("diffuse", Color.WHITE)
	var two_sided: bool = data.get("two_sided", false)
	var transparent = d.a < 0.999
	var key = "%s_%s" % [two_sided, transparent]
	if not _reflect_shaders.has(key):
		var shader = Shader.new()
		shader.code = REFLECT_SHADER.replace("{cull}", "cull_disabled" if two_sided else "cull_back") \
			.replace("{alpha}", "\n\tALPHA = albedo.a;" if transparent else "")
		_reflect_shaders[key] = shader
	var mat = ShaderMaterial.new()
	mat.shader = _reflect_shaders[key]
	mat.resource_name = data.get("name", "")
	var e: Color = data.get("emissive", Color.BLACK)
	mat.set_shader_parameter("albedo", d)
	mat.set_shader_parameter("texture_albedo", tex)
	mat.set_shader_parameter("texture_reflect", reflect_map)
	mat.set_shader_parameter("specular", clampf(data.get("specular", Color.BLACK).get_luminance(), 0.0, 1.0))
	mat.set_shader_parameter("emission", Color(e.r, e.g, e.b))
	return mat

func _reflect_map() -> Texture2D:
	var src = files.resolve(REFLECT_MAP)
	for root in extra_roots:
		if src == "":
			src = files.resolve(REFLECT_MAP, root)
	if src == "":
		_warn("Reflexions-Map " + REFLECT_MAP + " nicht gefunden, Waffen-Texturen r_... ohne Reflexion")
		return null
	return texture_file(src, REFLECT_MAP)

# A3DSkin::Load: <Ordner der .ski>\Textures\<Name>, sonst \Tex_<Name der .ski>\<Name>
func _texture(ski: Dictionary, tex_name: String) -> Texture2D:
	var ski_dir = ski["path"].get_base_dir()
	var src = files.resolve("Textures/" + tex_name, ski_dir)
	if src == "":
		src = files.resolve("Tex_" + ski["path"].get_file().get_basename() + "/" + tex_name, ski_dir)
	if src == "":
		_warn(ski["path"].get_file() + ": Textur " + tex_name + " nicht gefunden")
		return null
	return texture_file(src, ski["path"].get_file() + ": Textur " + tex_name)

# Textur der Spieldaten laden (kopiert bzw. als .res gespeichert, siehe texture_dest), auch für GFX
func texture_file(src: String, label: String) -> Texture2D:
	if _tex_cache.has(src):
		return _tex_cache[src]
	var tex: Texture2D = null
	var dest: String = texture_dest.call(src)
	var dds = src.get_extension().to_lower() == "dds"
	var bytes = _fs().get_bytes(src) # entpackt oder aus dem Paket
	var img: Image = null
	if dds:
		# Godot liest DXT1 ohne Alpha (BC1 RGB): durchsichtige Pixel (1-Bit-Alpha) würden schwarz.
		# DXT1 mit Alpha und .dds, die Godot nicht liest, selbst entpacken.
		var dxt1 = _dds_fourcc(bytes) == "DXT1"
		if dxt1 or not _godot_reads_dds(bytes):
			img = _dds_top_image(bytes)
			if img != null and dxt1 and img.get_format() == Image.FORMAT_RGB8 and _godot_reads_dds(bytes):
				img = null
	if dds and img == null and _godot_reads_dds(bytes):
		if dest != "":
			# unverändert als .dds unter res://ECM_Import (Godot lädt .dds ohne Import)
			DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
			if not FileAccess.file_exists(dest) or _file_size(dest) != bytes.size():
				var f = FileAccess.open(dest, FileAccess.WRITE)
				if f != null:
					f.store_buffer(bytes)
					f.close()
					written.append(dest)
			var loaded = load(dest)
			tex = loaded if loaded is Texture2D else null
		else:
			var dimg = Image.new()
			if dimg.load_dds_from_buffer(bytes) == OK and not dimg.is_empty():
				tex = ImageTexture.create_from_image(dimg)
	else:
		# .tga, .bmp & Co. und selbst entpackte .dds: als ImageTexture (.res) speichern,
		# .psd kann Godot nicht lesen
		if not dds:
			img = _fs().image_from_bytes(bytes, src.get_extension())
		if img != null and not img.is_empty():
			tex = ImageTexture.create_from_image(img)
			if dest != "":
				dest = dest.get_basename() + ".res"
				DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
				tex.take_over_path(dest)
				if ResourceSaver.save(tex, dest) == OK:
					register_uid(dest)
				written.append(dest)
	if tex == null:
		_warn(label + " nicht lesbar")
	_tex_cache[src] = tex
	return tex

# Datei-Zugriff (angelica_files.gd); Bauer nur für Bilder (z.B. der Oberfläche) haben keinen und
# bekommen hier einen, Pfade sind dann absolut
func _fs():
	if files == null:
		files = load(get_script().resource_path.get_base_dir().path_join("../Data/angelica_files.gd").simplify_path()).new()
	return files

# UID einer eben gespeicherten Datei sofort bekannt machen: lädt der Import gleich eine Szene, die
# sie nennt (z.B. die Gebäude der Map), fände Godot sie sonst erst nach dem nächsten Scan des
# Editors ("invalid UID")
static func register_uid(path: String) -> void:
	var uid = ResourceLoader.get_resource_uid(path)
	if uid == ResourceUID.INVALID_ID:
		return
	if ResourceUID.has_id(uid):
		ResourceUID.set_id(uid, path)
	else:
		ResourceUID.add_id(uid, path)

# Bild einer Textur der Spieldaten zum Weiterverarbeiten (z.B. Bodentexturen des Terrains):
# DXT-.dds selbst entpackt (oberste Stufe), sonst wie Godot lädt; null = nicht lesbar
func image_file(src: String) -> Image:
	var bytes = _fs().get_bytes(src)
	if src.get_extension().to_lower() == "dds":
		var img = _dds_top_image(bytes)
		if img != null:
			return img
	return _fs().image_from_bytes(bytes, src.get_extension())

# Godot liest die meisten .dds selbst, zwei Sorten aus den Spieldaten nicht:
#  - als Volumen markiert (DDSCAPS2_VOLUME, Tiefe 1): wird eine Texture3D
#  - unvollständige Mipmap-Kette (z.B. nur 2 Stufen): Godot erwartet alle Stufen bis 1x1
func _godot_reads_dds(b: PackedByteArray) -> bool:
	if b.size() < 128:
		return true
	var w = b.decode_u32(16)
	var h = b.decode_u32(12)
	var mips = b.decode_u32(28) if b.decode_u32(8) & DDSD_MIPMAPCOUNT else 1
	var full = int(floor(log(maxf(1.0, maxi(w, h))) / log(2.0))) + 1
	return b.decode_u32(112) & DDSCAPS2_VOLUME == 0 and (mips <= 1 or mips == full)

# FourCC einer .dds ("" = unkomprimiert / keine .dds)
func _dds_fourcc(b: PackedByteArray) -> String:
	if b.size() < 128 or b.decode_u32(80) & DDPF_FOURCC == 0:
		return ""
	return b.slice(84, 88).get_string_from_ascii()

func _file_size(path: String) -> int:
	var f = FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f != null else -1

# Oberste Stufe einer DXT1/3/5-.dds selbst lesen, mit neuen Mipmaps (null = andere Art).
# DXT1 mit 1-Bit-Alpha bleibt mit Alpha (als DXT5), ohne Alpha RGB; DXT3/5 entpackt.
func _dds_top_image(b: PackedByteArray) -> Image:
	if b.size() < 128 or b.decode_u32(80) & DDPF_FOURCC == 0:
		return null
	var fmt = DDS_FORMATS.get(b.slice(84, 88).get_string_from_ascii(), -1)
	if fmt < 0:
		return null
	var w = b.decode_u32(16)
	var h = b.decode_u32(12)
	var size = maxi(1, (w + 3) / 4) * maxi(1, (h + 3) / 4) * (8 if fmt == Image.FORMAT_DXT1 else 16)
	if w == 0 or h == 0 or b.size() < 128 + size:
		return null
	var img = Image.create_from_data(w, h, false, fmt, b.slice(128, 128 + size))
	img.decompress()
	var alpha = fmt == Image.FORMAT_DXT1 and img.detect_alpha() != Image.ALPHA_NONE
	if fmt == Image.FORMAT_DXT1 and not alpha:
		img.convert(Image.FORMAT_RGB8)
	img.generate_mipmaps()
	if alpha:
		img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB) # DXT5, klein wie das Original (GENERIC nähme bei Grau / Rot RGTC)
	return img


# ====================================================
# AKTIONEN
# ====================================================
func build_actions(smd: Dictionary, bon: Dictionary, sk: Skeleton3D) -> AnimationLibrary:
	var lib = AnimationLibrary.new()
	var fps = maxi(1, bon["fps"]) # Aktionen der .smd v8 laufen im Takt des Skeletts
	var smd_dir = smd["path"].get_base_dir()
	var tck_dir = files.resolve(smd["tcks"], smd_dir) if smd["tcks"] != "" else smd_dir
	for act in smd["actions"]:
		var stck_path = files.resolve(act["stck"], tck_dir) if tck_dir != "" else ""
		if stck_path == "":
			_warn("Aktion " + act["name"] + ": " + act["stck"] + " nicht gefunden")
			continue
		if not _stck_cache.has(stck_path):
			_stck_cache[stck_path] = reader.read_stck(stck_path)
		var st: Dictionary = _stck_cache[stck_path]
		if st.has("error"):
			_warn("Aktion " + act["name"] + ": " + st["error"])
			continue
		var anim = _build_action(act, st, fps, bon, sk)
		var name = _clean_name(act["name"], "Aktion")
		var base = name
		var k = 2
		while lib.has_animation(name):
			name = "%s_%d" % [base, k]
			k += 1
		lib.add_animation(name, anim)
	return lib

func _build_action(act: Dictionary, st: Dictionary, fps: int, bon: Dictionary, sk: Skeleton3D) -> Animation:
	# A3DSkinModelActionCore::FrameToTime
	var t0 = int(act["start"] * 1000.0 / fps)
	var t1 = maxi(t0, int(act["end"] * 1000.0 / fps))
	var anim = Animation.new()
	anim.length = maxf((t1 - t0) / 1000.0, 1.0 / fps)
	anim.loop_mode = Animation.LOOP_LINEAR
	anim.step = 1.0 / st["fps"]
	var times = PackedInt32Array()
	var step = 1000.0 / st["fps"]
	var k = 0
	while t0 + k * step < t1 - 0.5:
		times.append(int(t0 + k * step))
		k += 1
	times.append(t1)
	var bones: Array = bon["bones"]
	for b in bones.size():
		var track = st["tracks"].get(bones[b]["first_joint"], null)
		if track == null:
			continue
		var path = NodePath("Skeleton3D:" + sk.get_bone_name(b))
		_add_track(anim, Animation.TYPE_POSITION_3D, path, track["pos"], times, t0)
		_add_track(anim, Animation.TYPE_ROTATION_3D, path, track["rot"], times, t0)
		var flipped = (bones[b]["flags"] & reader.BONE_FLAG_FLIPPED) != 0
		var scale = Vector3(-1.0, 1.0, 1.0) if flipped else Vector3.ONE
		if flipped or not sk.get_bone_rest(b).basis.get_scale().is_equal_approx(Vector3.ONE):
			var ti = anim.add_track(Animation.TYPE_SCALE_3D)
			anim.track_set_path(ti, path)
			anim.scale_track_insert_key(ti, 0.0, scale)
	return anim

# Abgetastete Spur; bleibt der Wert gleich, genügt ein Key
func _add_track(anim: Animation, type: int, path: NodePath, track: Dictionary, times: PackedInt32Array, t0: int) -> void:
	var values = []
	var constant = true
	for t in times:
		var v = reader.track_value(track, t)
		if v == null:
			return
		if type == Animation.TYPE_ROTATION_3D:
			v = (v as Quaternion).normalized()
		if not values.is_empty() and constant and not v.is_equal_approx(values[0]):
			constant = false
		values.append(v)
	var ti = anim.add_track(type)
	anim.track_set_path(ti, path)
	for i in (1 if constant else values.size()):
		var time = (times[i] - t0) / 1000.0
		if type == Animation.TYPE_ROTATION_3D:
			anim.rotation_track_insert_key(ti, time, values[i])
		else:
			anim.position_track_insert_key(ti, time, values[i])
