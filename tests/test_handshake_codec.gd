extends SceneTree
## Run: godot --headless --path . -s res://tests/test_handshake_codec.gd

var _failures := 0


func _initialize() -> void:
	_test_hello_round_trip()
	_test_welcome_round_trip()
	_test_reject_round_trip()
	_test_malformed_packets()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_hello_round_trip() -> void:
	var message := HandshakeCodec.Message.new()
	message.kind = HandshakeCodec.Message.Kind.CLIENT_HELLO
	message.build_version = "0.1.0-test"
	message.content_hash = "sha256:test-content"
	var decoded := HandshakeCodec.decode(HandshakeCodec.encode(message))
	_expect(decoded != null, "hello: valid packet rejected")
	if decoded == null:
		return
	_expect(decoded.kind == HandshakeCodec.Message.Kind.CLIENT_HELLO, "hello: wrong kind")
	_expect(decoded.protocol_version == HandshakeCodec.PROTOCOL_VERSION, "hello: wrong protocol")
	_expect(decoded.build_version == message.build_version, "hello: build changed")
	_expect(decoded.content_hash == message.content_hash, "hello: content hash changed")


func _test_welcome_round_trip() -> void:
	var message := HandshakeCodec.Message.new()
	message.kind = HandshakeCodec.Message.Kind.HOST_WELCOME
	message.session_id = 123456
	message.player_slot = 3
	var decoded := HandshakeCodec.decode(HandshakeCodec.encode(message))
	_expect(decoded != null, "welcome: valid packet rejected")
	if decoded != null:
		_expect(decoded.kind == HandshakeCodec.Message.Kind.HOST_WELCOME, "welcome: wrong kind")
		_expect(decoded.session_id == 123456, "welcome: session changed")
		_expect(decoded.player_slot == 3, "welcome: slot changed")


func _test_reject_round_trip() -> void:
	var message := HandshakeCodec.Message.new()
	message.kind = HandshakeCodec.Message.Kind.REJECT
	message.reject_reason = "protocol_mismatch"
	var decoded := HandshakeCodec.decode(HandshakeCodec.encode(message))
	_expect(decoded != null and decoded.reject_reason == message.reject_reason,
		"reject: reason did not round-trip")


func _test_malformed_packets() -> void:
	var message := HandshakeCodec.Message.new()
	message.build_version = "test"
	message.content_hash = "content"
	var valid := HandshakeCodec.encode(message)
	_expect(HandshakeCodec.decode(PackedByteArray()) == null, "malformed: empty packet accepted")
	for length: int in valid.size():
		_expect(HandshakeCodec.decode(valid.slice(0, length)) == null,
			"malformed: truncated packet of %d bytes accepted" % length)
	var bad_magic := valid.duplicate()
	bad_magic[0] ^= 0xff
	_expect(HandshakeCodec.decode(bad_magic) == null, "malformed: bad magic accepted")
	var unknown_kind := valid.duplicate()
	unknown_kind[4] = 99
	_expect(HandshakeCodec.decode(unknown_kind) == null, "malformed: unknown kind accepted")
	var trailing := valid.duplicate()
	trailing.append(0)
	_expect(HandshakeCodec.decode(trailing) == null, "malformed: trailing byte accepted")
	var oversized := PackedByteArray()
	oversized.resize(HandshakeCodec.MAX_PACKET_SIZE + 1)
	_expect(HandshakeCodec.decode(oversized) == null, "malformed: oversized packet accepted")
	message.build_version = "x".repeat(HandshakeCodec.MAX_STRING_BYTES + 1)
	_expect(HandshakeCodec.encode(message).is_empty(), "malformed: oversized string encoded")
	message.build_version = ""
	_expect(HandshakeCodec.encode(message).is_empty(), "malformed: empty build encoded")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)
