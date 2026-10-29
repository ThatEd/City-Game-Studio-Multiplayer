extends Reference

# Multiplayer saves.
#
# Why the game's own save names are not enough
# --------------------------------------------
# The game names a save after the player's own id and keeps it in `user://`:
#
#     user://<player id>.cgs          the save
#     user://<player id>.cgs.autosave the file being written
#
# For single player that is right. For co-op it is wrong in two specific ways:
#
#   1. **The same person in two sessions.** A player who joins host A's world and then host B's world
#      has one id in each - but the game keeps one `lastsavegame`, and Continue loads whatever was
#      written last. A player ends up loading the wrong world's save.
#   2. **The join itself.** A client boots the *host's* world, which carries the host's player id, so a
#      naive save writes the host's id - overwriting the host's own save if both run on one machine, and
#      handing that name to the relay as "the" save.
#
# What this does
# --------------
# A co-op save is named after the session *and* the player, so the two can never collide:
#
#     user://coop-<session>-<player>.cgs
#
# The session is derived from the world the player joined (the host's save id), the player from their own
# co-op id. Nothing about the game's save format changes; only the name does, and the game already treats
# a save as "whatever filename it is given".
#
# What the relay keeps
# ---------------------
# `server/coop_server.py` already keeps each player's company record. It now also keeps the name of the
# save they were playing (`save` field on the record), so a returning player is told which save is theirs
# before they land in a world - that is the "server feeds all the players the correct save" part. The
# save *file* never leaves the machine it was written on; what travels is the name plus the company.

const coop_log = preload("res://coop/log.gd")
const PREFIX = "coop-"


# The save name for this player in this session.
#
# `session` is the host's save id (what the world was loaded from), `player` is the co-op player id. Both
# are reduced to a safe filename: the game writes `<name>.cgs`, and a name with a slash or a colon in it
# would write somewhere else entirely.
static func save_name(session, player):
	# Each part is reduced to its bare identifier first: both the session name and the player id already
	# carry a `coop-` prefix, and keeping it produced `coop-coop-tester-coop-tester`.
	var safe_session = __bare(session)
	var safe_player = __bare(player)
	if safe_player == "":
		return ""
	if safe_session == "":
		return PREFIX + safe_player
	return "%s%s-%s" % [PREFIX, safe_session, safe_player]


# A part of a save name with its own prefix and any directory decoration removed.
static func __bare(text):
	var value = String(text)
	# Trailing decoration first, then the directory part, then the shared prefix. `find_last` is not
	# available in this engine build, so the last separator is found by scanning.
	if value.ends_with(".cgs"):
		value = value.substr(0, value.length() - 4)
	elif value.ends_with(".autosave"):
		value = value.substr(0, value.length() - 9)
	var cut = -1
	var index = 0
	while index < value.length():
		if value.substr(index, 1) == "/":
			cut = index
		index += 1
	if cut >= 0:
		value = value.substr(cut + 1, value.length())
	if value.begins_with(PREFIX):
		value = value.substr(PREFIX.length(), value.length())
	return __safe(value)


# The name of the save this machine is playing, so it can be reported to the relay and handed back later.
static func current_name(session, player):
	return save_name(session, player)


# A stable session name for a world that has no save of its own yet.
#
# A world started from New Game has no filename, but clients still need a per-session name to build their
# own saves from - otherwise two different worlds played with the same host name produce the same client
# save name and overwrite each other.
static func session_name_from(host_name):
	var base = __bare(host_name)
	if base == "":
		base = "session"
	return "%s%s" % [PREFIX, base]


# Whether a save name belongs to a co-op session rather than to single player.
static func is_coop_save(name):
	return String(name).begins_with(PREFIX)


# Every co-op save for one session, for the lobby to offer a returning player.
static func list_for_session(session):
	var out = []
	var safe_session = __safe(session)
	if safe_session == "":
		return out
	var prefix = "%s%s-" % [PREFIX, safe_session]
	var dir = Directory.new()
	if dir.open("user://") != OK:
		return out
	dir.list_dir_begin()
	var filename = dir.get_next()
	while filename != "":
		if not dir.current_is_dir() and filename.begins_with(prefix) and filename.ends_with(".cgs"):
			out.push_back(filename)
		filename = dir.get_next()
	dir.list_dir_end()
	return out


# Turns a save name back into the player it belongs to.
static func player_of(name):
	var text = String(name)
	if not text.begins_with(PREFIX):
		return ""
	var rest = text.substr(PREFIX.length(), text.length())
	var dash = rest.find("-")
	if dash < 0:
		return rest
	return rest.substr(dash + 1, rest.length())


# Copies a co-op session's save to a plain single-player name, so a player can carry on alone.
static func export_to_single(session, player, plain_name):
	var from = save_name(session, player)
	if from == "" or plain_name == "":
		return "nothing to export"
	var source = "user://%s.cgs" % [from]
	var target = "user://%s.cgs" % [__safe(plain_name)]
	var dir = Directory.new()
	if not dir.file_exists(source):
		return "no save called %s to export" % [from]
	if OK != dir.copy(source, target):
		return "could not copy %s to %s" % [source, target]
	coop_log.info("coop", "save: exported %s to %s" % [from, target])
	return "exported to %s" % [target]


static func __safe(text):
	var raw = String(text)
	var out = ""
	var index = 0
	while index < raw.length():
		var c = raw.substr(index, 1)
		# Ordered so the common case is cheap. `to_ascii()` is avoided deliberately: on this engine
		# build it is not a reliable way to classify a one-character String, and using it made every
		# character look unsafe - which silently produced the save name `coop--`.
		if c == "-" or c == "_" or c == " ":
			out += "_" if c == " " else c
		elif c >= "a" and c <= "z":
			out += c
		elif c >= "A" and c <= "Z":
			out += c
		elif c >= "0" and c <= "9":
			out += c
		index += 1
	if out.length() > 56:
		out = out.substr(0, 56)
	return out
