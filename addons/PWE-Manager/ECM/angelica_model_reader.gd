@tool
extends RefCounted

# ====================================================
# Liest die Angelica-2-Modelldateien (wie A3DSkinModelMan / A3DSkeleton / A3DSkin /
# A3DSklTrackSet in Angelica2.2/Angelica3D). Alle beginnen mit "MOXB" (AFile binär).
#   .smd v8:  Skelett (.bon), Skins (.ski), Aktionen (Name, Start-/End-Frame, .stck)
#   .bon v6:  Bones (Relativ- und BoneInit-Matrix, Flags), Joints, Hooks
#   .ski v9:  Bone-Namen, Texturen, Materialien, Skin- und Rigid-Meshes
#   .stck v1: je Joint eine Positions- und eine Rotationsspur (Keys + Segmente)
# Matrizen sind Zeilenvektor-Matrizen (v * M): Zeile 0-2 = Achsen, Zeile 3 = Position;
# in Godot werden die Zeilen zu Spalten. Koordinaten bleiben wie in Angelica (wie im GFX-Plugin).
# Ältere Versionen (unter 1 % der Spieldaten) liefern {"error": ...}.
# ====================================================

const BONE_FLAG_FLIPPED = 0x02 # A3DBone::FLAG_FLIPPED: X-Achse gespiegelt
const SLERP_EPSILON = 0.25 # SLERPQuad: darüber linear

var files # angelica_files.gd (GBK-Text)


func _init(p_files) -> void:
	files = p_files


# Lesezeiger über die Bytes einer Datei
class Bin:
	var b: PackedByteArray
	var p = 0
	var ok = true

	func _init(bytes: PackedByteArray) -> void:
		b = bytes

	func need(n: int) -> bool:
		if n < 0 or p + n > b.size():
			ok = false
		return ok

	func i32() -> int:
		if not need(4):
			return 0
		p += 4
		return b.decode_s32(p - 4)

	func f32() -> float:
		if not need(4):
			return 0.0
		p += 4
		return b.decode_float(p - 4)

	func raw(n: int) -> PackedByteArray:
		if not need(n):
			return PackedByteArray()
		p += n
		return b.slice(p - n, p)

	func skip(n: int) -> void:
		if need(n):
			p += n

	# AString: int32 Länge + Bytes
	func astr() -> PackedByteArray:
		var n = i32()
		if n > 65536:
			ok = false
			return PackedByteArray()
		return raw(n)

	# char*: bis zum Nullbyte
	func zstr() -> PackedByteArray:
		var e = b.find(0, p)
		if e < 0:
			ok = false
			return PackedByteArray()
		var v = b.slice(p, e)
		p = e + 1
		return v

	# A3DMATRIX4 (Zeilen) -> Transform3D (Spalten)
	func mat() -> Transform3D:
		var f = raw(64).to_float32_array()
		if f.size() < 16:
			return Transform3D.IDENTITY
		return Transform3D(Basis(Vector3(f[0], f[1], f[2]), Vector3(f[4], f[5], f[6]), Vector3(f[8], f[9], f[10])), Vector3(f[12], f[13], f[14]))

func _open(path: String, ident: String) -> Bin:
	var r = Bin.new(files.get_bytes(path))
	if r.raw(4).get_string_from_ascii() != "MOXB" or r.raw(4).get_string_from_ascii() != ident:
		return null
	return r

func _err(path: String, msg: String) -> Dictionary:
	return {"error": path.get_file() + ": " + msg}

func _text(b: PackedByteArray) -> String:
	return files.decode_gbk(b)


