extends Reference

# A remote control for a running game, so a person can drive the real UI one press at a time.
#
# This is not a test and not a script. It is a channel: a command file written by hand (or by a shell
# one line at a time), executed once, and answered in a log. Whoever is driving reads the answer and the
# screen before deciding the next command, which is what playing the game is - as opposed to running a
# fixed sequence and asserting afterwards.
#
#   echo "1 tree" >> coop/remote.cmd          # answered as "#1 ..." in coop/remote.log
#   echo "2 press project" >> coop/remote.cmd
#   echo "3 state" >> coop/remote.cmd
#
# Each command is executed exactly once: the highest sequence number seen is remembered, and anything at
# or below it is ignored, so a stale file is harmless.
#
# Commands:
#   tree                       every popup and the game's own menu bar, with visibility
#   find <name>                where a node called <name> is, and whether it can be pressed
#   press <name>               press it the way a click does (pressed signal, else _pressed())
#   fill <name> <text>         type into a text field
#   call <name> <method>       call a method on a node (for things with no button)
#   menu <button>              list the submenu a game menu button popped, item by item
#   menuitem <button> <index>  press item <index> of that submenu
#   dialogs                    everything sitting on top of the game right now
#   close                      press the top dialog's own close button
#   steam                      list and close the Steam "not detected" dialog
#   innodes <scene> <command>  run any of the above inside one popup, by its scene path
#   state                      date, money, offices, staff, games, other players
#   shot                       mark the point in the log a screenshot belongs to
#
# Names repeat across the game's screens - "select" is both the studio and the genre picker - so when a
# command needs disambiguating it goes through `innodes <scene>`. The scene is matched on the tail of the
# path, e.g. innodes project/kickoff-self press select.
#
# Enabled with --coop-remote; the files live beside the mod's log directory.

const coop_log = preload("res://coop/log.gd")
const automation = preload("res://coop/automation.gd")
const company = preload("res://coop/company.gd")
const dict_lib = preload("res://coop/dict.gd")

const COMMAND_PREFIX = "remote-"
const ANSWER_PREFIX = "remote-"
const POLL_INTERVAL = 0.25

const GAME_MENU_SCENE = "res://scenes/game/menu.tscn"
# The in-game scene itself. Some of what a player clicks is drawn here rather than in a popup: the
# in-development project list, with each finished project's Release button, is part of it.
const GAME_SCENE = "res://scenes/game/main.tscn"

# Everything below is one flat list of helpers, and the first tick checks each one is really there: a
# script that stops parsing part way keeps the functions it already registered and silently loses the
# rest, and the only symptom is "Nonexistent function" at the moment a command is used.
const REMOTE_HELPERS = ["__run", "__tree", "__state", "__find", "__press", "__fill", "__call",
	"__menu", "__menu_item", "__menu_button", "__popup_of", "__dialogs", "__close", "__find_node",
	"__paths", "__collect", "__press_path", "__click_path", "__in_nodes", "__popup_by_scene",
	"__children", "__press_node", "__fill_node", "__call_on_node", "__answer", "company_join",
	"command_file", "answer_file"]


# Both instances run out of the same folder, so each drives itself through its own pair of files, named
# after its log (remote-R1-client.cmd and so on).
static func command_file(coop):
	return COMMAND_PREFIX + String(coop.config.log_name) + ".cmd"


static func answer_file(coop):
	return ANSWER_PREFIX + String(coop.config.log_name) + ".log"


static func _command_head(line):
	var space = line.find(" ")
	return line if space < 0 else line.substr(0, space)


static func tick(coop):
	if not coop.config.remote:
		return
	# Deliberately not gated on models.is_loaded(): the menu commands are how a test gets *into* a game,
	# so requiring a loaded game to reach them meant the channel sat silent exactly when it was needed.
	# The commands that do need the models say so themselves.
	#
	# A GDScript file that fails to parse this far keeps the functions it already registered and drops the
	# rest, with no error in the log - the commands then answer "Nonexistent function" while everything
	# looks healthy. So the first tick asks this script which helpers it actually has.
	if not coop.__remote_reported:
		coop.__remote_reported = true
		# Asked of an instance of this script, not of self: every helper here is static, so asking self
		# reported "0 of 28 loaded" on a perfectly good file. get_method_list() is used because it is
		# the one introspection call this engine build is known to provide.
		var missing = []
		var loaded = []
		var script = load("res://coop/remote.gd")
		var probe = null
		if script != null:
			probe = script.new()
		if probe != null:
			for entry in probe.get_method_list():
				loaded.push_back(String(entry.name))
		for wanted in REMOTE_HELPERS:
			if not loaded.has(String(wanted)):
				missing.push_back(String(wanted))
		coop_log.info(coop.config.log_name, "remote: ready, %s of %s helper(s) loaded" % [
			String(REMOTE_HELPERS.size() - missing.size()), String(REMOTE_HELPERS.size())
		])
		if missing.size() > 0:
			coop_log.warning(coop.config.log_name, "remote: NOT LOADED: " + company.join(missing, " "))
	if coop.__elapsed < coop.__remote_next_at:
		return
	coop.__remote_next_at = coop.__elapsed + POLL_INTERVAL

	var text = coop_log.read_text(command_file(coop))
	if text == null or text.strip_edges() == "":
		return

	# Commands are remembered by their text, not only by their number.
	#
	# The number says "this one has already run", which only works while the file is appended to. Rewriting
	# the file - the obvious way to queue a command by hand - restarted the numbering and the new commands
	# were silently ignored until they passed the old high-water mark; that cost two runs. Remembering the
	# text means a rewritten file works whatever numbers it carries, and the same file polled again does
	# not repeat itself.
	for raw_line in text.split("\n"):
		var line = String(raw_line).strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		if not _command_head(line).is_valid_integer():
			continue
		if coop.__remote_done.has(line):
			continue
		coop.__remote_done[line] = true
		var space = line.find(" ")
		var seq = int(_command_head(line))
		coop.__remote_seq = seq
		var command = "" if space < 0 else line.substr(space + 1, line.length() - space - 1)
		coop_log.info(coop.config.log_name, "remote: command %s [%s]" % [String(seq), command])
		# Answers are written before the command runs, so a command that kills a call is still visible in
		# the log: "running" is the last line for a command that never came back.
		coop_log.info(coop.config.log_name, "remote: --- %s: %s (running)" % [String(seq), command])
		var answer = __run(coop, command)
		__answer(coop, seq, command, answer)
		return


