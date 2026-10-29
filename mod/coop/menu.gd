extends Reference

# The main menu's multiplayer entry.
#
# One entry, "Multiplayer", sitting to the left of the game's own "Continue". It is a *copy* of that
# entry's node tree - same MarginContainer, same button, same icon frame and label - so it is styled by
# the game itself instead of by hand, and a theme change in an update carries over. Only the icon and
# the label differ: the icon is a two-people drawing built by build/build_mod.py (see ICON_PATH).
#
# Pressing it reveals the two things a player can do - host a game, or join one - and hides them again
# when pressed a second time. Nothing is drawn until then.
#
# Host: the player loads or starts a game as usual; hosting begins as soon as that game exists, because
# the host's save is the world.
# Join: the address box takes host:port of the relay server (default 127.0.0.1:7470).

const coop_log = preload("res://coop/log.gd")

const BUTTON_NODE = "coop_multiplayer"
const OPTIONS_NODE = "coop_multiplayer_options"
const LABEL_TEXT = "Multiplayer"
# Generated at build time from mod/coop/icon/multiplayer.svg (two people, white, 128x128).
const ICON_PATH = "res://coop/icon/multiplayer.tex"


static func patch(menu, coop, log_name, warn = true):
	# The entry it is copied from and placed beside. "continue" is the first item of the game's menu;
	# "newgame" is the fallback for a build where Continue is missing.
	var anchor = menu.find_node("continue", true, false)
	if anchor == null:
		anchor = menu.find_node("newgame", true, false)
	if anchor == null:
		if warn:
			coop_log.error(log_name, "menu: no menu entry to put the multiplayer button beside")
		return false

	var parent = anchor.get_parent()
	if parent == null:
		return false
	if parent.has_node(BUTTON_NODE):
		return true

	var item = __clone_entry(anchor, coop, log_name)
	parent.add_child(item)
	parent.move_child(item, anchor.get_position_in_parent())

	var options = __build_options(coop)
	options.set_name(OPTIONS_NODE)
	options.hide()
	# Added to the scene root, not to the menu's own list: that list is a container and would lay the
	# panel out as another entry, on top of the ones it is supposed to sit beside.
	menu.add_child(options)

	coop_log.info(log_name, "menu: multiplayer entry added to the left of the game's own entries")
	return true


static func __clone_entry(anchor, coop, log_name):
	var item = anchor.duplicate()
	item.set_name(BUTTON_NODE)

	var button = item.find_node("button", true, false)
	if button != null:
		# The copy must not also run the game's own handler for the entry it was cloned from.
		for connection in button.get_signal_connection_list("pressed"):
			button.disconnect("pressed", connection["target"], connection["method"])
		button.connect("pressed", coop, "menu_multiplayer_pressed")
		button.set_tooltip("Host this save for another player, or join someone else's world.")

	var label = item.find_node("value", true, false)
	if label != null and label.has_method("set_text"):
		label.set_text(LABEL_TEXT)

	var icon = item.find_node("icon", true, false)
	if icon != null and icon.has_method("set_texture"):
		var texture = load(ICON_PATH)
		if texture != null:
			icon.set_texture(texture)
		else:
			coop_log.warning(log_name, "menu: %s is missing from this build" % [ICON_PATH])

	return item


static func __build_options(coop):
	var panel = PanelContainer.new()
	var box = VBoxContainer.new()
	box.set_name("box")
	panel.add_child(box)

	var host_button = Button.new()
	host_button.set_name("host")
	host_button.set_text("Host a game")
	host_button.set_tooltip("Others can join as soon as a game is loaded.")
	host_button.connect("pressed", coop, "menu_host_pressed")
	box.add_child(host_button)

	var join_button = Button.new()
	join_button.set_name("join")
	join_button.set_text("Join a game")
	join_button.set_tooltip("Join the world in the address below.")
	join_button.connect("pressed", coop, "menu_join_pressed")
	box.add_child(join_button)

	var address = LineEdit.new()
	address.set_name("address")
	address.set_text("127.0.0.1:7470")
	address.set_tooltip("host:port of the relay server")
	box.add_child(address)

	return panel


static func set_options_visible(menu, visible):
	var options = menu.find_node(OPTIONS_NODE, true, false)
	if options == null:
		return false
	if not visible:
		options.hide()
		return true

	# Placed under the entry that opened it, in screen coordinates, so it lands beside the menu
	# entries whatever the resolution.
	var item = menu.find_node(BUTTON_NODE, true, false)
	if item != null and item.has_method("get_global_rect"):
		var rect = item.get_global_rect()
		options.set_global_pos(Vector2(rect.pos.x, rect.pos.y + rect.size.y + 4.0))
	options.set_size(Vector2(260, 176))
	options.show()
	# Size again after showing: a hidden container is not laid out, so setting it while hidden leaves
	# its children stacked at the same position.
	options.set_size(Vector2(260, 176))
	return true


static func options_visible(menu):
	var options = menu.find_node(OPTIONS_NODE, true, false)
	if options == null:
		return false
	return options.is_visible()


static func address_text(menu):
	var options = menu.find_node(OPTIONS_NODE, true, false)
	if options == null:
		return ""
	var address = options.find_node("address", true, false)
	if address == null or not address.has_method("get_text"):
		return ""
	return String(address.get_text())


# The node a click actually lands on: the cloned entry is a MarginContainer with a Button inside it.
static func press_target(menu):
	var item = menu.find_node(BUTTON_NODE, true, false)
	if item == null:
		return null
	return item.find_node("button", true, false)


static func entry(menu):
	return menu.find_node(BUTTON_NODE, true, false)
