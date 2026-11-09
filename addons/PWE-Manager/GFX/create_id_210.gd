@tool
extends "create_id_140.gd"

# ====================================================
# GFXELEMENTID 210 = ID_ELE_TYPE_GRID_DECAL_3D (A3DGridDecalEx)
# ====================================================
# Ein frei verformtes Gitter aus wNumber x hNumber Punkten (Zeile für Zeile in der Datei,
# je Punkt "x y z" + "dwColor: AARRGGBB"), jedes Feld = 2 Dreiecke (0, 1, 2) / (1, 3, 2).
#   Textur: U über die Spalten, V über die Zeilen (UReverse / VReverse drehen sie um),
#           im Spritesheet-Feld m_fTexU / m_fTexWid bzw. TileMode; UVExchg tauscht danach U und V.
#   Farbe : je Kanal (Punktfarbe * KeyPoint-Farbe) >> 8 (_setColorComposed),
#           unter KeyPoint-Alpha 5 wird nicht gezeichnet (Update_3D).
#   Lage  : GetTranMatrix(kp) = Richtung * Rad_2D um Z + Position, OHNE KeyPoint-Scale;
#           AffByScl: danach * Scale (auch die Position), wie GetTranMatrix(kp) * Scaling * ParentTM.
#   RotFromView: Gitter-Ebene zur Kamera gedreht (Welt-Raum), Achsen aus KeyPoint-Richtung (lokales Z)
#           und Blickrichtung, Scale = GFX-Scale (* KeyPoint-Scale bei AffByScl), ohne Rad_2D.
#   Grid-Animation (keyNumber, ab Version 99): bis zu 5 Schlüssel mit allen Punkten (Base64),
#           A3DGfxGridAnimation::GetValue mischt Position / Farbe nach der Element-Zeit ab StartTime.
#           Nur bei höchstens 100 Punkten (nVertsLimit), sonst gilt das Gitter aus der Datei.
# MatchGrnd / bAlwaysOnGround (Punkte auf den Boden) braucht das Terrain des Spiels -> nicht umgesetzt.
# fGridSize / fZOffset wirken nur im Editor bzw. bei 211 (2D).
# Gitter und Grid-Animation stehen beim Erstellen fest (Mesh / Daten-Textur).
# ====================================================

const MAX_ANIM_VERTS = 100 # A3DGfxGridAnimation::nVertsLimit
const MAX_ANIM_KEYS = 5
# Werden fest ins Mesh / in die Daten-Textur gebaut -> kein eigener Uniform
const STRUCTURE_PARAMS = ["wNumber", "hNumber", "keyNumber"]

var _grid = {}


func _element_id() -> String:
	return "210"

func _node_name() -> String:
	return "GridDecal_GFX"

func _skip_main_param(key: String) -> bool:
	return key in STRUCTURE_PARAMS or key.begins_with("GridVector") or key.begins_with("dwColor")


# ====================================================
# GITTER AUS parsed_data (A3DGridDecalEx::Load)
# ====================================================
# {w, h, pos: PackedVector3Array, col: PackedColorArray, key_times: Array, key_tex: ImageTexture / null}
func read_grid(parsed_data: Dictionary) -> Dictionary:
	var w = maxi(0, int(parsed_data.get("wNumber", 0)))
	var h = maxi(0, int(parsed_data.get("hNumber", 0)))
	var n = w * h
	var pos = PackedVector3Array()
	var col = PackedColorArray()
	for i in range(1, n + 1):
		# Fehlende Zeilen = GRID_VERTEX_DATA(): Position 0, Farbe weiß
		var p = str(parsed_data.get("GridVector_" + str(i), "")).split(" ", false)
		pos.append(Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float()) if p.size() >= 3 else Vector3.ZERO)
		col.append(_argb_to_color(_hex_u32(parsed_data.get("dwColor" if i == 1 else "dwColor_" + str(i), "ffffffff"))))
	var grid = {"w": w, "h": h, "pos": pos, "col": col, "key_times": [], "key_tex": null}
	_read_grid_animation(parsed_data, grid)
	return grid