static func __run(coop, command):
	var parts = command.split(" ")
	var verb = parts[0]
	var arg1 = parts[1] if parts.size() > 1 else ""
	var rest = ""
	if parts.size() > 2:
		rest = command.substr(command.find(arg1) + arg1.length() + 1, command.length())
	if verb == "tree":
		return __tree(coop)
	if verb == "state":
		return __state(coop)
	if verb == "shot":
		return "screenshot point"
	if verb == "find":
		return __find(coop, arg1)
	if verb == "press":
		return __press(coop, arg1)
	if verb == "fill":
		return __fill(coop, arg1, rest)
	if verb == "call":
		return __call(coop, arg1, rest)
	if verb == "menu":
		return __menu(coop, arg1)
	if verb == "menuitem":
		return __menu_item(coop, arg1, rest.strip_edges())
	if verb == "dialogs":
		return __dialogs(coop)
	if verb == "close":
		return __close(coop)
	if verb == "innodes":
		return __in_nodes(coop, arg1, rest.strip_edges())
	if verb == "paths":
		return __paths(coop, arg1)
	if verb == "presspath":
		return __press_path(coop, arg1)
	if verb == "clickpath":
		return __click_path(coop, arg1)
	if verb == "steam":
		return __steam(coop)
	if verb == "grep":
		return __grep(coop, arg1)
	if verb == "findall":
		return __findall(coop, arg1)
	if verb == "pressroot":
		return __press_root(coop, arg1)
	if verb == "date":
		return __date(coop, arg1, rest.strip_edges())
	if verb == "own":
		return __own(coop)
	if verb == "clock":
		return __clock(coop)
	if verb == "trends":
		return __trends(coop)
	if verb == "lobby":
		return __lobby(coop, arg1, rest.strip_edges())
	return "unknown command [%s]; try tree, find, findall, press, fill, call, menu, menuitem, dialogs, " \
		% [verb] + "close, steam, innodes, paths, presspath, clickpath, grep, date, lobby, state"


# The clock, through the same controller the calendar's own buttons call. "date pause" and "date run" are
# what the play/pause button does; "date speed <n>" is one of the 1x/2x/4x/6x buttons.
static func __date(coop, what, speed_text):
	if not models.has_model("date"):
		return "no date model loaded"
	var date_controller = controllers.get_controller("date")
	var date_model = models.get_model("date")
	if String(what) == "pause":
		date_controller.call("set_pause", true)
		return "paused the world"
	if String(what) == "run":
		date_controller.call("set_pause", false)
		return "unpaused the world"
	if String(what) == "speed":
		var wanted = int(speed_text) if String(speed_text).is_valid_integer() else 1
		date_model.call("set_speed", wanted)
		date_controller.call("compute_state")
		return "set speed %s (now %s)" % [String(wanted), String(date_model.get_speed_index())]
	var date = date_model.get_date()
	return "date now: raw=%s year=%s month=%s week=%s paused=%s started=%s speed=%s tick=%s" % [
		String(date_model.get_raw_date()), String(date.year), String(date.month), String(date.week),
		String(bool(date_model.paused)), String(bool(date_model.is_started())),
		String(date_model.get_speed_index()), String(date_model.get_week_duration())
	]


# The Steam "not detected" window. It is a WindowDialog inside the store manager, so it floats above every
# popup the game itself opens and covers the bottom half of the new-game form during a co-op test run.
# Closing it is exactly what a player does with its X when they play without Steam.
static func __steam(coop):
	var store = coop.get_tree().get_root().find_node("store_manager", true, false)
	if store == null:
		return "no store manager in this scene tree"
	var dialog = store.find_node("window", true, false)
	if dialog == null:
		return "the store manager has no Steam window"
	var lines = ["the Steam window is hidden=%s" % [String(bool(dialog.call("is_hidden")))]]
	var close = store.find_node("close", true, false)
	if close == null:
		lines.push_back("no close button found")
		return company_join(lines)
	if close.has_method("emit_signal"):
		close.emit_signal("pressed")
	else:
		close.call("_pressed")
	lines.push_back("closed it")
	return company_join(lines)


