class_name NetworkTransport
extends RefCounted

## Byte-packet boundary between sessions and a concrete network backend.
## Implementations queue external callbacks; poll() emits them at a safe call site.

signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal packet_received(sender_id: int, packet: PackedByteArray)


func poll() -> void:
	pass


func send_to(_peer_id: int, _packet: PackedByteArray, _reliable: bool = true) -> bool:
	return false


func close() -> void:
	pass


func is_open() -> bool:
	return false
