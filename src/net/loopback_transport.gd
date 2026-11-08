class_name LoopbackTransport
extends NetworkTransport

## Deterministic two-endpoint transport for local sessions and tests. Delivery and
## connection signals happen only when the receiving endpoint is polled.

var _local_id := 0
var _peer: LoopbackTransport
var _open := false
var _pending: Array[Dictionary] = []


static func create_pair() -> Array[LoopbackTransport]:
	var host := LoopbackTransport.new()
	var client := LoopbackTransport.new()
	host._local_id = 0
	client._local_id = 1
	host._peer = client
	client._peer = host
	host._open = true
	client._open = true
	host._pending.append({"event": &"connected", "peer_id": 1})
	client._pending.append({"event": &"connected", "peer_id": 0})
	return [host, client]


func poll() -> void:
	var pending := _pending
	_pending = []
	for event: Dictionary in pending:
		match event.get("event"):
			&"connected":
				peer_connected.emit(event["peer_id"])
			&"disconnected":
				peer_disconnected.emit(event["peer_id"])
			&"packet":
				packet_received.emit(event["peer_id"], event["packet"])


func send_to(peer_id: int, packet: PackedByteArray, _reliable: bool = true) -> bool:
	if not _open or _peer == null or not _peer._open or peer_id != _peer._local_id:
		return false
	_peer._pending.append({
		"event": &"packet",
		"peer_id": _local_id,
		"packet": packet.duplicate(),
	})
	return true


func close() -> void:
	if not _open:
		return
	_open = false
	var peer := _peer
	if peer == null:
		return
	_pending.append({"event": &"disconnected", "peer_id": peer._local_id})
	if peer._open:
		peer._open = false
		peer._pending.append({"event": &"disconnected", "peer_id": _local_id})
	peer._peer = null
	_peer = null


func is_open() -> bool:
	return _open
