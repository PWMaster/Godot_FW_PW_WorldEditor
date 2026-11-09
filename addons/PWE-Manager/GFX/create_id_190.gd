@tool
extends "create_id_140.gd"

# ====================================================
# GFXELEMENTID 190 = ID_ELE_TYPE_PARABOLOID (A3DParaboloid)
# ====================================================
# Ein Paraboloid (Schale) entlang der lokalen +Z-Achse, A3DParaboloid::Build:
#   n = clamp(int(height / 0.1), 1, 8) Ringe, Ring i bei z = i * height / n,
#   Radius = sqrt(Coeff * z), je 24 Segmente (alle 15 Grad).
# Textur radial von oben: Mitte = Texturmitte, äußerster Ring = eingeschriebener Kreis
#   tu = 0.5 + 0.5 * (i / n) * cos(Winkel), tv = 0.5 - 0.5 * (i / n) * sin(Winkel)
#   (im Spritesheet-Feld m_fTexU / m_fTexWid, wie beim Ring).
# Welt = Scale(KeyPoint-Scale) * Rotation(Dir * Rad_2D um Z) + Position, Farbe = KeyPoint-Farbe.
# FillVertexBuffer ignoriert UReverse / VReverse / UVExchg.
# Die Ringzahl steht beim Erstellen fest; Coeff / height lassen sich danach im Material ändern.
# ====================================================

const GRID_SIZE = 0.1 # _grid_sz
const MAX_CIRCLES = 8 # _max_circles
const SEGS = 24 # 360 / 15


func _element_id() -> String:
	return "190"

func _node_name() -> String:
	return "Paraboloid_GFX"


# A3DParaboloid::Build: Ringzahl aus der Höhe, in float32 wie in C++ (0.6 / 0.1 = 6, in double 5.999...)
# int() schneidet wie in C++ Richtung 0 ab
func _circles(parsed_data: Dictionary) -> int:
	var height = _f32(float(parsed_data.get("height", 0.0)))
	return clampi(int(_f32(height / _f32(GRID_SIZE))), 1, MAX_CIRCLES)

func _f32(value: float) -> float:
	return PackedFloat32Array([value])[0]


func _gen_element_uniforms(_parent_node: Node, parsed_data: Dictionary, _declared: Dictionary, _uniform_assignments: Dictionary, _ctrl_methods: Array) -> String:
	return "const float PB_CIRCLES = " + str(_circles(parsed_data)) + ".0;\n\n"


func _gen_vertex_body(declared: Dictionary) -> String:
	var u = func(name, fallback): return KeyPointShader.u(declared, name, fallback)
	var c = "\t// --- A3DParaboloid::Build (UV2 = Ring, Segment; Segment 24 = Naht) ---\n"
	c += "\tfloat pb_ring = UV2.x / PB_CIRCLES;\n"
	c += "\tfloat pb_ang = TAU / " + str(SEGS) + ".0 * mod(UV2.y, " + str(SEGS) + ".0);\n"
	c += "\tfloat pb_z = " + u.call("height", "0.0") + " * pb_ring;\n"
	c += "\t// sqrt(Coeff * z): bei verschiedenen Vorzeichen rechnet Angelica NaN, hier Radius 0\n"
	c += "\tfloat pb_r = sqrt(max(0.0, " + u.call("Coeff", "1.0") + " * pb_z));\n"
	c += "\tvec3 local_pos = vec3(pb_r * cos(pb_ang), pb_r * sin(pb_ang), pb_z);\n\n"
	c += "\t// --- FillVertexBuffer: Scale(kp) * GetTranMatrix(kp) ---\n"
	c += "\tVERTEX = quat_rot(quat_mul(k_dir, quat_axis(vec3(0.0, 0.0, 1.0), k_rad)), local_pos * k_scale) + k_pos;\n"
	c += "\tv_color = k_color;\n"
	c += "\tcell_uv = vec2(0.5 + 0.5 * pb_ring * cos(pb_ang), 0.5 - 0.5 * pb_ring * sin(pb_ang));\n"
	c += "\t// Das Paraboloid nutzt UReverse / VReverse / UVExchg nicht\n"
	return c


# (n + 1) Ringe zu je 25 Vertices (Segment 24 doppelt für die Naht), Bänder zwischen den Ringen.
# Die echte Form rechnet der Vertex-Shader aus Coeff / height.
func _build_mesh(parsed_data: Dictionary) -> ArrayMesh:
	var n = _circles(parsed_data)
	var height = float(parsed_data.get("height", 0.0))
	var coeff = float(parsed_data.get("Coeff", 1.0))
	var verts = PackedVector3Array()
	var uvs = PackedVector2Array()
	var uv2s = PackedVector2Array()
	var indices = PackedInt32Array()
	for i in range(n + 1):
		var f = float(i) / float(n)
		var z = height * f
		var r = sqrt(maxf(0.0, coeff * z))
		for j in range(SEGS + 1):
			var a = TAU / SEGS * (j % SEGS)
			verts.append(Vector3(r * cos(a), r * sin(a), z))
			uvs.append(Vector2(0.5 + 0.5 * f * cos(a), 0.5 - 0.5 * f * sin(a)))
			uv2s.append(Vector2(float(i), float(j)))
	for i in range(n):
		var b1 = i * (SEGS + 1)
		var b2 = b1 + SEGS + 1
		for j in range(SEGS):
			indices.append_array([b1 + j, b2 + j, b1 + j + 1, b2 + j, b2 + j + 1, b1 + j + 1])

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