# Every node with this name, with its full path, so an ambiguous name ("select" is both the genre and the
# theme button) can be told apart without guessing.
static func __paths(coop, name):
	var popups = coop.get_tree().get_nodes_in_group("popup-node")
	var lines = []
	for index in range(popups.size()):
		var popup = popups[popups.size() - 1 - index]
		if popup == null:
			continue
		var found = []
		__collect(popup, name, found)
		for node in found:
			var detail = String(popup.get_filename()) + " :: " + String(popup.get_path_to(node))
			if node.has_method("is_disabled"):
				detail += " disabled=%s" % [String(bool(node.call("is_disabled")))]
			lines.push_back(detail)
	if lines.size() == 0:
		return "no node called [%s] inside any popup" % [name]
	return company_join(lines)


# Every node with this name anywhere a player can click, with the rectangle it occupies on screen. Names
# repeat across the game's screens and across instanced cards - several project cards each have their own
# `release` button, and the released-games panel has one too - so the rect is what tells them apart. A
# rect off the screen, or zero-sized, is not the button the player is looking at.
static func __findall(coop, name):
	var lines = []
	var areas = []
	areas.push_back([coop.get_tree().get_root(), "scene tree"])
	for area in areas:
		var root = area[0]
		if root == null:
			continue
		var all = []
		__collect_all(root, all)
		for node in all:
			if String(node.get_name()) != String(name):
				continue
			var detail = String(area[1]) + " :: " + String(root.get_path_to(node))
			if node.has_method("is_visible"):
				detail += " visible=%s" % [String(bool(node.call("is_visible")))]
			if node.has_method("is_hidden"):
				detail += " hidden=%s" % [String(bool(node.call("is_hidden")))]
			if node.has_method("is_disabled"):
				detail += " disabled=%s" % [String(bool(node.call("is_disabled")))]
			if node.has_method("get_global_rect"):
				detail += " rect=%s" % [String(node.call("get_global_rect"))]
			lines.push_back(detail)
	if lines.size() == 0:
		return "no node called [%s] anywhere" % [name]
	return company_join(lines)


# Every node whose name begins with this, with its full path. The genre cards are named after the genre
# ("Action", "Dungeon", "FPS"), and the panel's own nodes are not, so this is how one card is addressed.
static func __grep(coop, prefix):
	var popups = coop.get_tree().get_nodes_in_group("popup-node")
	var lines = []
	for index in range(popups.size()):
		var popup = popups[popups.size() - 1 - index]
		if popup == null:
			continue
		var all = []
		__collect_all(popup, all)
		for node in all:
			if not String(node.get_name()).begins_with(String(prefix)):
				continue
			lines.push_back("%s :: %s" % [
				String(popup.get_filename()), String(popup.get_path_to(node))
			])
	if lines.size() == 0:
		return "no node starting with [%s] inside any popup" % [prefix]
	return company_join(lines)


static func __collect_all(node, found):
	if node == null:
		return
	found.push_back(node)
	for child in node.get_children():
		__collect_all(child, found)


static func __collect(node, name, found):
	if node == null:
		return
	if String(node.get_name()) == String(name):
		found.push_back(node)
	for child in node.get_children():
		__collect(child, name, found)


static func __press_path(coop, path):
	var popups = coop.get_tree().get_nodes_in_group("popup-node")
	for index in range(popups.size()):
		var popup = popups[popups.size() - 1 - index]
		if popup == null:
			continue
		var node = popup.get_node(String(path))
		if node != null:
			return __press_node(node, String(path))
	return "no node at [%s] in any open popup" % [path]


# Some of the game's own items are not Buttons: a genre card handles its click in _input(), where it
# emits `toggled(type_name, type_weight)` (scripts/game/project/game/game-genre.gd), so emitting "pressed"
# would do nothing at all. This build provides no way to synthesise an input event either - naming
# InputEventMouseButton is a compile error, and InputEvent itself has no new() - so the item's own signal
# is emitted with exactly the arguments its _input would have sent. The type name is the node's name
# (the panel sets it with set_name(type_name)) and the weight comes from the same model the card reads.
static func __click_path(coop, path):
	var node = null
	var popups = coop.get_tree().get_nodes_in_group("popup-node")
	for index in range(popups.size()):
		var popup = popups[popups.size() - 1 - index]
		if popup == null:
			continue
		node = popup.get_node(String(path))
		if node != null:
			break
	if node == null:
		return "no node at [%s] in any open popup" % [path]

	if node.has_method("emit_signal") and __has_signal(node, "toggled"):
		var type_name = String(node.get_name())
		var weight = 1
		if models.has_model("game-type"):
			var gametype = models.get_model("game-type")
			if gametype.has_method("get_type_weight_from_data"):
				var data = gametype.call("get_game_type_by_name", type_name)
				if data != null:
					weight = int(gametype.call("get_type_weight_from_data", data))
		node.emit_signal("toggled", type_name, weight)
		return "clicked [%s] through its own toggled signal (%s, weight %s)" % [
			path, type_name, String(weight)
		]
	return __press_node(node, String(path))


static func __has_signal(node, wanted):
	if not node.has_method("get_signal_list"):
		return false
	for entry in node.call("get_signal_list"):
		if String(entry.name) == String(wanted):
			return true
	return false


