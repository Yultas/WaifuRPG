class_name HostSession
extends RefCounted

## Handshake owner for a host transport. Assigns client slots 1–3 after exact
## protocol/build/content matching. Does not own or close the transport.

signal client_accepted(peer_id: int, player_slot: int)
signal client_rejected(peer_id: int, reason: String)
signal client_disconnected(peer_id: int)

var protocol_version := HandshakeCodec.PROTOCOL_VERSION
var build_version := "dev"
var content_hash := ""
var session_id := 1

var _transport: NetworkTransport
var _slots: Dictionary[int, int] = {}
var _next_slot := 1


func setup(transport: NetworkTransport) -> void:
	dispose()
	_transport = transport
	_transport.packet_received.connect(_on_packet)
	_transport.peer_disconnected.connect(_on_disconnected)


func poll() -> void:
	if _transport != null:
		_transport.poll()


func dispose() -> void:
	if _transport == null:
		return
	_transport.packet_received.disconnect(_on_packet)
	_transport.peer_disconnected.disconnect(_on_disconnected)
	_transport = null


func slot_for(peer_id: int) -> int:
	return _slots.get(peer_id, -1)


func _on_packet(peer_id: int, packet: PackedByteArray) -> void:
	var message := HandshakeCodec.decode(packet)
	if message != null and message.kind == HandshakeCodec.Message.Kind.CLIENT_HELLO \
			and _slots.has(peer_id):
		_send_welcome(peer_id, _slots[peer_id])
		return
	if _slots.has(peer_id):
		return
	if message == null:
		_reject(peer_id, "malformed_packet")
		return
	if message.kind != HandshakeCodec.Message.Kind.CLIENT_HELLO:
		_reject(peer_id, "unexpected_message")
		return
	if message.protocol_version != protocol_version:
		_reject(peer_id, "protocol_mismatch")
		return
	if message.build_version != build_version:
		_reject(peer_id, "build_mismatch")
		return
	if message.content_hash != content_hash:
		_reject(peer_id, "content_mismatch")
		return
	if _next_slot >= 4:
		_reject(peer_id, "session_full")
		return
	var slot := _next_slot
	_next_slot += 1
	_slots[peer_id] = slot
	_send_welcome(peer_id, slot)
	client_accepted.emit(peer_id, slot)


func _send_welcome(peer_id: int, slot: int) -> void:
	var welcome := HandshakeCodec.Message.new()
	welcome.kind = HandshakeCodec.Message.Kind.HOST_WELCOME
	welcome.protocol_version = protocol_version
	welcome.session_id = session_id
	welcome.player_slot = slot
	_transport.send_to(peer_id, HandshakeCodec.encode(welcome), true)


func _reject(peer_id: int, reason: String) -> void:
	var reject := HandshakeCodec.Message.new()
	reject.kind = HandshakeCodec.Message.Kind.REJECT
	reject.reject_reason = reason
	_transport.send_to(peer_id, HandshakeCodec.encode(reject), true)
	client_rejected.emit(peer_id, reason)


func _on_disconnected(peer_id: int) -> void:
	if _slots.erase(peer_id):
		client_disconnected.emit(peer_id)
