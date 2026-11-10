extends Node

# ====================================================
# Einstieg des Spiels, Hauptszene res://game/main.tscn (Knoten "Game"). Die Rolle kommt aus der
# Kommandozeile nach "--" bzw. dem Export:
#   Server   --server oder Export mit "dedicated_server"   -> Net + Server (server/server.gd)
#   Bot      --bot (Test ohne Fenster)                      -> Bot (tests/bot.gd)
#   sonst    Client                                        -> Net + Session + Login im Spielstil
#            (client/login_screen.gd; ohne Spieldaten das einfache Fenster client/client.gd)
# Statt Autoloads hängen Netz und Sitzung hier, so braucht project.godot keine Einträge.
# ====================================================

const Settings = preload("common/settings.gd")
const Net = preload("common/net.gd")
const Server = preload("server/server.gd")
const Session = preload("client/session.gd")
const Client = preload("client/client.gd")
const LoginScreen = preload("client/login_screen.gd")
const Bot = preload("tests/bot.gd")

enum Role {CLIENT, SERVER, BOT}


static func role() -> int:
	var args = Settings.user_args()
	if OS.has_feature("dedicated_server") or args.has("server"):
		return Role.SERVER
	if args.has("bot"):
		return Role.BOT
	return Role.CLIENT

func _ready() -> void:
	match role():
		Role.SERVER:
			Engine.max_fps = 60 # ohne Fenster sonst Dauerlast
			_add(Net.new(), "Net")
			_add(Server.new(), "Server")
		Role.BOT:
			Engine.max_fps = 60
			_add(Bot.new(), "Bot")
		_:
			Engine.max_fps = 60
			_add(Net.new(), "Net")
			_add(Session.new(), "Session")
			var client_settings = Settings.new("client")
			client_settings.use_imported_pw_client_if_missing()
			var ui_available = LoginScreen.available(client_settings)
			if ui_available:
				_add(LoginScreen.new(), "Login")
			else:
				_add(Client.new(), "Client")

func _add(node: Node, node_name: String) -> void:
	node.name = node_name
	add_child(node)