# Presses a node addressed from the scene root, as `findall` reports it. Necessary because the buttons a
# player clicks are not all inside popups: the Release button on a finished project lives in the HUD
# (game/GUI/IndevProject/...), and `presspath` only searches popups, so it reported "no node at" for the
# one button that matters. The same name also exists in the released-games panel, which is why the path
# is used rather than the name.
static func __press_root(coop, path):
	var root = coop.get_tree().get_root()
	var node = root.get_node(String(path))
	if node == null:
		return "no node at [%s] from the scene root" % [path]
	return __press_node(node, String(path))


# Runs a command with the search confined to one popup, chosen by the tail of its scene path. Without
# this, pressing "select" hit the studio picker when the genre picker was meant: both screens have a node
# called select, and which one is found depends on which popup happens to be searched first.
static func __in_nodes(coop, scene_tail, command):
	var popup = __popup_by_scene(coop, scene_tail)
	if popup == null:
		return "no open popup whose scene ends with [%s]" % [scene_tail]
	var parts = command.split(" ")
	var verb = parts[0]
	var arg1 = parts[1] if parts.size() > 1 else ""
	var rest = ""
	if parts.size() > 2:
		rest = command.substr(command.find(arg1) + arg1.length() + 1, command.length())

	if verb == "find" or verb == "press" or verb == "fill" or verb == "call":
		var node = popup.find_node(arg1, true, false)
		if node == null:
			return "no node called [%s] inside [%s]" % [arg1, scene_tail]
		if verb == "find":
			var detail = "found [%s] visible=%s" % [
				arg1, String(node.is_visible()) if node.has_method("is_visible") else "?"
			]
			if node.has_method("is_disabled"):
				detail += " disabled=%s" % [String(bool(node.call("is_disabled")))]
			if node.has_method("get_text"):
				detail += " text=[%s]" % [String(node.call("get_text"))]
			return detail
		if verb == "press":
			return __press_node(node, arg1)
		if verb == "fill":
			return __fill_node(node, arg1, rest)
		return __call_on_node(node, arg1, rest)
	if verb == "tree":
		var lines = ["inside [%s]:" % [scene_tail]]
		for line in __children(popup, 1):
			lines.push_back(line)
		return company_join(lines)
	return "inside a popup only find, press, fill, call and tree make sense, got [%s]" % [verb]


static func __popup_by_scene(coop, tail):
	var popups = coop.get_tree().get_nodes_in_group("popup-node")
	for index in range(popups.size()):
		var popup = popups[popups.size() - 1 - index]
		if popup == null:
			continue
		var path = String(popup.get_filename())
		if path == null or path == "":
			continue
		if path.ends_with(String(tail)) or path.find(String(tail)) >= 0:
			return popup
	return null


static func __children(node, depth):
	var lines = []
	if node == null or depth > 8:
		return lines
	for child in node.get_children():
		if child == null:
			continue
		var shown = true
		if child.has_method("is_visible"):
			shown = bool(child.is_visible())
		var extra = ""
		if child.has_method("is_disabled") and bool(child.call("is_disabled")):
			extra += " disabled"
		if child.has_method("get_text") and String(child.call("get_text")) != "":
			extra += " text=[%s]" % [String(child.call("get_text"))]
		var indent = ""
		for i in range(depth):
			indent += "  "
		lines.push_back("%s%s %s%s" % [indent, String(child.get_name()), "shown" if shown else "hidden", extra])
		for line in __children(child, depth + 1):
			lines.push_back(line)
	return lines


static func __press_node(node, name):
	if node.has_method("is_disabled") and bool(node.call("is_disabled")):
		return "[%s] is disabled, not pressing it" % [name]
	var connections = []
	if node.has_method("get_signal_connection_list"):
		connections = node.call("get_signal_connection_list", "pressed")
	if connections.size() > 0:
		node.emit_signal("pressed")
		return "pressed [%s] via its pressed signal (%s handler(s))" % [name, String(connections.size())]
	if node.has_method("_pressed"):
		node.call("_pressed")
		return "pressed [%s] via _pressed()" % [name]
	return "[%s] has no press path" % [name]


static func __fill_node(node, name, value):
	if not node.has_method("set_text"):
		return "[%s] is not a text field" % [name]
	node.call("set_text", value)
	node.emit_signal("text_changed", value)
	return "typed [%s] into [%s]" % [value, name]


static func __call_on_node(node, name, method):
	if not node.has_method(method):
		return "[%s] has no method [%s]" % [name, method]
	node.call(method)
	return "called %s() on [%s]" % [method, name]


# Everything a player can currently see or press that the mod knows about: the game's menu bar and every
# popup open on top of it.
static func __tree(coop):
	var lines = []
	var menu = automation.find_by_scene(coop.get_tree().get_root(), GAME_MENU_SCENE)
	if menu == null:
		lines.push_back("no game menu: this is not the in-game scene yet")
	else:
		var bar = null
		var options_button = menu.find_node("options", true, false)
		if options_button != null:
			bar = options_button.get_parent()
		if bar == null:
			lines.push_back("game menu has no button bar")
		else:
			lines.push_back("game menu bar:")
			for child in bar.get_children():
				lines.push_back("  %s %s%s" % [
					String(child.get_name()),
					"shown" if child.is_visible() else "hidden",
					" (disabled)" if child.has_method("is_disabled") and bool(child.call("is_disabled")) else ""
				])

	lines.push_back("open popups:")
	var popups = coop.get_tree().get_nodes_in_group("popup-node")
	if popups.size() == 0:
		lines.push_back("  none")
	for popup in popups:
		lines.push_back("  %s  %s  visible=%s" % [
			String(popup.get_name()), String(popup.get_filename()),
			String(popup.is_visible()) if popup.has_method("is_visible") else "?"
		])
	return company_join(lines)


