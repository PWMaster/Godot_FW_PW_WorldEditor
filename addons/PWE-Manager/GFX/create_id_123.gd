@tool
extends "create_id_120.gd"

# ====================================================
# GFXELEMENTID 123 = ID_ELE_TYPE_PARTICLE_ELLIPSOID (A3DEllipsoidEmitter : A3DAreaEmitter)
# ====================================================
# Partikel entstehen im Volumen (bzw. auf der Oberfläche) eines Ellipsoids mit den
# Durchmessern AreaSize. IsAvgGen verteilt sie stattdessen gleichmäßig über
# AlphaSeg x BetaSeg Längen-/Breitengrade (fester Zähler pro Loop).
# ====================================================

func _element_id() -> String:
	return "123"

func _gen_emitter_uniforms(_parent_node: Node, parsed_data: Dictionary, declared: Dictionary, _uniform_assignments: Dictionary, _emitter_ctrls: Array) -> String:
	# GenAverage-Zyklus: Nordpol, (BetaSeg - 1) Ringe, Südpol
	var ring_count = _avg_ring_count(int(parsed_data.get("AlphaSeg", 10)))
	var beta_seg = maxi(int(parsed_data.get("BetaSeg", 10)), 1)
	var cycle = 2 + (beta_seg - 1) * ring_count
	declared["Avg_Ring_Count"] = true
	declared["Avg_Cycle"] = true
	var c = "group_uniforms Emitter_Average;\n"
	c += "uniform int Avg_Ring_Count = " + str(ring_count) + ";\n"
	c += "uniform int Avg_Cycle = " + str(cycle) + ";\n"
	c += "group_uniforms;\n\n"
	return c

func _gen_emitter_functions(_declared: Dictionary) -> String:
	return _area_offset_glsl()

func _gen_emitter_init(declared: Dictionary) -> String:
	var u_surface = _u(declared, "IsSurface", "false")
	var c = "\t// A3DEllipsoidEmitter::InitParticle\n"
	c += "\tvec3 ell_u;\n"
	c += "\tbool ell_gen_dir = true;\n"
	c += "\tif (" + _u(declared, "IsAvgGen", "false") + ") {\n"
	c += "\t\t// GenAverage: (Alpha, Beta) aus dem Emissionszähler\n"
	c += "\t\tfloat a_delta = TAU / max(1.0, float(" + _u(declared, "AlphaSeg", "10") + "));\n"
	c += "\t\tfloat b_delta = PI / max(1.0, float(" + _u(declared, "BetaSeg", "10") + "));\n"
	c += "\t\tfloat k = mod(e_idx, float(Avg_Cycle));\n"
	c += "\t\tfloat alpha = 0.0;\n"
	c += "\t\tfloat beta = 0.0;\n"
	c += "\t\tif (k > float(Avg_Cycle) - 1.5) {\n"
	c += "\t\t\tbeta = PI; // Südpol (letzte Emission des Zyklus)\n"
	c += "\t\t} else if (k > 0.5) {\n"
	c += "\t\t\tfloat m = k - 1.0;\n"
	c += "\t\t\tfloat n = float(Avg_Ring_Count);\n"
	c += "\t\t\tbeta = (1.0 + floor(m / n)) * b_delta;\n"
	c += "\t\t\talpha = mod(m, n) * a_delta;\n"
	c += "\t\t}\n"
	c += "\t\tvec3 v = quat_rot(quat_axis(vec3(0.0, 1.0, 0.0), alpha), quat_rot(quat_axis(vec3(1.0, 0.0, 0.0), beta), vec3(0.0, 1.0, 0.0)));\n"
	c += "\t\tell_u = v * (" + u_surface + " ? 1.0 : rnd(e_idx, 13.0));\n"
	c += "\t} else if (" + u_surface + ") {\n"
	c += "\t\t// GenSurface: Punkt auf der Oberfläche, Flugrichtung nach INNEN (-v, auch ungebunden ungedreht)\n"
	c += "\t\tvec3 v = quat_rot(quat_axis(vec3(0.0, 1.0, 0.0), rnd(e_idx, 11.0) * TAU), vec3(1.0, 0.0, 0.0));\n"
	c += "\t\tv = quat_rot(quat_axis(v, rnd(e_idx, 12.0) * TAU), vec3(0.0, 1.0, 0.0));\n"
	c += "\t\tell_u = v;\n"
	c += "\t\tmove_dir = -v;\n"
	c += "\t\tell_gen_dir = false;\n"
	c += "\t} else {\n"
	c += "\t\t// GenTotal: gleichverteilt in der Einheitskugel (statt Rejection-Sampling)\n"
	c += "\t\tfloat z = srnd(e_idx, 11.0);\n"
	c += "\t\tfloat phi = rnd(e_idx, 12.0) * TAU;\n"
	c += "\t\tfloat rxy = sqrt(max(0.0, 1.0 - z * z));\n"
	c += "\t\tell_u = pow(rnd(e_idx, 13.0), 1.0 / 3.0) * vec3(rxy * cos(phi), rxy * sin(phi), z);\n"
	c += "\t}\n"
	c += _area_finish(declared, "ell_u", false)
	c += "\tif (ell_gen_dir) move_dir = gen_direction(e_idx, is_bind, ee_rot, " + _u(declared, "Angle", "0.0") + ");\n"
	return c
