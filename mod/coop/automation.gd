extends Reference

# Drives the game's own UI from inside the mod, so tests never need a human at the keyboard
# (playbook/automated-qa.md: "test with bots, not with your owner").
#
# Everything here goes through the same entry points a click would: it emits the menu button's
# `pressed` signal and calls the new-game popup's `start_pressed()`. Nothing is faked, so a
# successful run means the retail UI really produced a real game.

const MENU_SCENE = "res://scenes/main.tscn"
const NEW_GAME_SCENE = "res://scenes/new-game/main.tscn"


# Depth-first search for a node instanced from `scene_path`.
static func find_by_scene(node, scene_path):
	if node == null:
		return null

	if node.get_filename() == scene_path:
		return node

	for child in node.get_children():
		var found = find_by_scene(child, scene_path)
		if found != null:
			return found

	return null


# The menu's "new game" entry. The path is the one scripts/menu/main.gd uses itself.
static func press_new_game(menu):
	var newgame = menu.find_node("newgame", true, false)
	if newgame == null:
		return false

	var button = null
	if newgame.has_node("button"):
		button = newgame.get_node("button")
	if button == null:
		return false

	button.emit_signal("pressed")
	return true
