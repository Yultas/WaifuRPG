extends SceneTree
## Run: godot --headless --path . -s res://tests/test_session_handshake.gd

var _failures := 0


func _initialize() -> void:
	_test_accept_duplicate_and_disconnect()
	_test_mismatch("protocol")
	_test_mismatch("build")
	_test_mismatch("content")
	_test_malformed()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_accept_duplicate_and_disconnect() -> void:
	var fixture := _fixture()
	var host: HostSession = fixture["host"]
	var client: ClientSession = fixture["client"]
	var accepted: Array[int] = []
	var disconnected: Array[int] = []
	host.client_accepted.connect(func(_peer_id: int, slot: int) -> void: accepted.append(slot))
	host.client_disconnected.connect(func(peer_id: int) -> void: disconnected.append(peer_id))
	_expect(client.start(), "accept: client could not start")
	client.poll()
	_expect(client.state == ClientSession.State.CONNECTING, "accept: client is not connecting")
	host.poll()
	client.poll()
	_expect(client.state == ClientSession.State.ACCEPTED, "accept: client not accepted")
	_expect(client.session_id == 77 and client.player_slot == 1, "accept: wrong session or slot")
	_expect(accepted == [1], "accept: host events %s" % [accepted])
	_expect(not client.start(), "accept: second start accepted")
	var hello := HandshakeCodec.Message.new()
	hello.build_version = "dev"
	hello.content_hash = "content-test"
	var transport: LoopbackTransport = fixture["client_transport"]
	transport.send_to(0, HandshakeCodec.encode(hello), true)
	host.poll()
	client.poll()
	_expect(accepted == [1], "accept: duplicate hello assigned another slot")
	_expect(host.slot_for(1) == 1, "accept: host lost the peer slot")
	fixture["host_transport"].close()
	host.poll()
	client.poll()
	_expect(client.state == ClientSession.State.DISCONNECTED, "disconnect: client state unchanged")
	_expect(disconnected == [1], "disconnect: host events %s" % [disconnected])
	_dispose(fixture)


func _test_mismatch(field: String) -> void:
	var fixture := _fixture()
	var host: HostSession = fixture["host"]
	var client: ClientSession = fixture["client"]
	var rejected: Array[String] = []
	client.rejected.connect(func(reason: String) -> void: rejected.append(reason))
	match field:
		"protocol":
			client.protocol_version += 1
		"build":
			client.build_version = "other"
		"content":
			client.content_hash = "other"
	client.start()
	host.poll()
	client.poll()
	var expected := "%s_mismatch" % field
	_expect(client.state == ClientSession.State.REJECTED, "%s: client not rejected" % field)
	_expect(rejected == [expected], "%s: reasons %s" % [field, rejected])
	_expect(host.slot_for(1) == -1, "%s: rejected peer received a slot" % field)
	_dispose(fixture)


func _test_malformed() -> void:
	var fixture := _fixture()
	var host: HostSession = fixture["host"]
	var rejected: Array[String] = []
	host.client_rejected.connect(func(_peer_id: int, reason: String) -> void: rejected.append(reason))
	fixture["client_transport"].send_to(0, PackedByteArray([1, 2]), true)
	host.poll()
	_expect(rejected == ["malformed_packet"], "malformed: host events %s" % [rejected])
	_expect(host.slot_for(1) == -1, "malformed: peer received a slot")
	_dispose(fixture)


func _fixture() -> Dictionary:
	var pair := LoopbackTransport.create_pair()
	var host := HostSession.new()
	host.build_version = "dev"
	host.content_hash = "content-test"
	host.session_id = 77
	host.setup(pair[0])
	var client := ClientSession.new()
	client.build_version = "dev"
	client.content_hash = "content-test"
	client.setup(pair[1])
	return {
		"host": host,
		"client": client,
		"host_transport": pair[0],
		"client_transport": pair[1],
	}


func _dispose(fixture: Dictionary) -> void:
	fixture["host"].dispose()
	fixture["client"].dispose()
	fixture["host_transport"].close()
	fixture["client_transport"].close()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)