static func __state(coop):
	var lines = []
	if models.has_model("date"):
		var date = models.get_model("date")
		lines.push_back("date raw=%s paused=%s frozen=%s" % [
			String(date.get_raw_date()), String(bool(date.paused)), String(coop.__date_frozen(date))
		])
	if models.has_model("currency"):
		lines.push_back("money %s" % [String(int(models.get_model("currency").get_currency()))])
	if models.has_model("fanbase"):
		lines.push_back("fanbase %s" % [String(int(models.get_model("fanbase").get_fanbase()))])
	if models.has_model("studio"):
		lines.push_back("offices %s" % [String(int(models.get_model("studio").get_number_of_studios()))])
	if models.has_model("staff"):
		lines.push_back("staff %s" % [String(company.my_staff_summary())])
	if models.has_model("game"):
		var catalog = models.get_model("game").get_data()["catalog"]
		var counts = []
		for bucket in ["dev", "hold", "published", "released", "canceled", "discontinued"]:
			if catalog.has(bucket) and catalog[bucket] != null:
				counts.push_back("%s=%s" % [bucket, String(catalog[bucket].size())])
		lines.push_back("games " + company_join(counts))
		for bucket in ["dev", "hold"]:
			if not catalog.has(bucket) or catalog[bucket] == null:
				continue
			for game_id in catalog[bucket]:
				var game = catalog[bucket][game_id]
				if game != null and game.has("name"):
					lines.push_back("  %s: %s step=%s" % [
						bucket, String(game["name"]), String(game["step"])
					])
	lines.push_back("other players %s" % [String(coop.ui_other_players().size())])
	for other in coop.ui_other_players():
		lines.push_back("  %s  %s" % [String(other), coop.ui_player_name(other)])
	# The console and server figures the owner reported as wrong: the client had millions of server users
	# without owning anything that needs a server, because it had inherited the host's store.
	if models.has_model("server"):
		var server = models.get_model("server")
		if server.has_method("get_usage"):
			lines.push_back("server users %s" % [String(int(server.call("get_usage")))])
		if server.has_method("get_online_players"):
			lines.push_back("server online %s" % [String(int(server.call("get_online_players")))])
	if models.has_model("custom-platform"):
		var consoles = company.my_consoles()
		lines.push_back("own consoles %s" % [String(consoles.size())])
		for entry in consoles:
			if entry != null and entry.has("name"):
				lines.push_back("  %s" % [String(entry["name"])])
	if models.has_model("digital-store"):
		var support = 0
		var store = models.get_model("digital-store").get_data()
		if store != null and store.has("platform") and store["platform"] != null:
			support = store["platform"].size()
		lines.push_back("store platforms %s" % [String(support)])
	var live = null
	if models.has_model("concurrent"):
		live = models.get_model("concurrent").get_concurrent()
	if live != null:
		lines.push_back("rivals modelled %s" % [String(live.size())])
	return company_join(lines)


static func __find(coop, name):
	var node = __find_node(coop, name)
	if node == null:
		return "no node called [%s] on screen" % [name]
	var detail = "found [%s] visible=%s" % [
		name,
		String(node.is_visible()) if node.has_method("is_visible") else "?"
	]
	if node.has_method("is_disabled"):
		detail += " disabled=%s" % [String(bool(node.call("is_disabled")))]
	if node.has_method("get_text"):
		detail += " text=[%s]" % [String(node.call("get_text"))]
	if node.has_method("is_pressed"):
		detail += " pressed=%s" % [String(bool(node.call("is_pressed")))]
	if node.has_method("get_global_rect"):
		detail += " rect=%s" % [String(node.call("get_global_rect"))]
	return detail


static func __press(coop, name):
	var node = __find_node(coop, name)
	if node == null:
		return "no node called [%s] to press" % [name]
	return __press_node(node, name)


static func __fill(coop, name, value):
	var node = __find_node(coop, name)
	if node == null:
		return "no node called [%s] to type into" % [name]
	return __fill_node(node, name, value)


static func __call(coop, name, method):
	var node = __find_node(coop, name)
	if node == null:
		return "no node called [%s]" % [name]
	return __call_on_node(node, name, method)


# The submenu a game menu button builds for itself. It is a native PopupMenu added as that button's child
# (scripts/game/menu/generic.gd _create_popup_menu), which the scene tree walk cannot see, so it is listed
# item by item with the button name each item carries in its metadata.
static func __menu(coop, button_name):
	var button = __menu_button(coop, button_name)
	if button == null:
		return "no game menu button called [%s]" % [button_name]
	var popup = __popup_of(button)
	if popup == null:
		return "[%s] builds no submenu" % [button_name]
	var count = int(popup.call("get_item_count"))
	if count == 0:
		return "[%s]'s submenu is empty" % [button_name]
	var lines = ["%s's submenu:" % [button_name]]
	for index in range(count):
		var meta = popup.call("get_item_metadata", index)
		var named = "?"
		if meta != null and typeof(meta) == TYPE_DICTIONARY and meta.has("button_name"):
			named = String(meta["button_name"])
		var disabled = false
		if popup.has_method("is_item_disabled"):
			disabled = bool(popup.call("is_item_disabled", index))
		lines.push_back("  %s %s%s" % [
			String(index), named, " (disabled)" if disabled else ""
		])
	return company_join(lines)