# ====================================================
# .smd (A3DSkinModelMan::LoadModelFromFile)
# ====================================================
func read_smd(path: String) -> Dictionary:
	var r = _open(path, "DMSA")
	if r == null:
		return _err(path, "keine Angelica-.smd")
	var ver = r.i32()
	var n_skin = r.i32()
	var n_act = r.i32()
	var n_hanger = r.i32()
	r.skip(4 + 60) # iNumProp, aReserved
	if ver != 8:
		return _err(path, ".smd-Version %d wird noch nicht unterstützt" % ver)
	var out = {"path": path, "bon": _text(r.astr()), "skins": [], "actions": [], "hangers": n_hanger}
	for i in n_skin:
		out["skins"].append(_text(r.astr()))
	out["phys"] = _text(r.astr())
	out["tcks"] = _text(r.astr())
	for i in n_act:
		var act = {"name": _text(r.astr()), "start": r.f32(), "end": r.f32()}
		act["stck"] = _text(r.astr())
		out["actions"].append(act)
	if not r.ok:
		return _err(path, "Datei zu kurz")
	return out


# ====================================================
# .bon (A3DSkeleton::Load, A3DBone::Load, A3DSkeletonHook::Load)
# ====================================================
func read_bon(path: String) -> Dictionary:
	var r = _open(path, "EKSA")
	if r == null:
		return _err(path, "keine Angelica-.bon")
	var ver = r.i32()
	var n_bone = r.i32()
	var n_joint = r.i32()
	var n_hook = r.i32()
	r.skip(8) # iAnimStart, iAnimEnd
	var fps = r.i32()
	r.skip(64)
	if ver != 6:
		return _err(path, ".bon-Version %d wird noch nicht unterstützt" % ver)
	var bones = []
	for i in n_bone:
		var bone = {"name": _text(r.astr())}
		var flags = r.raw(4) # BYTE + 3 Füllbytes (BONEDATA ist nicht gepackt)
		bone["flags"] = flags[0] if flags.size() == 4 else 0
		bone["parent"] = r.i32()
		bone["first_joint"] = r.i32()
		var n_child = r.i32()
		bone["rel"] = r.mat() # matRelative: Bone -> Eltern
		bone["init"] = r.mat() # matBoneInit: Mesh -> Bone (inverse Bind-Pose)
		r.skip(4 * n_child)
		bones.append(bone)
	r.skip(4 * n_joint) # Joint-Typen
	var joints = []
	for i in n_joint:
		var joint = {"name": _text(r.astr()), "parent_bone": r.i32(), "child_bone": r.i32()}
		r.skip(4) # iSiblingJoint
		joints.append(joint)
	var hooks = []
	for i in n_hook:
		var hook = {"name": _text(r.astr())}
		hook["type"] = r.i32()
		hook["bone"] = r.i32()
		hook["tm"] = r.mat() # relativ zum Bone (bzw. zum Skelett bei bone < 0)
		hooks.append(hook)
	if not r.ok or r.p != r.b.size():
		return _err(path, "Format passt nicht")
	return {"path": path, "fps": fps, "bones": bones, "joints": joints, "hooks": hooks}


# ====================================================
# .ski (A3DSkin::Load, A3DMaterial::Load, A3DSkinMesh / A3DRigidMesh::Load)
# ====================================================
func read_ski(path: String) -> Dictionary:
	var r = _open(path, "IKSA")
	if r == null:
		return _err(path, "keine Angelica-.ski")
	var ver = r.i32()
	var n_skin = r.i32()
	var n_rigid = r.i32()
	var n_morph = r.i32() + r.i32()
	var n_tex = r.i32()
	var n_mat = r.i32()
	var n_bone = r.i32()
	r.skip(8) # fMinWeight, iNumSkeBone
	var n_other = r.i32() + r.i32() # Supple, Muscle
	r.skip(52)
	if ver != 9:
		return _err(path, ".ski-Version %d wird noch nicht unterstützt" % ver)
	if n_morph + n_other > 0:
		return _err(path, "Morph-/Supple-/Muscle-Meshes werden nicht unterstützt")
	var out = {"path": path, "bone_names": [], "textures": [], "materials": [], "skin_meshes": [], "rigid_meshes": []}
	for i in n_bone:
		out["bone_names"].append(_text(r.astr()))
	for i in n_tex:
		out["textures"].append(_text(r.astr()))
	for i in n_mat:
		var mat = {"name": _text(r.zstr()).trim_prefix("MATERIAL: ")}
		var c = r.raw(64).to_float32_array()
		if c.size() == 16:
			mat["ambient"] = Color(c[0], c[1], c[2], c[3])
			mat["diffuse"] = Color(c[4], c[5], c[6], c[7])
			mat["emissive"] = Color(c[8], c[9], c[10], c[11])
			mat["specular"] = Color(c[12], c[13], c[14], c[15])
		mat["power"] = r.f32()
		var two_sided = r.raw(1)
		mat["two_sided"] = two_sided.size() == 1 and two_sided[0] != 0
		out["materials"].append(mat)
	for i in n_skin:
		var m = {"name": _text(r.astr()), "texture": r.i32(), "material": r.i32()}
		var nv = r.i32()
		var ni = r.i32()
		_read_skin_verts(m, r.raw(48 * nv), nv)
		m["indices"] = _read_indices(r.raw(2 * ni), ni)
		out["skin_meshes"].append(m)
	for i in n_rigid:
		var m = {"name": _text(r.astr()), "bone": r.i32(), "texture": r.i32(), "material": r.i32()}
		var nv = r.i32()
		var ni = r.i32()
		_read_rigid_verts(m, r.raw(32 * nv), nv)
		m["indices"] = _read_indices(r.raw(2 * ni), ni)
		out["rigid_meshes"].append(m)
	if not r.ok or r.p != r.b.size():
		return _err(path, "Format passt nicht")
	return out

