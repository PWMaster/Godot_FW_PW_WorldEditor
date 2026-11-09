@tool
extends RefCounted

# ====================================================
# Angriffs-Effekt (.att, A3DSkillGfxComposer::Load, Textform) aus gfx\SkillAttack\: was ein
# Angriffspunkt (Ereignis 104 einer kombinierten Aktion, SGCAttackPointMark) abspielt.
#   var att = AttFile.read(files, Pfad)  -> {} wenn unlesbar, sonst
#   {version,
#    fly: {gfx, pos, end_pos, scale}  Flug-GFX vom Angreifer zum Ziel (gfx "" = keine)
#    move_mode   GfxMoveMode: 0 gerade, 1 Parabel, 7 am Ziel (OnTarget), 13 am Ziel fest ...
#    target_mode, fly_speed (m/s), fly_time (ms), one_hit, fade_out,
#    hit: {gfx, pos, scale, rel_scale, target_scale, min_scale, max_scale, trace, stay}
#                Treffer-GFX am Ziel (rel_scale: Scale = Zielhöhe / target_scale, begrenzt)
#    ground: {gfx, pos}}
# pos = {hook, offset (Vector3), rel_hook, hanger, child_hook, bottom (HitPos 1 = Füße, 0 = Mitte)}
# Die Zeilen folgen fest aufeinander (Version entscheidet, welche es gibt), daher wird der Reihe
# nach gelesen statt nach Schlüsseln.
# ====================================================

const MOVE_LINEAR = 0
const MOVE_PARABOLIC = 1
const MOVE_ON_TARGET = 7
const MOVE_ON_TARGET_FIX = 13

var _lines: PackedStringArray
var _i = 0


static func read(files, path: String) -> Dictionary:
	if path == "" or not files.file_exists(path):
		return {}
	var r = new()
	r._lines = files.read_lines(path)
	return r._parse()

func _parse() -> Dictionary:
	var v = _int(_next().trim_prefix("MOXT"))
	if _lines.is_empty():
		return {}
	var out = {"version": v}
	var fly = {"gfx": _next() if v > 0 else "", "pos": _pos(v), "end_pos": _pos(v) if v >= 13 else {}}
	var ground = {"gfx": _next()}
	if v >= 5:
		_next() # unbenutzte Zeile (Path)
	fly["scale"] = _float(_next()) if v >= 3 else 1.0
	out["move_mode"] = _int(_next())
	if v >= 18:
		out["custom_move"] = true # eigene Bahn-Parameter: noch nicht gelesen
	out["target_mode"] = _int(_next())
	_next() # AttMode
	_next() # Count
	_next() # Interv
	out["one_hit"] = _int(_next()) != 0 if v >= 2 else true
	out["fade_out"] = _int(_next()) != 0 if v >= 4 else false
	if v >= 1:
		_next() # IsArea
		_next() # Shape
		_next() # Range
	out["fly_time"] = _int(_next())
	out["fly_speed"] = _float(_next()) if v >= 6 else 20.0
	var hit = {"pos": _pos(v) if v >= 12 else {}}
	ground["pos"] = _pos(v) if v >= 12 else {}
	hit["rel_scale"] = _int(_next()) != 0
	hit["target_scale"] = _float(_next())
	if hit["target_scale"] == 0.0:
		hit["target_scale"] = 1.8
	hit["gfx"] = _next()
	hit["scale"] = _float(_next()) if v >= 3 else 1.0
	_next() # AttMode
	_next() # Count
	_next() # Interv
	hit["trace"] = _int(_next()) != 0
	var val_type = _int(_next())
	if val_type >= 0 and val_type <= 2:
		_next() # Bool / Int / Float
	hit["stay"] = _int(_next()) if v >= 11 else 0
	if v >= 20:
		_next() # DelayTime
	hit["max_scale"] = _float(_next()) if v >= 14 else 99999.0
	hit["min_scale"] = _float(_next()) if v >= 14 else 0.01
	out["fly"] = fly
	out["hit"] = hit
	out["ground"] = ground
	return out

# SGC_POS_INFO (_load_sgc_pos)
func _pos(v: int) -> Dictionary:
	var p = {"hook": "", "offset": Vector3.ZERO, "rel_hook": false, "hanger": "", "child_hook": false, "bottom": false}
	if v >= 7:
		if v < 19:
			p["hook"] = _next()
		else:
			var n = _int(_next())
			for i in n:
				var h = _next()
				if i == 0:
					p["hook"] = h
	if v >= 8:
		var f = _next().split(",")
		if f.size() == 3:
			p["offset"] = Vector3(f[0].to_float(), f[1].to_float(), f[2].to_float())
	if v >= 9:
		p["rel_hook"] = _int(_next()) != 0
	if v >= 10:
		p["hanger"] = _next()
		p["child_hook"] = _int(_next()) != 0
	if v >= 12:
		p["bottom"] = _int(_next()) == 1
	return p

# Wert der nächsten Zeile (hinter dem ersten ":")
func _next() -> String:
	if _i >= _lines.size():
		return ""
	var line = _lines[_i]
	_i += 1
	var c = line.find(":")
	return line.substr(c + 1).strip_edges() if c >= 0 else line.strip_edges()

static func _int(s: String) -> int:
	return s.strip_edges().to_int()

static func _float(s: String) -> float:
	return s.strip_edges().to_float()
