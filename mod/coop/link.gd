extends Reference

# TCP client to the co-op server.
#
# The game can only be a client: this engine build has StreamPeerTCP but no TCPServer (probed in
# the shipped exe, see main.gd __probe_classes). That is exactly why the session has an
# off-game server: the game dials out, the server does the fan-out, and the link is a reliable,
# ordered TCP stream, so no sequencing or retransmission is needed here.
#
# Framing matches coop_server.py: 8 decimal digits of byte length, then that many bytes of JSON.
#
# Reading is streamed, not "wait for a whole frame": whatever has arrived is taken into a String
# and complete frames are cut out of it. Waiting for a whole frame first deadlocks as soon as a
# message is bigger than the socket receive buffer (64 KB here), which is the case for the company
# logo and for a world slice, and it was the reason a joining client sat with a full 64 KB buffer
# and never read a byte.
#
# That String accumulation is only valid because every message the relay sends is pure ASCII: it
# always re-serialises with json.dumps, whose default ensure_ascii=True escapes anything else. A
# byte count and a character count therefore agree, so the length prefix can be used as a String
# offset. coop_server.py keeps ensure_ascii=True explicitly for that reason.

const PREFIX = 8
# The host's world travels in one message per model; the largest model (map) is a few MB.
const MAX_MESSAGE = 64 * 1024 * 1024
const coop_log = preload("res://coop/log.gd")

var peer = null
var address = ""
var port = 0
var connected = false
var last_error = ""
var stats_sent = 0
var stats_received = 0
var stats_frames = 0
# When set to a log name, every socket call is logged before and after it, so a native crash
# names the one call that killed the process.
var trace_name = ""

# Last known socket state, for the diagnostic log.
var last_status = -99
var last_available = 0
var last_put_error = 0
var inbox = ""

var __announced = false

# Every message kind is counted here as it crosses the socket, in both directions. Without this the
# question "has this call ever run?" can only be answered from memory, and memory said yes to things
# that had never been on the wire: the verify suite asserted model values, never that the code that
# moves them had executed. Counting at the transport boundary is the one place that cannot miss a
# kind, because every kind has to pass through send() or poll().
var census_sent = {}
var census_received = {}


func connect_to(host, target_port):
	address = host
	port = target_port
	peer = StreamPeerTCP.new()
	inbox = ""

	var error = peer.connect(host, target_port)
	if error != OK:
		last_error = "connect to %s:%d failed (error %d)" % [host, target_port, error]
		peer = null
		return false

	__announced = false
	return true


func status():
	if peer == null:
		return -1
	return peer.get_status()


func is_live():
	return peer != null and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


# One line of transport truth per second: socket status, bytes readable, last write result.
func debug_line():
	if peer == null:
		return "no socket"
	return "status=%s connected=%s available=%s sent=%s received=%s frames=%s inbox=%s put_error=%s error=%s" % [
		String(last_status), String(connected), String(last_available),
		String(stats_sent), String(stats_received), String(stats_frames),
		String(inbox.length()), String(last_put_error), last_error
	]


# Reads whatever has arrived and returns the complete messages in it.
func poll():
	var messages = []
	if peer == null:
		return messages

	var previous_status = last_status
	last_status = peer.get_status()
	if last_status != previous_status:
		__trace("get_status=" + String(last_status))

	var now_live = last_status == StreamPeerTCP.STATUS_CONNECTED
	if now_live != connected:
		connected = now_live
		__announced = false

	# Only ask a live socket how much it has.
	#
	# get_available_bytes() on a socket whose peer has gone raises an engine error every single call -
	# 4,618 of them in the two minutes between the relay saying the host was gone and the player pressing
	# Confirm - and filled a 1 MB error log with one identical line. There is nothing to read from a dead
	# socket, so it is not asked.
	if not now_live:
		return messages

	last_available = peer.get_available_bytes()
	if last_available > 0:
		var chunk = peer.get_data(last_available)
		var error = int(chunk[0])
		var bytes = chunk[1]
		if error != OK:
			last_error = "read failed (error %d)" % [error]
			return messages
		if bytes.size() > 0:
			stats_received += bytes.size()
			__trace("read %s bytes" % [String(bytes.size())])
			inbox += bytes.get_string_from_utf8()

	while inbox.length() >= PREFIX:
		var prefix = inbox.substr(0, PREFIX)
		if prefix.length() != PREFIX or not prefix.is_valid_integer():
			last_error = "server sent a bad frame prefix"
			inbox = ""
			break

		var length = int(prefix)
		if length <= 0 or length > MAX_MESSAGE:
			last_error = "server sent a bad frame length %d" % [length]
			inbox = ""
			break

		# The rest of the frame has not all arrived yet; the next poll() continues it.
		if inbox.length() < PREFIX + length:
			break

		var body = inbox.substr(PREFIX, length)
		inbox = inbox.substr(PREFIX + length, inbox.length() - PREFIX - length)
		stats_frames += 1

		var message = {}
		if message.parse_json(body) != OK:
			last_error = "server sent unparsable JSON"
			continue
		if message.has("t"):
			__count(census_received, String(message["t"]))
		messages.push_back(message)

	return messages


func send(message):
	if not is_live():
		return false

	if message.has("t"):
		__count(census_sent, String(message["t"]))

	var body = message.to_json()
	var byte_count = body.to_utf8().size()
	var header = String(byte_count)
	while header.length() < PREFIX:
		header = "0" + header

	if header.length() > PREFIX:
		last_error = "message too large to frame (%s bytes)" % [String(byte_count)]
		return false

	var error = peer.put_data((header + body).to_utf8())
	__trace("put_data(%s bytes) -> %s" % [header, String(error)])
	last_put_error = error
	if error != OK:
		last_error = "write failed (error %d)" % [error]
		connected = false
		return false

	stats_sent += byte_count
	return true


func close():
	if peer != null:
		peer.disconnect()
	peer = null
	inbox = ""
	connected = false


func __trace(text):
	if trace_name != "":
		coop_log.info(trace_name, "trace: " + text)


func __count(table, kind):
	if table.has(kind):
		table[kind] = int(table[kind]) + 1
	else:
		table[kind] = 1


# "kind=count" pairs, sorted, so two logs can be diffed and a missing kind is obvious.
static func census_text(table):
	var kinds = table.keys()
	kinds.sort()
	var parts = []
	for kind in kinds:
		parts.push_back("%s=%s" % [kind, String(table[kind])])
	if parts.size() == 0:
		return "none"
	var text = ""
	for part in parts:
		if text != "":
			text += " "
		text += String(part)
	return text