# A3DBVERTEX3: Position, 3 Gewichte, 4 Bone-Indizes (UBYTE4, Index = Skin-Bone), Normale, UV.
# Das 4. Gewicht ist 1 - (w0 + w1 + w2) (D3DFVF_XYZB4 | LASTBETA_UBYTE4).
func _read_skin_verts(m: Dictionary, vb: PackedByteArray, nv: int) -> void:
	var f = vb.to_float32_array()
	var pos = PackedVector3Array()
	var nrm = PackedVector3Array()
	var uv = PackedVector2Array()
	var weights = PackedFloat32Array()
	var bones = PackedInt32Array()
	pos.resize(nv)
	nrm.resize(nv)
	uv.resize(nv)
	weights.resize(nv * 4)
	bones.resize(nv * 4)
	for v in nv:
		var o = v * 12
		pos[v] = Vector3(f[o], f[o + 1], f[o + 2])
		var w0 = f[o + 3]
		var w1 = f[o + 4]
		var w2 = f[o + 5]
		weights[v * 4] = w0
		weights[v * 4 + 1] = w1
		weights[v * 4 + 2] = w2
		weights[v * 4 + 3] = maxf(0.0, 1.0 - w0 - w1 - w2)
		for k in 4:
			bones[v * 4 + k] = vb[v * 48 + 24 + k]
		nrm[v] = Vector3(f[o + 7], f[o + 8], f[o + 9])
		uv[v] = Vector2(f[o + 10], f[o + 11])
	m["positions"] = pos
	m["normals"] = nrm
	m["uvs"] = uv
	m["weights"] = weights
	m["bones"] = bones

# A3DVERTEX: Position, Normale, UV
func _read_rigid_verts(m: Dictionary, vb: PackedByteArray, nv: int) -> void:
	var f = vb.to_float32_array()
	var pos = PackedVector3Array()
	var nrm = PackedVector3Array()
	var uv = PackedVector2Array()
	pos.resize(nv)
	nrm.resize(nv)
	uv.resize(nv)
	for v in nv:
		var o = v * 8
		pos[v] = Vector3(f[o], f[o + 1], f[o + 2])
		nrm[v] = Vector3(f[o + 3], f[o + 4], f[o + 5])
		uv[v] = Vector2(f[o + 6], f[o + 7])
	m["positions"] = pos
	m["normals"] = nrm
	m["uvs"] = uv

# WORD-Indizes; Dreiecke umgedreht: Angelica-Koordinaten in Godot sind gespiegelt
func _read_indices(ib: PackedByteArray, ni: int) -> PackedInt32Array:
	var idx = PackedInt32Array()
	idx.resize(ni - ni % 3)
	for t in range(0, ni - ni % 3, 3):
		idx[t] = ib.decode_u16(t * 2)
		idx[t + 1] = ib.decode_u16(t * 2 + 4)
		idx[t + 2] = ib.decode_u16(t * 2 + 2)
	return idx