static func __menu_item(coop, button_name, index_text):
	if not String(index_text).is_valid_integer():
		return "menuitem needs an index, got [%s]" % [index_text]
	var button = __menu_button(coop, button_name)
	if button == null:
		return "no game menu button called [%s]" % [button_name]
	var popup = __popup_of(button)
	if popup == null:
		return "[%s] builds no submenu" % [button_name]
	var index = int(index_text)
	if index < 0 or index >= int(popup.call("get_item_count")):
		return "no item %s in [%s]'s submenu" % [String(index), button_name]
	if popup.has_method("is_item_disabled") and bool(popup.call("is_item_disabled", index)):
		return "item %s of [%s] is disabled" % [String(index), button_name]
	popup.emit_signal("item_pressed", index)
	var meta = popup.call("get_item_metadata", index)
	var named = String(meta["button_name"]) if meta != null and typeof(meta) == TYPE_DICTIONARY and meta.has("button_name") else "?"
	return "pressed submenu item %s (%s) of [%s]" % [String(index), named, button_name]


static func __menu_button(coop, button_name):
	var menu = automation.find_by_scene(coop.get_tree().get_root(), GAME_MENU_SCENE)
	if menu == null:
		return null
	return menu.find_node(button_name, true, false)


static func __popup_of(button):
	if button == null:
		return null
	for child in button.get_children():
		if child != null and child.has_method("get_item_metadata"):
			return child
	return null


# Everything the game treats as per-company progression, read from the models that hold it. These are the
# halves of the world that are NOT one shared world: two players must have their own. Reported here so
# the same question can be asked of both machines and the answers compared.
# The join lobby, driven and inspected here rather than by node name: its rows are created at runtime
# from the host's world, so there is no fixed name to press.
#
#   lobby                    what is on screen, and every row
#   lobby new                press "Start a new company"
#   lobby take <index>       press row <index>
static func __lobby(coop, what, arg):
	var panel = coop.__lobby_panel()
	if panel == null:
		return "no lobby on screen"
	var lines = []
	var status = ""
	var status_node = __child_named(panel, "status")
	if status_node != null and status_node.has_method("get_text"):
		status = String(status_node.get_text())
	lines.push_back("visible=%s status=[%s]" % [String(panel.is_visible()), status])

	var list = __child_named(panel, "list")
	if list != null:
		var index = 0
		for child in list.get_children():
			if child != null and child.has_method("get_text"):
				lines.push_back("  [%s] %s" % [String(index), String(child.get_text())])
				index += 1
		lines.push_back("  %s row(s)" % [String(index)])

	if String(what) == "new":
		var button = __child_named(panel, "lobby_new")
		if button == null:
			return "no [Start a new company] button in the lobby"
		button.emit_signal("pressed")
		lines.push_back("pressed [Start a new company]")
	elif String(what) == "name":
		# Types into the game's company form. The form is the game's own node tree, so the field is found
		# through it rather than through the popup the generic `fill` command searches.
		var field = __find_line_edit(panel)
		if field == null:
			var form = panel.find_node("company_form", true, false)
			if form == null:
				return "the company form is not open; press [Start a new company] first"
			return "the company form has no name field"
		field.set_text(String(arg))
		# The form saves on a debounce; the signal is what it listens for.
		field.emit_signal("text_changed", String(arg))
		lines.push_back("name set to [%s]" % [String(arg)])
	elif String(what) == "create":
		var ok = __child_named(panel, "create_ok")
		if ok == null:
			return "the company form is not open"
		ok.emit_signal("pressed")
		lines.push_back("pressed [Create and join]")
	elif String(what) == "take":
		if not String(arg).is_valid_integer():
			return "lobby take needs a row index, got [%s]" % [String(arg)]
		var wanted = int(arg)
		var at = 0
		var pressed = false
		for child in list.get_children():
			if child == null or not child.has_method("get_text"):
				continue
			if at == wanted:
				child.emit_signal("pressed")
				lines.push_back("pressed row [%s] %s" % [String(at), String(child.get_text())])
				pressed = true
				break
			at += 1
		if not pressed:
			return "no row [%s] in the lobby" % [String(wanted)]
	return company_join(lines)


# Finds a node by the name given to it, walking the tree.
#
# find_node(name) does not work for nodes the mod creates at runtime: in this engine build they are not
# registered under the name that was set, so a whole lobby subtree reports as `@@38`. Walking and
# comparing get_name() does work.
static func __child_named(root, name):
	if root == null:
		return null
	if String(root.get_name()) == String(name):
		return root
	for child in root.get_children():
		var found = __child_named(child, name)
		if found != null:
			return found
	return null


# The first LineEdit under a node, found by walking rather than by name.
#
# Nodes created at runtime in this build are not registered under the names they were given - the lobby's
# whole subtree shows up as `@@38` and the like - so find_node("name/value") inside it finds nothing.
# Walking and asking each node what it can do is the reliable way.
static func __find_line_edit(node):
	if node == null:
		return null
	if node.has_method("get_text") and node.has_method("set_text") and node.has_method("get_cursor_pos"):
		return node
	for child in node.get_children():
		var found = __find_line_edit(child)
		if found != null:
			return found
	return null


