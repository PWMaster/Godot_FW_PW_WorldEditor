@tool
extends RefCounted

# ====================================================
# A3DGFXCtrlCurveMove::GenPath (A3DGFXKeyPoint.cpp)
# Gemeinsam genutzt von create_id_125 (Kurven-Emitter) und create_id_130 (CtrlType 110 am Licht).
# ====================================================

const DIV_NUM = 5 # _div_num in A3DGFXKeyPoint.cpp

# Liefert {points, ratios, dirs, quats} oder {} bei weniger als 3 Punkten.
#  ratios = normierte Bogenlänge (BezierPt::m_fRatio)
#  dirs   = normierte Segmentrichtung (A3DCurveEmitter::Init)
#  quats  = Ausrichtung pro Punkt für CalcDir (m_pDir, _build_matrix)
static func gen_path(verts: Array) -> Dictionary:
	var n = verts.size()
	if n < 3:
		return {}

	# Bezier-Kontrollpunkte (Tangente = (P[i+1] - P[i-1]) / 6)
	var buf_sz = 3 * n - 2
	var corner = []
	corner.resize(buf_sz)
	corner[0] = verts[0]
	corner[buf_sz - 1] = verts[n - 1]
	for i in range(1, n - 1):
		var diff = (verts[i + 1] - verts[i - 1]) / 6.0
		var base = 2 + (i - 1) * 3
		corner[base] = verts[i] - diff
		corner[base + 1] = verts[i]
		corner[base + 2] = verts[i] + diff
	corner[1] = corner[2] + (verts[0] - verts[1]) / 3.0
	corner[buf_sz - 2] = corner[buf_sz - 3] + (verts[n - 1] - verts[n - 2]) / 3.0

	# Pro Segment DIV_NUM Zwischenpunkte
	var count = (n - 1) * DIV_NUM + n
	var points = PackedVector3Array()
	points.resize(count)
	for i in range(n - 1):
		var base = i * 3
		var insert = i * (DIV_NUM + 1)
		points[insert] = verts[i]
		for j in range(1, DIV_NUM + 1):
			points[insert + j] = bezier4(corner[base], corner[base + 1], corner[base + 2], corner[base + 3], j / float(DIV_NUM + 1))
	points[count - 1] = verts[n - 1]

	var ratios = PackedFloat32Array()
	ratios.resize(count)
	var dirs = PackedVector3Array()
	dirs.resize(count)
	var quats = []
	quats.resize(count)
	ratios[0] = 0.0
	for i in range(1, count):
		var seg = points[i] - points[i - 1]
		ratios[i] = ratios[i - 1] + seg.length()
		dirs[i - 1] = seg.normalized()
		quats[i - 1] = build_quat(dirs[i - 1])
	dirs[count - 1] = dirs[count - 2]
	quats[count - 1] = quats[count - 2]
	var total = ratios[count - 1]
	if total > 0.0:
		for i in range(1, count):
			ratios[i] /= total
	return {"points": points, "ratios": ratios, "dirs": dirs, "quats": quats, "total_len": total}

# A3DGFXCtrlCurveMove::GetInterpPoint (Suche ab Punkt 0) -> {pos, quat}
static func interp_point(path: Dictionary, ratio: float) -> Dictionary:
	var points: PackedVector3Array = path["points"]
	var ratios: PackedFloat32Array = path["ratios"]
	var quats: Array = path["quats"]
	var n = points.size()
	var cur = 0
	while cur + 1 < n:
		if ratio <= ratios[cur + 1]:
			break
		cur += 1
	if cur + 1 >= n:
		return {"pos": points[n - 1], "quat": quats[n - 1]}
	var f = (ratio - ratios[cur]) / maxf(ratios[cur + 1] - ratios[cur], 0.000001)
	return {"pos": points[cur].lerp(points[cur + 1], f), "quat": (quats[cur] as Quaternion).slerp(quats[cur + 1], f)}

static func bezier4(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var rt = 1.0 - t
	return rt * rt * rt * p0 + (3.0 * rt * rt * t) * p1 + (3.0 * rt * t * t) * p2 + t * t * t * p3

# _build_matrix(vDir, 0): Achsen X, Y und Z = vDir als Quaternion
static func build_quat(d: Vector3) -> Quaternion:
	if d.length() < 0.000001:
		return Quaternion.IDENTITY
	var x: Vector3
	var y: Vector3
	if absf(d.y) > 0.999:
		y = d.cross(Vector3.RIGHT).normalized()
		x = y.cross(d)
	else:
		x = Vector3.UP.cross(d).normalized()
		y = d.cross(x)
	return Quaternion(Basis(x, y, d).orthonormalized())