# GRID_ANIM_KEY::Load: je Schlüssel Base64 von int Zeit + n * (float x, y, z, A3DCOLOR).
# Der Parser hängt alle Zeilen aneinander -> nach der festen Länge je Schlüssel trennen.
func _read_grid_animation(parsed_data: Dictionary, grid: Dictionary) -> void:
	var n = grid["w"] * grid["h"]
	var keys = mini(int(parsed_data.get("keyNumber", 0)), MAX_ANIM_KEYS)
	var lines = parsed_data.get("_grid_animations", [])
	# GetValue tut bei mehr als nVertsLimit Punkten nichts
	if keys <= 0 or n <= 0 or n > MAX_ANIM_VERTS or lines.is_empty():
		return
	var text = "".join(PackedStringArray(lines)).strip_edges()
	var key_bytes = 4 + 16 * n
	var key_len = int(ceil(key_bytes / 3.0)) * 4
	var data = PackedFloat32Array()
	var times = []
	for k in range(keys):
		var raw = Marshalls.base64_to_raw(text.substr(k * key_len, key_len))
		if raw.size() < key_bytes:
			push_warning("Grid-Animation: Schlüssel " + str(k) + " unvollständig -> Grid-Animation übersprungen")
			return
		times.append(float(raw.decode_s32(0)))
		var row_pos = PackedFloat32Array()
		var row_col = PackedFloat32Array()
		for i in range(n):
			var o = 4 + 16 * i
			row_pos.append_array([raw.decode_float(o), raw.decode_float(o + 4), raw.decode_float(o + 8), 0.0])
			var argb = raw.decode_u32(o + 12)
			# Farbe als 0..255 (Interp_Color rechnet und schneidet in ganzen Kanalwerten)
			row_col.append_array([float((argb >> 16) & 0xFF), float((argb >> 8) & 0xFF), float(argb & 0xFF), float((argb >> 24) & 0xFF)])
		data.append_array(row_pos)
		data.append_array(row_col)
	# Zeile 2k = Position, Zeile 2k + 1 = Farbe von Schlüssel k, Spalte = Punkt
	var img = Image.create_from_data(n, keys * 2, false, Image.FORMAT_RGBAF, data.to_byte_array())
	grid["key_times"] = times
	grid["key_tex"] = ImageTexture.create_from_image(img)

func _hex_u32(value) -> int:
	var s = str(value).strip_edges().to_lower().trim_prefix("0x")
	return s.hex_to_int() & 0xFFFFFFFF if s.is_valid_hex_number() else 0xFFFFFFFF

func _argb_to_color(argb: int) -> Color:
	return Color8((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >> 24) & 0xFF)


# ====================================================
# SHADER-HOOKS
# ====================================================
func _gen_element_uniforms(_parent_node: Node, parsed_data: Dictionary, declared: Dictionary, uniform_assignments: Dictionary, _ctrl_methods: Array) -> String:
	_grid = read_grid(parsed_data)
	var c = "const int GD_W = " + str(maxi(1, _grid["w"])) + ";\n"
	var keys = _grid["key_times"].size()
	c += "const int GD_KEYS = " + str(keys) + "; // Grid-Animation: Anzahl Schlüssel\n"
	if keys > 0:
		var t = []
		for kt in _grid["key_times"]:
			t.append(_f(kt))
		c += "const float GD_KEY_TIME[" + str(keys) + "] = float[" + str(keys) + "](" + ", ".join(PackedStringArray(t)) + ");\n"
		c += "group_uniforms Grid_Animation;\n"
		c += "// Zeile 2k = Positionen, 2k + 1 = Farben (0..255) von Schlüssel k\n"
		c += KeyPointShader.declare(declared, "sampler2D", "Grid_Anim_Keys", " : filter_nearest")
		c += "group_uniforms;\n"
		uniform_assignments["Grid_Anim_Keys"] = _grid["key_tex"]
	return c + "\n"


