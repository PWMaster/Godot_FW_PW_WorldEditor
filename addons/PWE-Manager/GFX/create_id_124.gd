@tool
extends "create_id_120.gd"

# ====================================================
# GFXELEMENTID 124 = ID_ELE_TYPE_PARTICLE_CYLINDER (A3DCylinderEmitter : A3DAreaEmitter)
# ====================================================
# Partikel entstehen im Volumen (bzw. auf dem Mantel) eines Zylinders entlang Z.
# AreaSize = (Durchmesser X, Durchmesser Y, Höhe Z). IsAvgGen verteilt sie gleichmäßig
# über AlphaSeg Winkel x (BetaSeg + 1) Höhenstufen (fester Zähler pro Loop).
# ====================================================

func _element_id() -> String:
	return "124"

func _gen_emitter_uniforms(_parent_node: Node, parsed_data: Dictionary, declared: Dictionary, _uniform_assignments: Dictionary, _emitter_ctrls: Array) -> String:
	# GenAverage-Zyklus: (BetaSeg + 1) Höhenstufen mit je Avg_Ring_Count Winkeln
	var ring_count = _avg_ring_count(int(parsed_data.get("AlphaSeg", 10)))
	var beta_seg = maxi(int(parsed_data.get("BetaSeg", 10)), 1)
	declared["Avg_Ring_Count"] = true
	declared["Avg_Cycle"] = true
	var c = "group_uniforms Emitter_Average;\n"
	c += "uniform int Avg_Ring_Count = " + str(ring_count) + ";\n"
	c += "uniform int Avg_Cycle = " + str((beta_seg + 1) * ring_count) + ";\n"
	c += "group_uniforms;\n\n"
	return c

func _gen_emitter_functions(_declared: Dictionary) -> String:
	return _area_offset_glsl()

func _gen_emitter_init(declared: Dictionary) -> String:
	var u_surface = _u(declared, "IsSurface", "false")
	var c = "\t// A3DCylinderEmitter::InitParticle\n"
	c += "\tvec3 cyl_u;\n"
	c += "\tif (" + _u(declared, "IsAvgGen", "false") + ") {\n"
	c += "\t\t// GenAverage: Winkel und Höhenstufe aus dem Emissionszähler\n"
	c += "\t\tfloat a_delta = TAU / max(1.0, float(" + _u(declared, "AlphaSeg", "10") + "));\n"
	c += "\t\tfloat b_seg = max(1.0, float(" + _u(declared, "BetaSeg", "10") + "));\n"
	c += "\t\tfloat n = float(Avg_Ring_Count);\n"
	c += "\t\tfloat k = mod(e_idx, float(Avg_Cycle));\n"
	c += "\t\tfloat ring = floor(k / n);\n"
	c += "\t\tvec3 v = quat_rot(quat_axis(vec3(0.0, 0.0, 1.0), mod(k, n) * a_delta), vec3(0.0, 1.0, 1.0 - 2.0 * ring / b_seg));\n"
	c += "\t\tcyl_u = v * (" + u_surface + " ? 1.0 : rnd(e_idx, 13.0));\n"
	c += "\t} else if (" + u_surface + ") {\n"
	c += "\t\t// GenSurface: auf dem Mantel\n"
	c += "\t\tfloat phi = rnd(e_idx, 11.0) * TAU;\n"
	c += "\t\tcyl_u = vec3(cos(phi), sin(phi), srnd(e_idx, 12.0));\n"
	c += "\t} else {\n"
	c += "\t\t// GenTotal: gleichverteilt im Volumen (statt Rejection-Sampling)\n"
	c += "\t\tfloat r = sqrt(rnd(e_idx, 11.0));\n"
	c += "\t\tfloat phi = rnd(e_idx, 12.0) * TAU;\n"
	c += "\t\tcyl_u = vec3(r * cos(phi), r * sin(phi), srnd(e_idx, 13.0));\n"
	c += "\t}\n"
	c += _area_finish(declared, "cyl_u", true)
	return c
