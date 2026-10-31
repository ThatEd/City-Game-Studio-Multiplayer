extends Reference

# The lobby: the screen a player sees after choosing "Join a game", before they are in a world.
#
# Why it exists
# -------------
# The two buttons alone left a hole. "Host a game" and "Join a game" said how to connect and said
# nothing about *who you would be* once connected, so a joining player was silently given a brand-new
# company - and the takeover path, which already worked, was reachable only from a command-line flag
# (`--coop-company=<id>`). A player could not choose.
#
# The lobby answers one question: which company do you want to run in this world?
#
#   * Start a new company  - what a first-time joiner does; an office is opened on the host's map.
#   * Take over a company  - pick one from this world's list. It keeps its name, money, fanbase,
#                            offices and the furniture in them, and the AI that owned it is removed
#                            through the game's own acquisition path.
#
# Timing, which is the whole difficulty
# -------------------------------------
# The list of companies to take over does not exist until the host's world has arrived, because it is
# *in* the world: rivals live in the concurrent model and co-op players in the coop-state section. So
# the lobby has three states and shows which one it is in:
#
#   waiting    the world is still being transferred ("Connecting to <address>...")
#   choosing   the world is here; pick a new company or one of the listed ones
#   starting   a choice was made and the join is finishing
#
# It is deliberately not a separate scene. A scene would mean the game tears down the menu, and the
# world arrives into a different scene tree than the one that asked for it. This is a panel on the
# main menu, so everything stays where the mod already expects it.

const coop_log = preload("res://coop/log.gd")

const PANEL_NODE = "coop_lobby"
const LIST_NODE = "list"
const STATUS_NODE = "status"
const NEW_BUTTON_NODE = "lobby_new"
const CREATE_PAGE_NODE = "create_page"
# The game's own company form: name, random name, logo, logo drawer, specialisation. Reused rather than
# reimplemented so a player gets the same fields, the same validation and the same look as New Game.
const COMPANY_FORM_SCENE = "res://scenes/new-game/company-item.tscn"
const WIDTH = 620
const HEIGHT = 460

# How many companies the list will show. A world can hold 21 rivals and the panel has to stay usable;
# the ones with studios come first, because those are the ones worth taking over.
const MAX_ROWS = 8


# One row per selectable company, best first.
#
# `entries` is a list of dictionaries: {id, name, offices, currency, fanbase, players, away, kind}.
# "kind" is "rival" for an AI company and "player" for another co-op player's company. A player's
# company is offered too: it is a real company in this world with real offices, and taking it over is
# exactly the same operation as taking over an AI one.
static func candidates(entries):
	var sorted = []
	for entry in entries:
		if entry == null:
			continue
		sorted.push_back(entry)

	# Best first: a company with offices beats one without, and a player's company beats an AI's -
	# a person who left is more likely to be wanted than a nameless Simulation Inc.
	#
	# Insertion sort rather than Array.sort_custom: this build has no documented sort_custom, and a
	# missing Variant member is a native crash here, not an error. Eight rows at most, so the cost is
	# irrelevant.
	var ordered = []
	for entry in sorted:
		var placed = false
		var at = 0
		while at < ordered.size():
			if __score(entry) > __score(ordered[at]):
				ordered.insert(at, entry)
				placed = true
				break
			at += 1
		if not placed:
			ordered.push_back(entry)

	var out = []
	for entry in ordered:
		if out.size() >= MAX_ROWS:
			break
		out.push_back(entry)
	return out


# How desirable a company is to take over.
static func __score(entry):
	var score = 0
	if int(value_of(entry, "offices", 0)) > 0:
		score += 100
	if String(value_of(entry, "kind", "")) == "player":
		score += 50
		if not bool(value_of(entry, "away", false)):
			score += 25
	return score


# Dictionary.get() is absent from this engine build and calling it is a native crash, not an error.
# Everything here reads through this instead.
static func value_of(entry, key, fallback):
	if entry == null or typeof(entry) != TYPE_DICTIONARY or not entry.has(key):
		return fallback
	var value = entry[key]
	if value == null:
		return fallback
	return value


# --- building ------------------------------------------------------------


