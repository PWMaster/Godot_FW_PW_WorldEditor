extends SceneTree

# ====================================================
# Abgleich Client <-> Server ohne Editor (Abgleich/data_check.gd), Bericht in die Ausgabe:
#   godot --headless --path <Projekt> -s res://addons/PWE-Manager/tools/check/run_check.gd
#         [-- --client=res://Stock-PWE-Client --server=res://Stock-PWE-Server]
# Ende: Exit 0, wenn der Abgleich lief (unabhängig vom Ergebnis), sonst 1.
# ====================================================

const Check = preload("../../Abgleich/data_check.gd")


func _initialize() -> void:
	var args = {"client": "res://Stock-PWE-Client", "server": "res://Stock-PWE-Server"}
	for a in OS.get_cmdline_user_args():
		var eq = a.find("=")
		if a.begins_with("--") and eq > 0:
			args[a.substr(2, eq - 2)] = a.substr(eq + 1)
	var check = Check.new()
	var r = check.run(args["client"], args["server"], func(text, f): print("ABGLEICH: %3d %% %s" % [roundi(f * 100.0), text]))
	print(Check.report_text(r))
	quit(0 if r.get("score", -1.0) >= 0.0 else 1)
