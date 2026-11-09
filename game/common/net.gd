extends Node

# ====================================================
# Nachrichten-Schicht über ENet, Knoten "Net" auf Server und Client. Rohe Pakete der
# Multiplayer-API (send_bytes / Signal peer_packet), je Paket ein Array mit var_to_bytes (nie Objekte):
#   [REQUEST, Nummer, Name, Argumente]   Client -> Server
#   [RESPONSE, Nummer, Code, Daten]      Server -> Client
#   [PUSH, Name, Daten]                  Server -> Client (Meldung ohne Anfrage)
#   [MOVE, x, y, z, Richtung, Zustand]   Client -> Server, unzuverlässig (geordnet)
#   [STATE, [[id, x, y, z, Richtung, Zustand], ...]]   Server -> Client, unzuverlässig (geordnet)
# Ohne RPC braucht es keinen gleichen Knotenpfad auf beiden Seiten, und der RPC-Cache der Engine
# bleibt leer (ein Peer-Wechsel meldete sonst im Release-Export Fehler zu "tree_exited").
#   Client:  var r = await net.request("login", {...})   -> {code, data}, nach Zeitlimit Code.TIMEOUT
#   Server:  Signal request_received(peer, id, what, args) -> respond(peer, id, code, data)
#            push(peer, what, data)
# Der Server ist Peer 1; Antworten und Meldungen nimmt ein Client nur von ihm an. Falsch
# aufgebaute oder zu große Pakete werden verworfen.
# ====================================================

const Proto = preload("protocol.gd")
const MAX_PACKET = 65536

enum Kind {REQUEST = 1, RESPONSE = 2, PUSH = 3, MOVE = 4, STATE = 5}

signal request_received(peer: int, id: int, what: String, args: Dictionary)
signal pushed(what: String, data: Dictionary)
signal move_received(peer: int, pos: Vector3, dir: float, state: int)
signal state_received(entries: Array)

var _next_id = 0
var _pending = {} # Nummer -> Waiter


# Wartet auf ein Ergebnis (Antwort, Zeitlimit oder Trennung, was zuerst kommt)
class Waiter:
	extends RefCounted
	signal done(result)


func _ready() -> void:
	multiplayer.peer_packet.connect(_on_packet)


# ====================================================
# CLIENT
# ====================================================
func request(what: String, args: Dictionary = {}, timeout: float = Proto.REQUEST_TIMEOUT) -> Dictionary:
	if not is_connected_to_server():
		return Proto.result(Proto.Code.NOT_CONNECTED)
	_next_id += 1
	var id = _next_id
	if _send(1, [Kind.REQUEST, id, what, args]) != OK:
		return Proto.result(Proto.Code.NOT_CONNECTED)
	var w = Waiter.new()
	_pending[id] = w
	get_tree().create_timer(timeout).timeout.connect(_finish.bind(id, Proto.Code.TIMEOUT, {}))
	return await w.done

# Alle offenen Anfragen mit einem Fehler beenden (z.B. bei Trennung)
func fail_all(code: int) -> void:
	for id in _pending.keys():
		_finish(id, code, {})

func is_connected_to_server() -> bool:
	var p = multiplayer.multiplayer_peer
	return p != null and not multiplayer.is_server() \
		and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func _finish(id: int, code: int, data: Dictionary) -> void:
	var w = _pending.get(id)
	if w == null:
		return
	_pending.erase(id)
	w.done.emit(Proto.result(code, data))


# ====================================================
# SERVER
# ====================================================
func respond(peer: int, id: int, code: int, data: Dictionary = {}) -> void:
	_send(peer, [Kind.RESPONSE, id, code, data])

func push(peer: int, what: String, data: Dictionary = {}) -> void:
	_send(peer, [Kind.PUSH, what, data])

func send_state(peer: int, entries: Array) -> void:
	_send(peer, [Kind.STATE, entries], MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)

# Client: eigene Position
func send_move(pos: Vector3, dir: float, state: int) -> void:
	if is_connected_to_server():
		_send(1, [Kind.MOVE, pos.x, pos.y, pos.z, dir, state], MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)


# ====================================================
# PAKETE
# ====================================================
func _send(peer: int, msg: Array, mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE) -> Error:
	# Peer, der gerade getrennt wird (ENet-Kanäle schon weg, Signal noch nicht da): nichts senden
	var mp = multiplayer.multiplayer_peer
	if mp is ENetMultiplayerPeer and peer > 0:
		var pp = mp.get_peer(peer)
		if pp == null or pp.get_state() != ENetPacketPeer.STATE_CONNECTED:
			return ERR_UNAVAILABLE
	return multiplayer.send_bytes(var_to_bytes(msg), peer, mode)

func _on_packet(from: int, packet: PackedByteArray) -> void:
	if packet.size() > MAX_PACKET:
		return
	var msg = bytes_to_var(packet)
	if not msg is Array or msg.is_empty():
		return
	var server = multiplayer.is_server()
	match msg[0]:
		Kind.REQUEST:
			if server and msg.size() == 4 and msg[1] is int and msg[2] is String and msg[3] is Dictionary:
				request_received.emit(from, msg[1], msg[2], msg[3])
		Kind.RESPONSE:
			if not server and from == 1 and msg.size() == 4 and msg[1] is int and msg[2] is int and msg[3] is Dictionary:
				_finish(msg[1], msg[2], msg[3])
		Kind.PUSH:
			if not server and from == 1 and msg.size() == 3 and msg[1] is String and msg[2] is Dictionary:
				pushed.emit(msg[1], msg[2])
		Kind.MOVE:
			if server and msg.size() == 6 and msg[5] is int:
				var v = [msg[1], msg[2], msg[3], msg[4]]
				for x in v:
					if not (x is float or x is int) or is_nan(float(x)) or is_inf(float(x)):
						return
				move_received.emit(from, Vector3(v[0], v[1], v[2]), float(v[3]), msg[5])
		Kind.STATE:
			if not server and from == 1 and msg.size() == 2 and msg[1] is Array:
				state_received.emit(msg[1])