static func __own(coop):
	var lines = []
	lines.push_back("probe start")
	if models.has_model("game-type"):
		var genres = models.get_model("game-type").get_unlocked_game_types()
		lines.push_back("unlocked genres %s" % [String(genres.size())])
	if models.has_model("game-engine"):
		var engine_data = models.get_model("game-engine").get_data()
		var owned = []
		if engine_data != null and engine_data.has("owned") and engine_data["owned"] != null:
			for key in engine_data["owned"]:
				owned.push_back(String(key))
		lines.push_back("owned engines %s" % [String(owned.size())])
	if models.has_model("capacity"):
		var caps = models.get_model("capacity").get_capacities_keys()
		lines.push_back("capacities %s" % [String(caps.size())])
	if models.has_model("convention"):
		var convention = models.get_model("convention")
		lines.push_back("conventions planned %s" % [String(convention.list_planned_conventions().size())])
		lines.push_back("conventions running %s" % [String(convention.list_running_conventions().size())])
		lines.push_back("conventions archived %s" % [String(convention.list_archived_conventions().size())])
		if convention.has_method("is_autoattending_convention"):
			lines.push_back("auto-attend %s" % [String(bool(convention.call("is_autoattending_convention")))])
	if models.has_model("player"):
		var player = models.get_model("player").get_data()
		lines.push_back("company [%s] note %s" % [String(player.company_name), String(float(player.note))])
	# What a project kickoff actually needs. The play bot prints "no usable project values" and says
	# nothing about which of the four is missing, which made a fresh company look like a broken bot:
	# `get_default_engine()` returns a *dictionary* {id, type}, not an id, so a caller that assigns it to
	# `engine_id` compares a dictionary against null and gets null - and there is no default engine to
	# return anyway until one is chosen, so the first project on a brand-new company needs the owned list.
	if models.has_model("game-engine"):
		var engine = models.get_model("game-engine")
		var default = engine.call("get_default_engine") if engine.has_method("get_default_engine") else null
		lines.push_back("default engine %s (type %s)" % [
			String(dict_lib.text(default, "id", "null")),
			String(dict_lib.text(default, "type", "-"))
		])
		var owned_list = engine.call("get_owned_engine_list") if engine.has_method("get_owned_engine_list") else null
		lines.push_back("owned engine list %s" % [String(owned_list.size()) if owned_list != null else "null"])
	if models.has_model("game-theme"):
		var themes = models.get_model("game-theme").get_theme_names()
		lines.push_back("themes %s (%s)" % [
			String(themes.size()) if themes != null else "null",
			String(themes[0]) if themes != null and themes.size() > 0 else "-"
		])
	var platform_controller = controllers.get_controller("platform")
	if platform_controller != null and platform_controller.has_method("list_platform"):
		var platforms = platform_controller.call("list_platform", false, true)
		lines.push_back("publishable platforms %s" % [String(platforms.size()) if platforms != null else "null"])
	return company_join(lines)


# Everything sitting on top of the game, whatever its scene, from the root down: the Steam warning is a
# separate scene that never joins the popup group, so a group walk alone reports "none" while a dialog
# covers the screen.
# Why the clock is or is not moving, in one answer.
#
# Four independent things can stop it and they look identical from the outside: the state model not being
# in view mode, the scene not being the game's main scene, the date model's own pause flag, and its
# freeze flag. A playtest sat with the world stopped at one week for fifteen minutes and each of those
# was a plausible cause, so this reports all of them at once instead of one at a time.
static func __clock(coop):
	var lines = []
	if not models.has_model("date"):
		return "no date model"
	var date_model = models.get_model("date")
	var state = "?"
	if models.has_model("state"):
		var state_model = models.get_model("state")
		if state_model.has_method("is_view_mode"):
			state = String(bool(state_model.call("is_view_mode")))
		if state_model.has_method("get_data"):
			var data = state_model.call("get_data")
			lines.push_back("state current=[%s] view_mode=%s" % [
				String(dict_lib.text(data, "current_state", "?")), state
			])
	else:
		lines.push_back("no state model")
	# `scene_manager` is an autoload: in main.gd it resolves as a global identifier, but remote.gd is a
	# different script, so it is reached through the tree instead of assumed.
	var scene_manager = coop.get_tree().get_root().find_node("scene_manager", true, false)
	if scene_manager == null:
		scene_manager = coop.get_tree().get_root().get_node("scene_manager") \
			if coop.get_tree().get_root().has_node("scene_manager") else null
	if scene_manager != null and scene_manager.has_method("is_game_main_scene"):
		lines.push_back("game main scene=%s" % [String(bool(scene_manager.call("is_game_main_scene")))])
	else:
		lines.push_back("no game main scene accessor")
	lines.push_back("paused=%s is_paused=%s started=%s raw=%s tick=%s interval=%s speed=%s" % [
		String(bool(date_model.paused)),
		String(bool(date_model.call("is_paused"))),
		String(bool(date_model.call("is_started"))),
		String(date_model.get_raw_date()),
		"n/a",
		String(date_model.get_week_duration()),
		String(date_model.get_speed_index())
	])
	lines.push_back("frozen (is_paused and not paused)=%s" % [String(coop.__date_frozen(date_model))])
	return company_join(lines)