func _gen_element_functions(_declared: Dictionary) -> String:
	if _grid["key_times"].is_empty():
		return ""
	var c = "// A3DGfxGridAnimation::GetValue (t = ms ab StartTime)\n"
	c += "void gd_grid_anim(float t, int idx, out vec3 pos, out vec4 col) {\n"
	c += "\tint a = 0;\n"
	c += "\tint b = 0;\n"
	c += "\tfloat r = 0.0;\n"
	c += "\tif (GD_KEYS > 1) {\n"
	c += "\t\tif (t < GD_KEY_TIME[0]) {\n"
	c += "\t\t\ta = 0; b = 0;\n"
	c += "\t\t} else if (t >= GD_KEY_TIME[GD_KEYS - 1]) {\n"
	c += "\t\t\ta = GD_KEYS - 1; b = a;\n"
	c += "\t\t} else {\n"
	c += "\t\t\tfor (int k = 1; k < GD_KEYS; k++) {\n"
	c += "\t\t\t\tif (t < GD_KEY_TIME[k]) {\n"
	c += "\t\t\t\t\ta = k - 1; b = k;\n"
	c += "\t\t\t\t\tr = (t - GD_KEY_TIME[a]) / (GD_KEY_TIME[b] - GD_KEY_TIME[a]);\n"
	c += "\t\t\t\t\tbreak;\n"
	c += "\t\t\t\t}\n"
	c += "\t\t\t}\n"
	c += "\t\t}\n"
	c += "\t}\n"
	c += "\tpos = texelFetch(Grid_Anim_Keys, ivec2(idx, a * 2), 0).xyz * (1.0 - r) + texelFetch(Grid_Anim_Keys, ivec2(idx, b * 2), 0).xyz * r;\n"
	c += "\t// Interp_Color: (int)(c1 * (1 - r) + c2 * r) je Kanal\n"
	c += "\tcol = floor(texelFetch(Grid_Anim_Keys, ivec2(idx, a * 2 + 1), 0) * (1.0 - r) + texelFetch(Grid_Anim_Keys, ivec2(idx, b * 2 + 1), 0) * r);\n"
	c += "}\n\n"
	return c


func _gen_vertex_body(declared: Dictionary) -> String:
	var c = _gen_grid_point()
	c += _gen_placement(declared)
	c += "\t// --- _setUVCoord: U über die Spalten, V über die Zeilen ---\n"
	c += "\tcell_uv = vec2(" + KeyPointShader.u(declared, "UReverse", "false") + " ? 1.0 - UV.x : UV.x, " + KeyPointShader.u(declared, "VReverse", "false") + " ? 1.0 - UV.y : UV.y);\n"
	return c

# Gitterpunkt gd_pos (lokal) und v_color, gemeinsam für 210 / 211
func _gen_grid_point() -> String:
	var c = "\t// --- Gitterpunkt (UV2 = Spalte, Zeile): Datei bzw. Grid-Animation ---\n"
	c += "\tvec3 gd_pos = VERTEX;\n"
	c += "\tvec4 gd_col = floor(COLOR * 255.0 + 0.5);\n"
	if not _grid["key_times"].is_empty():
		c += "\tgd_grid_anim(max(0.0, v_current_time - LocalStartTime), int(UV2.y) * GD_W + int(UV2.x), gd_pos, gd_col);\n"
	c += "\n\t// --- _setColorComposed: (Punktfarbe * KeyPoint-Farbe) >> 8 ---\n"
	c += "\tvec4 gd_diffuse = floor(k_color * 255.0 + 0.5);\n"
	c += "\tv_color = floor(gd_col * gd_diffuse / 256.0) / 255.0;\n"
	c += "\t// Update_3D / Update_2D: unter Alpha 5 zeichnet Angelica nichts\n"
	c += "\tif (gd_diffuse.a < 5.0) {\n"
	c += "\t\tv_active = 0.0;\n"
	c += "\t}\n\n"
	return c