static func build(coop):
	var panel = PanelContainer.new()
	panel.set_name(PANEL_NODE)

	var margin = MarginContainer.new()
	panel.add_child(margin)

	var column = VBoxContainer.new()
	column.set_name("column")
	margin.add_child(column)

	var title = Label.new()
	title.set_name("title")
	title.set_text("Join a game")
	column.add_child(title)

	var status = Label.new()
	status.set_name(STATUS_NODE)
	status.set_text("Connecting...")
	column.add_child(status)

	# Page 1: who are you?
	var choices = VBoxContainer.new()
	choices.set_name("choices")
	column.add_child(choices)

	var new_button = Button.new()
	new_button.set_name(NEW_BUTTON_NODE)
	new_button.set_text("Start a new company")
	new_button.set_tooltip("Opens the game's own company setup: name, logo and specialisation.")
	new_button.connect("pressed", coop, "lobby_new_pressed")
	choices.add_child(new_button)

	var heading = Label.new()
	heading.set_name("takeover_heading")
	heading.set_text("Or take over an existing company")
	choices.add_child(heading)

	var list = VBoxContainer.new()
	list.set_name(LIST_NODE)
	choices.add_child(list)
	# A Control added to the tree at runtime is not addressable by the name given to it in this engine
	# build - the whole lobby reports as `@@38` - so every lookup in this file walks the tree instead.
	# See __child().

	# Page 2: the game's own company form, hidden until asked for.
	var create = VBoxContainer.new()
	create.set_name(CREATE_PAGE_NODE)
	create.hide()
	column.add_child(create)

	var form = null
	var scene = load(COMPANY_FORM_SCENE)
	if scene != null:
		form = scene.instance()
		form.set_name("company_form")
		create.add_child(form)
	else:
		var missing = Label.new()
		missing.set_text("The company setup screen is missing from this build.")
		create.add_child(missing)

	var create_row = HBoxContainer.new()
	create_row.set_name("create_actions")
	create.add_child(create_row)

	var create_ok = Button.new()
	create_ok.set_name("create_ok")
	create_ok.set_text("Create and join")
	create_ok.connect("pressed", coop, "lobby_create_confirmed")
	create_row.add_child(create_ok)

	var create_back = Button.new()
	create_back.set_name("create_back")
	create_back.set_text("Back")
	create_back.connect("pressed", coop, "lobby_create_back")
	create_row.add_child(create_back)

	var leave = Button.new()
	leave.set_name("cancel")
	leave.set_text("Back")
	leave.connect("pressed", coop, "lobby_cancel_pressed")
	column.add_child(leave)

	panel.hide()
	return panel


# Shows the game's company form over the choice list.
static func show_create(panel):
	if panel == null:
		return
	var choices = __child(panel, "choices")
	if choices != null:
		choices.hide()
	var create = __child(panel, CREATE_PAGE_NODE)
	if create != null:
		create.show()
	__status(panel, "Set up your company, then create it and join.")
	__layout(panel)
	__raise(panel)
	panel.show()


static func show_choose_page(panel):
	if panel == null:
		return
	var create = __child(panel, CREATE_PAGE_NODE)
	if create != null:
		create.hide()
	var choices = __child(panel, "choices")
	if choices != null:
		choices.show()


# What the company form currently holds, read from the game's own node rather than tracked separately.
static func company_form_data(panel):
	if panel == null:
		return {}
	var form = __child(panel, "company_form")
	if form == null:
		return {}
	if form.has_method("is_valid") and not bool(form.call("is_valid")):
		return {}
	if form.has_method("get_data"):
		var data = form.call("get_data")
		if data != null and typeof(data) == TYPE_DICTIONARY:
			return data
	return {}


static func company_name_text(panel):
	if panel == null:
		return ""
	var form = __child(panel, "company_form")
	if form == null:
		return ""
	var name_node = __find_line_edit(form)
	if name_node != null and name_node.has_method("get_text"):
		return String(name_node.get_text())
	return ""


# The first LineEdit under a node. Nodes created at runtime are not addressable by name here, so the
# form's own text field is found by what it can do.
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


# Shows the lobby in its waiting state, before any world has arrived.
static func show_waiting(panel, address):
	if panel == null:
		return
	__status(panel, "Connecting to %s. Your company list appears when the host's world arrives." % [
		String(address)
	])
	__set_new_enabled(panel, false)
	__fill(panel, [])
	__layout(panel)
	__raise(panel)
	panel.show()


# Positions and sizes the panel for the screen it is on.
#
# It is parented to the scene root rather than to the main menu, so nothing lays it out: an anchorless
# Control added to the root keeps a zero-sized rect and draws nothing, however visible it claims to be.
# set_pos/set_size is the same pair ui.gd uses, which is proven in this build; the Godot 3 margin and
# anchor-preset calls are not.
static func __layout(panel, screen = null):
	var area = screen
	if area == null or area.size.x <= 0.0:
		area = Rect2(Vector2(0, 0), OS.get_window_size())
	var size = Vector2(WIDTH, HEIGHT)
	panel.set_size(size)
	panel.set_pos(Vector2((area.size.x - size.x) * 0.5, (area.size.y - size.y) * 0.35))


# Brings the panel to the front of its parent.
#
# It is a root-level Control added by the mod, so it sits wherever it was appended - and the game's own
# scene is added to the root after the autoloads, which put the whole game *over* the lobby: visible,
# correctly sized, and completely hidden. Raising it on every show is what actually makes it appear.
static func __raise(panel):
	var parent = panel.get_parent()
	if parent != null:
		parent.move_child(panel, parent.get_child_count() - 1)