# The theme trends, as this machine holds them.
#
# Trends are the market's opinion of each genre, rolled once per theme at game start and again on every
# month boundary, and they are what the project screen prices a genre against. Two machines in one world
# must agree on them, so this prints a stable fingerprint rather than the whole table: the sum of every
# value plus the current month's slice. Identical fingerprints on two machines is the claim worth checking.
static func __trends(coop):
	if not models.has_model("game-theme"):
		return "no game-theme model"
	var theme_model = models.get_model("game-theme")
	# get_data(), not call("get_trends"): the `own` verb reads every other model through get_data() and
	# works, while this returned an empty answer with no error - `call()` on this build's model nodes is
	# the same family of hazard the mod already documents elsewhere.
	var data = theme_model.get_data()["trends"] if theme_model.has_method("get_data") else null
	if data == null:
		return "no trends"
	var month = int(models.get_model("date").get_date().month)
	var names = []
	var total = 0
	var this_month = 0
	for name in data:
		names.push_back(String(name))
		var series = data[name]
		if series == null:
			continue
		var index = 0
		while index < series.size():
			total += int(series[index])
			if index == month:
				this_month += int(series[index])
			index += 1
	names.sort()
	var lines = []
	lines.push_back("themes=%s month=%s sum_all=%s sum_this_month=%s" % [
		String(names.size()), String(month), String(total), String(this_month)
	])
	# A few concrete values, so two machines can be compared by eye as well as by checksum.
	var sample = []
	var taken = 0
	for name in names:
		if taken >= 5:
			break
		var series = data[name]
		if series == null or series.size() <= month:
			continue
		sample.push_back("%s=%s" % [String(name), String(int(series[month]))])
		taken += 1
	lines.push_back("sample %s" % [company_join(sample, " ")])
	return company_join(lines)


static func __dialogs(coop):
	var lines = []
	var root = coop.get_tree().get_root()
	for node in root.get_children():
		if node == null:
			continue
		var shown = true
		if node.has_method("is_visible"):
			shown = bool(node.is_visible())
		lines.push_back("root child %s visible=%s %s" % [
			String(node.get_name()), String(shown), String(node.get_filename())
		])
		for child in node.get_children():
			var child_shown = true
			if child.has_method("is_visible"):
				child_shown = bool(child.is_visible())
			lines.push_back("   %s visible=%s %s" % [
				String(child.get_name()), String(child_shown), String(child.get_filename())
			])
	if lines.size() == 0:
		lines.push_back("nothing above the game")
	return company_join(lines)


# Presses the top dialog's own close button, which is what a player clicks. Tries the dialog's close
# button, then its cancel button.
static func __close(coop):
	var root = coop.get_tree().get_root()
	var top = null
	for node in root.get_children():
		if node != null and node.has_method("is_visible") and bool(node.is_visible()):
			if String(node.get_name()) != "root":
				top = node
	if top == null:
		return "nothing to close"
	var close = top.find_node("close", true, false)
	if close != null and close.has_method("emit_signal"):
		close.emit_signal("pressed")
		return "pressed the close button on %s" % [String(top.get_name())]
	var cancel = top.find_node("cancel", true, false)
	if cancel != null and cancel.has_method("emit_signal"):
		cancel.emit_signal("pressed")
		return "pressed cancel on %s" % [String(top.get_name())]
	return "no close button on %s" % [String(top.get_name())]


# Searches what a player can see, the way a person would: the open popups first (topmost last), then the
# game menu, then the HUD itself. The last of those matters because parts of the game a player clicks are
# not popups - the in-development project list, with its Release button, is drawn in the HUD.
static func __find_node(coop, name):
	var popups = coop.get_tree().get_nodes_in_group("popup-node")
	for index in range(popups.size()):
		var popup = popups[popups.size() - 1 - index]
		var found = popup.find_node(name, true, false)
		if found != null:
			return found
	var menu = automation.find_by_scene(coop.get_tree().get_root(), GAME_MENU_SCENE)
	if menu != null:
		var in_menu = menu.find_node(name, true, false)
		if in_menu != null:
			return in_menu
	var game = automation.find_by_scene(coop.get_tree().get_root(), GAME_SCENE)
	if game != null:
		return game.find_node(name, true, false)
	return null


static func __answer(coop, seq, command, answer):
	# The answer goes into this instance's own log first, one line at a time. That is the reliable channel:
	# it is the same file the mod already writes every message to, and reading it shows the answer even
	# when the separate answer file cannot be opened.
	coop_log.info(coop.config.log_name, "remote: --- %s: %s" % [String(seq), command])
	for line in String(answer).split("\n"):
		coop_log.info(coop.config.log_name, "remote:     " + String(line))
	coop_log.info(coop.config.log_name, "remote: --- end of %s" % [String(seq)])

	var path = coop_log.directory() + "/" + answer_file(coop)
	var file = File.new()
	var mode = File.READ_WRITE if file.file_exists(path) else File.WRITE
	if file.open(path, mode) != OK:
		return
	file.seek_end()
	file.store_line("#%s %s" % [String(seq), command])
	for line in String(answer).split("\n"):
		file.store_line("   " + String(line))
	file.store_line("   --")
	file.close()


static func company_join(lines):
	var out = ""
	for line in lines:
		out += String(line) + "\n"
	return out