# Fill_Verts_3D / Update_3D: setzt VERTEX aus gd_pos (211 überschreibt das mit Fill_Verts_2D)
func _gen_placement(declared: Dictionary) -> String:
	var u = func(name, fallback): return KeyPointShader.u(declared, name, fallback)
	var aff = u.call("AffByScl", "false")
	var c = "\tif (" + u.call("RotFromView", "false") + ") {\n"
	c += "\t\t// --- Fill_Verts_3D, m_bRotFromView: Welt-Raum, Achsen aus KeyPoint-Richtung und Kamera ---\n"
	c += "\t\tvec3 gd_c = (MODEL_MATRIX * vec4(k_pos, 1.0)).xyz;\n"
	c += "\t\tvec3 gd_dir = mat3(MODEL_MATRIX) * quat_rot(k_dir, vec3(0.0, 0.0, 1.0));\n"
	c += "\t\tvec3 gd_view = gd_c - CAMERA_POSITION_WORLD;\n"
	c += "\t\tvec3 gd_up = cross(gd_view, gd_dir);\n"
	c += "\t\tgd_view = cross(gd_dir, gd_up);\n"
	c += "\t\tgd_dir /= max(length(gd_dir), 0.000001);\n"
	c += "\t\tgd_view /= max(length(gd_view), 0.000001);\n"
	c += "\t\tgd_up /= max(length(gd_up), 0.000001);\n"
	c += "\t\t// matScale = GetActualScale() (* KeyPoint-Scale bei AffByScl)\n"
	c += "\t\tfloat gd_s = length(MODEL_MATRIX[0].xyz) * (" + aff + " ? k_scale : 1.0);\n"
	c += "\t\tvec3 gd_w = gd_c + (-gd_pos.y * gd_dir + gd_pos.x * gd_up + gd_pos.z * gd_view) * gd_s;\n"
	c += "\t\tVERTEX = (inverse(MODEL_MATRIX) * vec4(gd_w, 1.0)).xyz;\n"
	c += "\t} else {\n"
	c += "\t\t// --- GetTranMatrix(kp) (* Scaling(kp.Scale) bei AffByScl) ---\n"
	c += "\t\tvec3 gd_v = quat_rot(quat_mul(k_dir, quat_axis(vec3(0.0, 0.0, 1.0), k_rad)), gd_pos) + k_pos;\n"
	c += "\t\tVERTEX = " + aff + " ? gd_v * k_scale : gd_v;\n"
	c += "\t}\n\n"
	return c

# UVExchg tauscht die fertigen U / V (inkl. Spritesheet-Feld) wie gfx_swap(_pBufU, _pBufV)
func _gen_uv_post(declared: Dictionary) -> String:
	return "\tif (" + KeyPointShader.u(declared, "UVExchg", "false") + ") {\n\t\tUV = UV.yx;\n\t}\n"


# w * h gemeinsame Punkte: VERTEX / COLOR = Gitter aus der Datei, UV = (Spalte, Zeile) / (w - 1, h - 1),
# UV2 = (Spalte, Zeile); je Feld 2 Dreiecke wie der Index-Puffer der Render-Slots (0, 1, 2 / 1, 3, 2)
func _build_mesh(_parsed_data: Dictionary) -> ArrayMesh:
	var w: int = _grid["w"]
	var h: int = _grid["h"]
	var uvs = PackedVector2Array()
	var uv2s = PackedVector2Array()
	var indices = PackedInt32Array()
	for r in range(h):
		for col in range(w):
			uvs.append(Vector2(float(col) / float(maxi(1, w - 1)), float(r) / float(maxi(1, h - 1))))
			uv2s.append(Vector2(float(col), float(r)))
	for r in range(h - 1):
		for col in range(w - 1):
			var i1 = r * w + col
			var i3 = i1 + w
			indices.append_array([i1, i1 + 1, i3, i1 + 1, i3 + 1, i3])

	var mesh = ArrayMesh.new()
	if indices.is_empty():
		# Weniger als 2 x 2 Punkte: Angelica zeichnet nichts
		return mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _grid["pos"]
	arrays[Mesh.ARRAY_COLOR] = _grid["col"]
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
