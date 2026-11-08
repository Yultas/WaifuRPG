class_name HandshakeCodec
extends RefCounted

## Versioned binary handshake without Variant or object deserialization.
## All integers are little-endian; strings carry a uint16 UTF-8 byte length.

const PROTOCOL_VERSION := 1
const MAX_PACKET_SIZE := 1024
const MAX_STRING_BYTES := 128
const _MAGIC := 0x57525047


class Message:
	extends RefCounted

	enum Kind { CLIENT_HELLO = 1, HOST_WELCOME = 2, REJECT = 3 }

	var kind := Kind.CLIENT_HELLO
	var protocol_version := HandshakeCodec.PROTOCOL_VERSION
	var build_version := ""
	var content_hash := ""
	var session_id := 0
	var player_slot := 0
	var reject_reason := ""


class Reader:
	extends RefCounted

	var bytes: PackedByteArray
	var offset := 0
	var failed := false


	func _init(source: PackedByteArray) -> void:
		bytes = source


	func remaining() -> int:
		return bytes.size() - offset


	func read_u8() -> int:
		if remaining() < 1:
			failed = true
			return 0
		var value := bytes[offset]
		offset += 1
		return value


	func read_u16() -> int:
		if remaining() < 2:
			failed = true
			return 0
		var value := bytes.decode_u16(offset)
		offset += 2
		return value


	func read_u32() -> int:
		if remaining() < 4:
			failed = true
			return 0
		var value := bytes.decode_u32(offset)
		offset += 4
		return value


	func read_string() -> String:
		var length := read_u16()
		if failed or length > HandshakeCodec.MAX_STRING_BYTES or remaining() < length:
			failed = true
			return ""
		var value := bytes.slice(offset, offset + length).get_string_from_utf8()
		offset += length
		return value


static func encode(message: Message) -> PackedByteArray:
	if message == null or not _is_valid(message):
		return PackedByteArray()
	var packet := PackedByteArray()
	_append_u32(packet, _MAGIC)
	_append_u8(packet, message.kind)
	match message.kind:
		Message.Kind.CLIENT_HELLO:
			_append_u16(packet, message.protocol_version)
			_append_string(packet, message.build_version)
			_append_string(packet, message.content_hash)
		Message.Kind.HOST_WELCOME:
			_append_u16(packet, message.protocol_version)
			_append_u32(packet, message.session_id)
			_append_u8(packet, message.player_slot)
		Message.Kind.REJECT:
			_append_string(packet, message.reject_reason)
	return packet


static func decode(packet: PackedByteArray) -> Message:
	if packet.size() < 5 or packet.size() > MAX_PACKET_SIZE:
		return null
	var reader := Reader.new(packet)
	if reader.read_u32() != _MAGIC:
		return null
	var message := Message.new()
	message.kind = reader.read_u8() as Message.Kind
	match message.kind:
		Message.Kind.CLIENT_HELLO:
			message.protocol_version = reader.read_u16()
			message.build_version = reader.read_string()
			message.content_hash = reader.read_string()
		Message.Kind.HOST_WELCOME:
			message.protocol_version = reader.read_u16()
			message.session_id = reader.read_u32()
			message.player_slot = reader.read_u8()
		Message.Kind.REJECT:
			message.reject_reason = reader.read_string()
		_:
			return null
	if reader.failed or reader.remaining() != 0 or not _is_valid(message):
		return null
	return message


static func _is_valid(message: Message) -> bool:
	if message.protocol_version <= 0:
		return false
	match message.kind:
		Message.Kind.CLIENT_HELLO:
			return _valid_string(message.build_version) and _valid_string(message.content_hash)
		Message.Kind.HOST_WELCOME:
			return message.session_id > 0 and message.player_slot >= 0 and message.player_slot < 4
		Message.Kind.REJECT:
			return _valid_string(message.reject_reason)
	return false


static func _valid_string(value: String) -> bool:
	var size := value.to_utf8_buffer().size()
	return not value.is_empty() and size <= MAX_STRING_BYTES


static func _append_u8(packet: PackedByteArray, value: int) -> void:
	packet.append(value)


static func _append_u16(packet: PackedByteArray, value: int) -> void:
	var offset := packet.size()
	packet.resize(offset + 2)
	packet.encode_u16(offset, value)


static func _append_u32(packet: PackedByteArray, value: int) -> void:
	var offset := packet.size()
	packet.resize(offset + 4)
	packet.encode_u32(offset, value)


static func _append_string(packet: PackedByteArray, value: String) -> void:
	var bytes := value.to_utf8_buffer()
	_append_u16(packet, bytes.size())
	packet.append_array(bytes)
