extends Node

# ====================================================
# Sitzung des Clients: verbinden, Version prüfen ("hello"), Konto anlegen, an- und abmelden,
# trennen. Knoten "Session" neben "Net" unter "Game". Alle Aufrufe mit await, Ergebnis {code, data}.
#   open(hello = true)        verbinden (host, port, ggf. DTLS), dann hello
#   register / login / logout verbinden bei Bedarf selbst
#   list_chars / create_char / delete_char / enter_char   Figuren (angemeldet)
#   world_ready / world_leave, send_move (Welt; Meldungen und STATE über net.pushed / state_received)
#   select_target(id) (0 = abwählen), say(text) (Chat "Sagen"; die Nachricht kommt als Meldung "chat")
#   quest_accept(npc, id) / quest_complete(npc, id) / quest_abandon(id)
#   equip(pos) / unequip(slot, pos) / move_item(from, to) / gather(id) / gather_cancel()
#   attack(id) / attack_stop() / revive()
#   skill_seen(ids) / shortcut(bar, slot, id)
#   close()                   trennen
# Signale: state_changed(State), kicked(Code) (Server trennt: andere Anmeldung, Server endet ...),
# disconnected(Code).
# Benutzt die Multiplayer-API seines Zweigs (Client: die des SceneTree, Bot: je Sitzung eine eigene).
# ====================================================

const Proto = preload("../common/protocol.gd")
const Net = preload("../common/net.gd")
const CLIENT_NAME = "Godot-FW-Client"

signal state_changed(state: int)
signal kicked(code: int)
signal disconnected(code: int)

enum State {OFFLINE, CONNECTING, ONLINE, LOGGED_IN}

var host = "127.0.0.1"
var port = Proto.DEFAULT_PORT
var dtls = false
var dtls_cert = "" # Zertifikat des Servers (dtls.crt) zum Prüfen; leer = ungeprüft verschlüsselt
var protocol_version = Proto.VERSION # nur für Tests anders
var state = State.OFFLINE
var account = ""
var server_info = {}
var last_kick = Proto.Code.OK
var net: Node
var _wait: RefCounted # Net.Waiter während des Verbindens


func _ready() -> void:
	net = get_parent().get_node("Net")
	net.pushed.connect(_on_pushed)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func open(hello: bool = true) -> Dictionary:
	close()
	last_kick = Proto.Code.OK
	var p = ENetMultiplayerPeer.new()
	if p.create_client(host, port) != OK:
		return Proto.result(Proto.Code.CONNECT_FAILED)
	if dtls:
		var tls = _tls_options()
		if tls == null or p.host.dtls_client_setup(host, tls) != OK:
			p.close()
			return Proto.result(Proto.Code.CONNECT_FAILED, {"error": "DTLS"})
	multiplayer.multiplayer_peer = p
	_set_state(State.CONNECTING)
	var w = Net.Waiter.new()
	_wait = w
	get_tree().create_timer(Proto.CONNECT_TIMEOUT).timeout.connect(_connect_done.bind(w, Proto.Code.CONNECT_FAILED))
	var code = await w.done
	if code != Proto.Code.OK:
		_drop(code)
		return Proto.result(code)
	_set_state(State.ONLINE)
	if not hello:
		return Proto.result(Proto.Code.OK)
	var r = await net.request("hello", {"version": protocol_version, "client": CLIENT_NAME})
	if r["code"] != Proto.Code.OK:
		close()
		return r
	server_info = r["data"]
	return r

func close() -> void:
	if _wait != null:
		_connect_done(_wait, Proto.Code.DISCONNECTED)
	if state != State.OFFLINE:
		_drop(Proto.Code.DISCONNECTED)

func register(acc: String, password: String) -> Dictionary:
	var r = await _ensure_online()
	if r["code"] != Proto.Code.OK:
		return r
	return await net.request("register", {"account": acc, "password": password})

# force: Anmeldung erzwingen (eine andere Sitzung desselben Kontos wird getrennt)
func login(acc: String, password: String, force: bool = false) -> Dictionary:
	var r = await _ensure_online()
	if r["code"] != Proto.Code.OK:
		return r
	r = await net.request("login", {"account": acc, "password": password, "force": force})
	if r["code"] == Proto.Code.OK:
		account = r["data"]["account"]
		_set_state(State.LOGGED_IN)
	return r

func logout() -> Dictionary:
	if state != State.LOGGED_IN:
		return Proto.result(Proto.Code.NOT_LOGGED_IN)
	var r = await net.request("logout")
	if r["code"] == Proto.Code.OK:
		account = ""
		_set_state(State.ONLINE)
	return r

func list_chars() -> Dictionary:
	return await net.request("char_list")

