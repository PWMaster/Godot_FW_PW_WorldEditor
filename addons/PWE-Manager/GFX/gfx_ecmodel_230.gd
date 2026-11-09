@tool
extends "gfx_model_160.gd"

# ====================================================
# Laufzeit-Treiber für GFXELEMENTID 230 (A3DGFXECModel), angelegt von create_id_230.gd.
# Wie gfx_model_160.gd (A3DGFXECModel::TickAnimation -> UpdateECModel):
#   Transform = Scale(kp.m_fScale) * GetTranMatrix(kp), SetColor(diffuse), SetTransparent(1 - Alpha),
#   PlayActionByName(ECMActName) beim GFX-Start, die Aktion läuft, solange das Element tickt.
# Dazu: findet das Modell die kombinierte Aktion nicht unter ihrem Namen, gelten die
# Basis-Aktionen aus der .ecm, und ein Modell mit nur einer Animation spielt diese.
# ====================================================

@export_group("ECModel")
## Basis-Aktionen der kombinierten Aktion (aus der .ecm): Ersatznamen für die Animation
@export var Base_Actions: PackedStringArray = []:
	set(value):
		Base_Actions = value
		_dirty = true
## Gefundene .ecm (nur zur Info)
@export var Ecm_File: String = ""
## LDType: 0 = .ecm, 1 / 2 = Haut / Modell des Zaubernden (vom Spiel, hier die .ecm)
@export var Loader_Type: int = 0


func _get_configuration_warnings() -> PackedStringArray:
	var warnings = PackedStringArray()
	if Model_Resource == null:
		var parts = Model_Path.replace("\\", "/").split("/", false)
		var name = parts[parts.size() - 1].get_basename() if not parts.is_empty() else ""
		warnings.append("Kein Modell geladen: " + Model_Path + " nicht in den Spieldaten (Leiste ECM-GFX-MAP: Spieldaten-Ordner), dann Element neu erstellen")
	if Loader_Type != 0:
		warnings.append("LDType " + str(Loader_Type) + ": im Spiel kommt Haut / Modell vom Zaubernden, hier wird die .ecm gezeigt")
	return warnings

func _match_animation(player: AnimationPlayer, act_name: String) -> StringName:
	var found = super._match_animation(player, act_name)
	if found != &"" or act_name == "":
		return found
	for base_name in Base_Actions:
		found = super._match_animation(player, base_name)
		if found != &"":
			return found
	# Konvertierte Effekt-Modelle haben oft genau eine Animation
	var names = []
	for n in player.get_animation_list():
		if n.get_slice("/", n.get_slice_count("/") - 1) != "RESET":
			names.append(n)
	return StringName(names[0]) if names.size() == 1 else &""
