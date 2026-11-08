extends SceneTree
## Run: godot --headless --path . -s res://tests/test_loopback_transport.gd

var _failures := 0


func _initialize() -> void:
	var pair := LoopbackTransport.create_pair()
	var host := pair[0]
	var client := pair[1]
	var host_events: Array[String] = []
	var client_events: Array[String] = []
	var host_packets: Array[Dictionary] = []
	var client_packets: Array[Dictionary] = []
	host.peer_connected.connect(func(peer_id: int) -> void:
		host_events.append("connected:%d" % peer_id))
	client.peer_connected.connect(func(peer_id: int) -> void:
		client_events.append("connected:%d" % peer_id))
	host.peer_disconnected.connect(func(peer_id: int) -> void:
		host_events.append("disconnected:%d" % peer_id))
	client.peer_disconnected.connect(func(peer_id: int) -> void:
		client_events.append("disconnected:%d" % peer_id))
	host.packet_received.connect(func(sender_id: int, packet: PackedByteArray) -> void:
		host_packets.append({"sender": sender_id, "packet": packet}))
	client.packet_received.connect(func(sender_id: int, packet: PackedByteArray) -> void:
		client_packets.append({"sender": sender_id, "packet": packet}))

	_expect(host_events.is_empty() and client_events.is_empty(),
		"connect: signals emitted before poll")
	host.poll()
	client.poll()
	_expect(host_events == ["connected:1"], "connect: host events %s" % [host_events])
	_expect(client_events == ["connected:0"], "connect: client events %s" % [client_events])

	var outbound := PackedByteArray([1, 2, 3])
	_expect(host.send_to(1, outbound), "send: host packet rejected")
	outbound[0] = 99
	_expect(client_packets.is_empty(), "send: packet delivered before poll")
	client.poll()
	_expect(client_packets.size() == 1 and client_packets[0]["sender"] == 0
		and client_packets[0]["packet"] == PackedByteArray([1, 2, 3]),
		"send: host packet was not copied and delivered intact")
	_expect(client.send_to(0, PackedByteArray([4, 5]), false), "send: client packet rejected")
	host.poll()
	_expect(host_packets.size() == 1 and host_packets[0]["sender"] == 1
		and host_packets[0]["packet"] == PackedByteArray([4, 5]),
		"send: client packet did not reach host")
	_expect(not host.send_to(7, PackedByteArray([6])), "send: unknown peer accepted")

	client.close()
	_expect(not client.is_open() and not host.is_open(), "close: an endpoint stayed open")
	_expect(not host.send_to(1, PackedByteArray([7])), "close: send accepted after close")
	host.poll()
	client.poll()
	_expect(host_events == ["connected:1", "disconnected:1"],
		"close: host events %s" % [host_events])
	_expect(client_events == ["connected:0", "disconnected:0"],
		"close: client events %s" % [client_events])
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)