# appearance: {face, mask, hair, skin, hair_color}
func create_char(char_name: String, race: int, cls: int, gender: int, appearance: Dictionary) -> Dictionary:
	return await net.request("char_create", {"name": char_name, "race": race, "class": cls, "gender": gender,
		"appearance": appearance})

func delete_char(char_id: int) -> Dictionary:
	return await net.request("char_delete", {"id": char_id})

func enter_char(char_id: int) -> Dictionary:
	return await net.request("char_enter", {"id": char_id})

func world_ready() -> Dictionary:
	return await net.request("world_ready")

func world_leave() -> Dictionary:
	return await net.request("world_leave")

func select_target(id: int) -> Dictionary:
	return await net.request("target", {"id": id})

func quest_accept(npc: int, id: int) -> Dictionary:
	return await net.request("quest_accept", {"npc": npc, "id": id})

func quest_complete(npc: int, id: int) -> Dictionary:
	return await net.request("quest_complete", {"npc": npc, "id": id})

func quest_abandon(id: int) -> Dictionary:
	return await net.request("quest_abandon", {"id": id})

func equip(pos: int) -> Dictionary:
	return await net.request("equip", {"pos": pos})

func unequip(slot: int, pos: int = -1) -> Dictionary:
	return await net.request("unequip", {"slot": slot, "pos": pos})

func move_item(from: int, to: int) -> Dictionary:
	return await net.request("move_item", {"from": from, "to": to})

func gather(id: int) -> Dictionary:
	return await net.request("gather", {"id": id})

func gather_cancel() -> Dictionary:
	return await net.request("gather_cancel", {})

func attack(id: int) -> Dictionary:
	return await net.request("attack", {"id": id})

func attack_stop() -> Dictionary:
	return await net.request("attack_stop", {})

func revive() -> Dictionary:
	return await net.request("revive", {})

func skill_seen(ids: Array) -> Dictionary:
	return await net.request("skill_seen", {"ids": ids})

func shortcut(bar: int, slot: int, id: int) -> Dictionary:
	return await net.request("shortcut", {"bar": bar, "slot": slot, "id": id})

func skill_cast(id: int, target: int, pos = null) -> Dictionary:
	var args = {"id": id, "target": target}
	if pos is Vector3:
		args["pos"] = [pos.x, pos.y, pos.z]
	return await net.request("skill_cast", args)

func skill_cancel() -> Dictionary:
	return await net.request("skill_cancel", {})

func say(text: String, channel: int = Proto.CHAT_SAY) -> Dictionary:
	return await net.request("chat", {"channel": channel, "text": text})

func send_move(pos: Vector3, dir: float, state: int) -> void:
	net.send_move(pos, dir, state)

func _ensure_online() -> Dictionary:
	if state == State.ONLINE or state == State.LOGGED_IN:
		return Proto.result(Proto.Code.OK)
	if state == State.CONNECTING:
		return Proto.result(Proto.Code.NOT_CONNECTED)
	return await open()

func _tls_options() -> TLSOptions:
	if dtls_cert == "":
		return TLSOptions.client_unsafe()
	var cert = X509Certificate.new()
	if cert.load(dtls_cert) != OK:
		return null
	return TLSOptions.client_unsafe(cert) # Zertifikat muss passen, der Name (CN) wird nicht geprüft


# ====================================================
# ENET-SIGNALE
# ====================================================
func _on_connected() -> void:
	if _wait != null:
		_connect_done(_wait, Proto.Code.OK)

func _on_failed() -> void:
	if _wait != null:
		_connect_done(_wait, Proto.Code.CONNECT_FAILED)

func _on_server_disconnected() -> void:
	# nicht mitten im Netz-Signal den Peer tauschen
	_drop.call_deferred(last_kick if last_kick != Proto.Code.OK else Proto.Code.DISCONNECTED)

func _on_pushed(what: String, data: Dictionary) -> void:
	match what:
		"kicked":
			last_kick = int(data.get("code", Proto.Code.DISCONNECTED))
			kicked.emit(last_kick)
		"server_closing":
			last_kick = Proto.Code.SERVER_CLOSING
			kicked.emit(last_kick)

func _connect_done(w: RefCounted, code: int) -> void:
	if _wait != w:
		return
	_wait = null
	w.done.emit(code)

func _drop(code: int) -> void:
	if state == State.OFFLINE:
		return
	var p = multiplayer.multiplayer_peer
	if p is ENetMultiplayerPeer:
		p.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	net.fail_all(Proto.Code.DISCONNECTED)
	account = ""
	_set_state(State.OFFLINE)
	disconnected.emit(code)

func _set_state(s: int) -> void:
	if s != state:
		state = s
		state_changed.emit(s)
