@tool
extends "create_id_210.gd"

# ====================================================
# GFXELEMENTID 211 = ID_ELE_TYPE_GRID_DECAL_2D (A3DGridDecalEx, 2D)
# ====================================================
# Dasselbe Gitter wie 210 (Punkte, Farben, UV, Grid-Animation), aber flach in Bildschirm-
# Koordinaten gezeichnet (A3DGridDecalEx::Fill_Verts_2D):
#   Mitte  = GetParentTM() * KeyPoint-Position, auf den Bildschirm projiziert
#   fScale = Bildschirm-Breite einer Welt-Einheit (Kamera-Rechts) an der Mitte * GFX-Scale
#   Punkt  = Mitte + (x * cos + y * sin, -y * cos + x * sin) * fScale (Bildschirm, y nach unten)
#            -> immer bildschirmparallel, Rad_2D dreht im Uhrzeigersinn
#   Tiefe  = Tiefe der Mitte für alle Punkte; fZOffset rückt sie um fZOffset * GFX-Scale zur Kamera.
# KeyPoint-Scale, KeyPoint-Richtung, AffByScl und RotFromView wirken bei 2D nicht.
# Liegt die Mitte außerhalb von Near / Far (oder hinter der Kamera), zeichnet Angelica nichts.
# Der Shader schreibt POSITION (Clip-Raum) direkt, wie Angelicas A3DTLVERTEX.
# ====================================================


func _element_id() -> String:
	return "211"

func _node_name() -> String:
	return "GridDecal2D_GFX"


func _gen_placement(declared: Dictionary) -> String:
	var c = "\t// --- Fill_Verts_2D: Mitte auf dem Bildschirm (Godot: Near = 1, Far = CLIP_SPACE_FAR) ---\n"
	c += "\tvec3 gd_cw = (MODEL_MATRIX * vec4(k_pos, 1.0)).xyz;\n"
	c += "\tmat4 gd_vp = PROJECTION_MATRIX * VIEW_MATRIX;\n"
	c += "\tvec4 gd_cc = gd_vp * vec4(gd_cw, 1.0);\n"
	c += "\tvec3 gd_n = gd_cc.xyz / gd_cc.w;\n"
	c += "\tif (gd_cc.w <= 0.0 || gd_n.z >= 1.0 || gd_n.z <= CLIP_SPACE_FAR) {\n"
	c += "\t\tv_active = 0.0;\n"
	c += "\t}\n"
	c += "\t// GetActualScale()\n"
	c += "\tfloat gd_gs = length(MODEL_MATRIX[0].xyz);\n"
	c += "\tfloat gd_z = gd_n.z;\n"
	c += "\tfloat gd_zoff = " + KeyPointShader.u(declared, "fZOffset", "0.0") + ";\n"
	c += "\tif (gd_zoff != 0.0) {\n"
	c += "\t\t// vCenterWorld - Kamera-Blickrichtung * fZOffset * Scale (INV_VIEW_MATRIX[2] = -Blickrichtung)\n"
	c += "\t\tvec4 gd_zc = gd_vp * vec4(gd_cw + INV_VIEW_MATRIX[2].xyz * (gd_zoff * gd_gs), 1.0);\n"
	c += "\t\tgd_z = clamp(gd_zc.z / gd_zc.w, CLIP_SPACE_FAR, 1.0);\n"
	c += "\t}\n"
	c += "\t// fScale = (Bildschirm-x von Mitte + Kamera-Rechts) - Bildschirm-x der Mitte, hier in NDC-x\n"
	c += "\tvec4 gd_rc = gd_vp * vec4(gd_cw + INV_VIEW_MATRIX[0].xyz, 1.0);\n"
	c += "\tfloat gd_s = (gd_rc.x / gd_rc.w - gd_n.x) * gd_gs;\n"
	c += "\tfloat gd_sin = sin(k_rad);\n"
	c += "\tfloat gd_cos = cos(k_rad);\n"
	c += "\t// Bildschirm-y zeigt bei Angelica nach unten; NDC-y braucht das Seitenverhältnis und die Richtung\n"
	c += "\t// von Kamera-Oben in NDC (Vulkan: nach unten, OpenGL: nach oben)\n"
	c += "\tvec4 gd_uc = gd_vp * vec4(gd_cw + INV_VIEW_MATRIX[1].xyz, 1.0);\n"
	c += "\tfloat gd_up = gd_uc.y / gd_uc.w - gd_n.y < 0.0 ? -1.0 : 1.0;\n"
	c += "\tvec2 gd_off = vec2(gd_pos.x * gd_cos + gd_pos.y * gd_sin, gd_pos.y * gd_cos - gd_pos.x * gd_sin) * gd_s;\n"
	c += "\tgd_off.y *= VIEWPORT_SIZE.x / VIEWPORT_SIZE.y * gd_up;\n"
	c += "\tVERTEX = k_pos;\n"
	c += "\tPOSITION = vec4(gd_n.xy + gd_off, gd_z, 1.0);\n\n"
	return c