# Shows the lobby with the companies that can be taken over.
static func show_choices(panel, coop, entries):
	if panel == null:
		return
	var rows = candidates(entries)
	if rows.size() == 0:
		__status(panel, "The host's world has no company to take over. Start a new one.")
	else:
		__status(panel, "The host's world is here. Choose the company you want to run.")
	__set_new_enabled(panel, true)
	__fill(panel, rows, coop)
	__layout(panel)
	__raise(panel)
	panel.show()


# A plain status line, for the states where there is nothing to choose yet.
static func show_message(panel, text):
	if panel == null:
		return
	__status(panel, text)
	__fill(panel, [])
	__set_new_enabled(panel, false)
	__layout(panel)
	__raise(panel)
	panel.show()


static func show_starting(panel, label):
	if panel == null:
		return
	__status(panel, "Starting %s..." % [String(label)])
	__fill(panel, [])
	__set_new_enabled(panel, false)


static func hide(panel):
	if panel != null:
		panel.hide()


static func is_visible(panel):
	return panel != null and panel.is_visible()


# --- reading ------------------------------------------------------------


static func status_text(panel):
	if panel == null:
		return ""
	var node = __child(panel, STATUS_NODE)
	if node == null or not node.has_method("get_text"):
		return ""
	return String(node.get_text())


# Every company row currently on screen, as the test harness and the checks read it.
static func row_labels(panel):
	var out = []
	if panel == null:
		return out
	var list = __child(panel, LIST_NODE)
	if list == null:
		return out
	for child in list.get_children():
		if __is_button(child):
			out.push_back(String(child.get_text()))
	return out


# `is` is not an operator in this engine build's GDScript - it is a parse error, which takes out the
# whole file. A Button is recognised by what it can do instead.
static func __is_button(node):
	return node != null and node.has_method("get_text") and node.has_method("is_pressed")


static func row_ids(panel):
	var out = []
	if panel == null:
		return out
	var list = __child(panel, LIST_NODE)
	if list == null:
		return out
	for child in list.get_children():
		if child != null and child.has_meta("company_id"):
			out.push_back(String(child.get_meta("company_id")))
	return out


# --- internals ----------------------------------------------------------


# Finds a node by the name it was given, walking the tree.
#
# find_node(name) is unreliable here: nodes created at runtime are not registered under the names set on
# them in this engine build - a whole lobby subtree reports as `@@38` - so every lookup in this file goes
# through this instead.
static func __child(root, name):
	if root == null:
		return null
	if root.get_name() == String(name):
		return root
	for child in root.get_children():
		var found = __child(child, name)
		if found != null:
			return found
	return null


static func __status(panel, text):
	var node = __child(panel, STATUS_NODE)
	if node != null and node.has_method("set_text"):
		node.set_text(text)


static func __set_new_enabled(panel, enabled):
	var button = __child(panel, NEW_BUTTON_NODE)
	if button != null and button.has_method("set_disabled"):
		button.set_disabled(not enabled)


static func __fill(panel, rows, coop = null):
	var list = __child(panel, LIST_NODE)
	if list == null:
		return
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()
	for row in rows:
		var button = Button.new()
		var id = String(value_of(row, "id", ""))
		# Named, because an unnamed button cannot be pressed by any automated run: the remote channel
		# addresses nodes by name, so these twelve takeover rows were unreachable and `lobby_takeover_pressed`
		# had never once been exercised. `take_<n>` matches the trade panel's own convention.
		button.set_name("take_%s" % [String(list.get_child_count() + 1)])
		button.set_text(__row_text(row))
		button.set_meta("company_id", id)
		if coop != null:
			# The id rides on the signal as a bound argument. Reading "which button was pressed" back
			# out of the list afterwards does not work: a Button's pressed state is momentary, so by
			# the time the handler runs it is already false.
			button.connect("pressed", coop, "lobby_takeover_pressed", [id])
		list.add_child(button)


static func __row_text(row):
	var parts = []
	parts.push_back(String(value_of(row, "name", value_of(row, "id", "?"))))
	if String(value_of(row, "kind", "")) == "player":
		parts.push_back("player")
	parts.push_back("%s office(s)" % [String(int(value_of(row, "offices", 0)))])
	parts.push_back("$%s" % [__thousands(int(value_of(row, "currency", 0)))])
	if bool(value_of(row, "away", false)):
		parts.push_back("away")
	return __join(parts, "  -  ")


static func __join(parts, separator):
	var text = ""
	var index = 0
	while index < parts.size():
		if index > 0:
			text += separator
		text += String(parts[index])
		index += 1
	return text


static func __thousands(value):
	var text = String(value)
	var out = ""
	var count = 0
	var index = text.length() - 1
	while index >= 0:
		if count > 0 and count % 3 == 0:
			out = "," + out
		out = text.substr(index, 1) + out
		count += 1
		index -= 1
	return out
