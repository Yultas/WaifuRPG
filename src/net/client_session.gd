class_name ClientSession
extends RefCounted

## Client side of the versioned handshake. Does not own or close the transport.

signal accepted(session_id: int, player_slot: int)
signal rejected(reason: String)
signal disconnected()

enum State { IDLE, CONNECTING, ACCEPTED, REJECTED, DISCONNECTED }

var protocol_version := HandshakeCodec.PROTOCOL_VERSION
var build_version := "dev"
var content_hash := ""
var state := State.IDLE
var session_id := 0
var player_slot := -1

var _transport: NetworkTransport


func setup(transport: NetworkTransport) -> void:
	dispose()
	_transport = transport
	_transport.packet_received.connect(_on_packet)
	_transport.peer_disconnected.connect(_on_disconnected)


func start() -> bool:
	if _transport == null or state == State.CONNECTING or state == State.ACCEPTED:
		return false
	var hello := HandshakeCodec.Message.new()
	hello.kind = HandshakeCodec.Message.Kind.CLIENT_HELLO
	hello.protocol_version = protocol_version
	hello.build_version = build_version
	hello.content_hash = content_hash
	if not _transport.send_to(0, HandshakeCodec.encode(hello), true):
		return false
	state = State.CONNECTING
	return true


func poll() -> void:
	if _transport != null:
		_transport.poll()


func dispose() -> void:
	if _transport == null:
		return
	_transport.packet_received.disconnect(_on_packet)
	_transport.peer_disconnected.disconnect(_on_disconnected)
	_transport = null


func _on_packet(_peer_id: int, packet: PackedByteArray) -> void:
	if state != State.CONNECTING:
		return
	var message := HandshakeCodec.decode(packet)
	if message == null:
		return
	match message.kind:
		HandshakeCodec.Message.Kind.HOST_WELCOME:
			if message.protocol_version != protocol_version:
				_set_rejected("protocol_mismatch")
				return
			session_id = message.session_id
			player_slot = message.player_slot
			state = State.ACCEPTED
			accepted.emit(session_id, player_slot)
		HandshakeCodec.Message.Kind.REJECT:
			_set_rejected(message.reject_reason)


func _set_rejected(reason: String) -> void:
	state = State.REJECTED
	rejected.emit(reason)


func _on_disconnected(_peer_id: int) -> void:
	state = State.DISCONNECTED
	disconnected.emit()
