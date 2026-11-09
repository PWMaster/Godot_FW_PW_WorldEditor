@tool
extends "create_id_120.gd"

# ====================================================
# GFXELEMENTID 121 = ID_ELE_TYPE_PARTICLE_BOX (A3DBoxEmitter : A3DAreaEmitter)
# ====================================================
# Partikel entstehen im Volumen (bzw. auf der Oberfläche) einer Box der Größe AreaSize.
# Emission, Affectors, Bind/Drag und Rendering kommen aus create_id_120.gd.
# ====================================================

func _element_id() -> String:
	return "121"

func _gen_emitter_functions(_declared: Dictionary) -> String:
	return _area_offset_glsl()

func _gen_emitter_init(declared: Dictionary) -> String:
	var c = "\t// A3DBoxEmitter::InitParticle\n"
	c += "\tvec3 box_u;\n"
	c += "\tif (" + _u(declared, "IsSurface", "false") + ") {\n"
	c += "\t\t// GenSurface: Seite nach Flächenanteil wählen.\n"
	c += "\t\t// Angelica vergleicht im zweiten Zweig mit fS2 statt fS1 + fS2 – bewusst übernommen.\n"
	c += "\t\tvec3 sz = " + _u(declared, "AreaSize", "vec3(1.0)") + ";\n"
	c += "\t\tfloat s1 = sz.x * sz.y;\n"
	c += "\t\tfloat s2 = sz.y * sz.z;\n"
	c += "\t\tfloat s_sum = max(0.000001, s1 + s2 + sz.z * sz.x);\n"
	c += "\t\ts1 /= s_sum;\n"
	c += "\t\ts2 /= s_sum;\n"
	c += "\t\tfloat side = rnd(e_idx, 14.0) < 0.5 ? -1.0 : 1.0;\n"
	c += "\t\tfloat f_rand = rnd(e_idx, 11.0);\n"
	c += "\t\tif (f_rand < s1) box_u = vec3(srnd(e_idx, 12.0), srnd(e_idx, 13.0), side);\n"
	c += "\t\telse if (f_rand < s2) box_u = vec3(side, srnd(e_idx, 12.0), srnd(e_idx, 13.0));\n"
	c += "\t\telse box_u = vec3(srnd(e_idx, 12.0), side, srnd(e_idx, 13.0));\n"
	c += "\t} else {\n"
	c += "\t\t// GenTotal: gleichverteilt im Volumen\n"
	c += "\t\tbox_u = vec3(srnd(e_idx, 11.0), srnd(e_idx, 12.0), srnd(e_idx, 13.0));\n"
	c += "\t}\n"
	c += _area_finish(declared, "box_u", true)
	return c