# ====================================================
# .stck (A3DSklTrackSet::Load, A3DTrackData<T>::Load Version 1)
# ====================================================
# {fps, tracks: {Joint-Index: {pos: Spur, rot: Spur}}}, Spur = {keys, segs, fps}
func read_stck(path: String) -> Dictionary:
	var r = _open(path, "KCTS")
	if r == null:
		return _err(path, "keine Angelica-.stck")
	var ver = r.i32()
	if ver != 1:
		return _err(path, ".stck-Version %d wird noch nicht unterstützt" % ver)
	var n_track = r.i32()
	r.skip(8) # iAnimStart, iAnimEnd
	var out = {"path": path, "fps": r.i32(), "tracks": {}}
	for i in n_track:
		var id = r.i32()
		out["tracks"][id] = {"pos": _read_track(r, false), "rot": _read_track(r, true)}
	if not r.ok or r.p != r.b.size():
		return _err(path, "Format passt nicht")
	return out

# A3DTRACKSAVEDATA (iNumKey, iNumSegment, iFrameRate), Keys, SEGMENT[] (Start-/Endzeit ms, Start-/End-Key)
func _read_track(r: Bin, quat: bool) -> Dictionary:
	var nk = r.i32()
	var ns = r.i32()
	var fps = r.i32()
	var f = r.raw((16 if quat else 12) * nk).to_float32_array()
	var keys = []
	for k in nk:
		if quat:
			keys.append(Quaternion(f[k * 4], f[k * 4 + 1], f[k * 4 + 2], f[k * 4 + 3]))
		else:
			keys.append(Vector3(f[k * 3], f[k * 3 + 1], f[k * 3 + 2]))
	return {"keys": keys, "segs": r.raw(16 * ns).to_int32_array(), "fps": maxi(1, fps), "quat": quat}

# A3DTrackData<T>::GetKeyValue_OV: Wert zur Zeit ms (Positionen linear, Rotationen SLERPQuad)
func track_value(t: Dictionary, ms: int):
	var keys: Array = t["keys"]
	var segs: PackedInt32Array = t["segs"]
	var n = keys.size()
	var ns = segs.size() >> 2
	if n == 0:
		return null
	if ns == 0 or ms <= segs[0]:
		return keys[0]
	var seg = ns - 1
	var floor_key = n - 1
	if ms < segs[(ns - 1) * 4 + 1]:
		for s in ns:
			if segs[s * 4 + 1] > ms:
				seg = s
				if segs[s * 4 + 2] == segs[s * 4 + 3]:
					floor_key = segs[s * 4 + 2]
				else:
					floor_key = segs[s * 4 + 2] + floori((ms - segs[s * 4]) * t["fps"] / 1000.0)
				break
	if floor_key >= n - 1:
		return keys[n - 1]
	if segs[seg * 4 + 2] == segs[seg * 4 + 3]:
		return keys[segs[seg * 4 + 2]]
	var f = clampf((ms - segs[seg * 4]) / (1000.0 / t["fps"]) - (floor_key - segs[seg * 4 + 2]), 0.0, 1.0)
	if t["quat"]:
		return _slerp(keys[floor_key], keys[floor_key + 1], f)
	return (keys[floor_key] as Vector3).lerp(keys[floor_key + 1], f)

func _slerp(q1: Quaternion, q2: Quaternion, f: float) -> Quaternion:
	var c = q1.dot(q2)
	var sign = 1.0
	if c < 0.0:
		c = -c
		sign = -1.0
	var f1 = 1.0 - f
	var f2 = f * sign
	if c <= 1.0 - SLERP_EPSILON:
		var theta = acos(c)
		var s = sin(theta)
		f1 = sin((1.0 - f) * theta) / s
		f2 = sin(f * theta) / s * sign
	return (q1 * f1 + q2 * f2).normalized()
