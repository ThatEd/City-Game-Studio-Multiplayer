extends Reference

# Drives a real client through the retail UI, instead of calling the game's controllers.
#
# play.gd *is* scripting the client: it calls game_controller.create_game() and then pushes the game
# through its step machine itself. That proves the sync layer works, but it proves nothing about the
# buttons a player actually presses - and the two failures the owner hit ("host crashed upon designing a
# game", "client actually has 0 developers") both lived in code that only the UI ever runs.
#
# This file is the opposite. Every action finds a real node in the real scene tree and presses it:
#
#   game menu "project" button -> its submenu -> the project panel -> the theme picker -> a theme card
#   -> the panel's own Create button -> the design step -> its own Next button
#   game menu "competitor" button -> its submenu -> the rival list
#   the mod's own "Multiplayer" button -> the transfer panel -> its own Offer money button
#
# Every assertion afterwards reads what the UI produced - the panel in the tree, the button's own
# disabled flag, the card's own valid() answer, the rows the rival list drew, the catalogue the game
# itself filled in - not a value this file stored. If the retail UI stops working, this stops passing.
#
# Deliberately NOT OS-level mouse input (the owner asked for no real clicks; a synthetic click also
# depends on window focus, the stretch transform and where the OS thinks the cursor is, so a failure
# would be ambiguous). A press here goes through the same two paths a click does:
#   - the button has "pressed" connections  -> emit_signal("pressed"), which runs every handler
#   - otherwise the button acts in _pressed()  (scripts/game/menu/generic.gd does) -> call("_pressed")
# The game's own menu entries use the second path; their submenu is a real PopupMenu, so an entry with
# several unlocked kinds (self-publish, game-engine, trade-publish, ...) really does pop a menu, and the
# pilot presses its item exactly as a player would.
#
# The state lives on the autoload (__pilot_*), not here: script-level vars in a Reference do not survive
# across calls reliably in this engine build.
#
#     --coop-pilot=<seconds>    start driving the UI this long after boot (default 40)

const coop_log = preload("res://coop/log.gd")
const automation = preload("res://coop/automation.gd")
const company = preload("res://coop/company.gd")

const GAME_MENU_SCENE = "res://scenes/game/menu.tscn"
const PROJECT_SCENE = "res://scenes/game/project.tscn"
const KICKOFF_SCENE = "res://scenes/game/project/kickoff-self.tscn"
const THEME_SCENE = "res://scenes/game/project/game-theme.tscn"
const DESIGN_SCENE = "res://scenes/game/project/design.tscn"
const CONCURRENT_SCENE = "res://scenes/game/concurrent.tscn"
# The rival list panel and the scroll list of company rows inside it. A plain find_node("list") under the
# concurrent panel finds the *studio* list of whichever rival happens to be selected, which is empty when
# that rival has no studio - so the company list is located by its own scene.
const COMPANY_LIST_SCENE = "res://scenes/game/concurrent/concurrent-company-list.tscn"
const COMPANY_ROWS = "container/group/scroll/list"

# A step that has not happened after this long is reported as a failure and the run moves on, so a
# stuck step cannot swallow the rest of the evidence.
const STEP_TIMEOUT = 45.0
# How long to give the game to open a submenu's panel before the submenu itself is used instead.
const SUBMENU_GRACE = 1.5
const POLL_INTERVAL = 0.5

const STEP_NAMES = [
	"press the game menu's project button",
	"resolve the project submenu",
	"fill in the new-game form",
	"pick a theme from the theme picker",
	"press the panel's own Create button",
	"start the design step from its own Next button",
	"open the rival list from the game menu",
	"look at the host in the rival list",
	"offer money from the multiplayer panel",
	"report",
]

const SELF_PUBLISH = "self-publish"
const OVERALL = "overall"


static func tick(coop):
	if coop.config.pilot <= 0.0 or not models.is_loaded():
		return
	if not coop.__pilot_started:
		if coop.__elapsed < coop.config.pilot:
			return
		coop.__pilot_started = true
		coop.__pilot_at = coop.__elapsed
		coop.__pilot_next_at = coop.__elapsed
		coop_log.info(coop.config.log_name, "pilot: starting to drive the client's UI (%s steps)" % [
			String(STEP_NAMES.size())
		])
	if coop.__pilot_done or coop.__elapsed < coop.__pilot_next_at:
		return

	if coop.__elapsed - coop.__pilot_at > STEP_TIMEOUT:
		__fail(coop, "step %s (%s) timed out after %s s" % [
			String(coop.__pilot_step), __name(coop.__pilot_step), String(STEP_TIMEOUT)
		])
		__advance(coop)

	var step = coop.__pilot_step
	if step == 0:
		__step_project_button(coop)
	elif step == 1:
		__step_project_submenu(coop)
	elif step == 2:
		__step_form(coop)
	elif step == 3:
		__step_theme(coop)
	elif step == 4:
		__step_create(coop)
	elif step == 5:
		__step_design(coop)
	elif step == 6:
		__step_competitor_button(coop)
	elif step == 7:
		__step_rivals(coop)
	elif step == 8:
		__step_offer(coop)
	else:
		__finish(coop)


# --- the steps ----------------------------------------------------------

# The mod's Multiplayer button has to be in the game's own menu bar, and the project entry beside it is
# the one a player uses to start a game.
static func __step_project_button(coop):
	var menu = __scene(coop, GAME_MENU_SCENE)
	if menu == null:
		__wait(coop, POLL_INTERVAL)
		return
	var coop_button = menu.find_node("coop_button", true, false)
	__ok(coop, "the mod's Multiplayer button is in the game's menu bar", coop_button != null,
		"found" if coop_button != null else "no coop_button node")
	var project = menu.find_node("project", true, false)
	if project == null:
		__fail(coop, "the game menu has no project button")
		__advance(coop)
		return
	__press(coop, project, "the game menu's project button")
	coop.__pilot_press_at = coop.__elapsed
	__advance(coop)


# A project button with several unlocked kinds pops a real PopupMenu; with one it goes straight in. Both
# are what a player sees, so both are handled - the panel appearing on its own wins, otherwise the
# self-publish item is pressed.
static func __step_project_submenu(coop):
	if __scene(coop, PROJECT_SCENE) != null:
		__advance(coop)
		return
	var menu = __scene(coop, GAME_MENU_SCENE)
	if menu == null:
		__wait(coop, POLL_INTERVAL)
		return
	if coop.__pilot_sub == 0 and coop.__elapsed - coop.__pilot_press_at >= SUBMENU_GRACE:
		coop.__pilot_sub = 1
		var project = menu.find_node("project", true, false)
		var index = __popup_item(coop, project, SELF_PUBLISH)
		if index < 0:
			__fail(coop, "the project submenu has no enabled self-publish entry")
			__advance(coop)
			return
		__ok(coop, "the project button opened a submenu with Self publish in it", true,
			"item %s" % [String(index)])
		var popup = __popup_of(project)
		popup.emit_signal("item_pressed", index)
		coop_log.info(coop.config.log_name, "pilot: pressed the submenu's Self publish item")
		coop.__pilot_press_at = coop.__elapsed
	__wait(coop, POLL_INTERVAL)


static func __step_form(coop):
	var form = __form(coop)
	if form == null:
		__wait(coop, POLL_INTERVAL)
		return
	__ok(coop, "the project panel opened the self-publish form", true, "")

	var space = form.find_node("name", true, false)
	var field = null
	if space != null:
		field = space.find_node("value", true, false)
	if field == null or not field.has_method("set_text"):
		__fail(coop, "the form has no name box to type into")
		__advance(coop)
		return

	coop.__pilot_game_name = "Pilot %s" % [String(OS.get_ticks_msec() % 100000)]
	field.set_text(coop.__pilot_game_name)
	# The field's own handler is what a name a player types gets: the item debounces on text_changed and
	# then pushes the text into the form's data.
	field.emit_signal("text_changed", coop.__pilot_game_name)
	coop_log.info(coop.config.log_name, "pilot: typed the game name [%s]" % [coop.__pilot_game_name])

	var theme_row = form.find_node("theme", true, false)
	var theme_select = null
	if theme_row != null:
		theme_select = theme_row.find_node("select", true, false)
	if theme_select == null:
		__fail(coop, "the form has no theme button")
		__advance(coop)
		return
	__press(coop, theme_select, "the form's theme button")
	__advance(coop)


# The theme picker is a popup full of cards. Pressing a card's own button is what a player does.
static func __step_theme(coop):
	var picker = __scene(coop, THEME_SCENE)
	if picker == null:
		__wait(coop, POLL_INTERVAL)
		return
	var grid = picker.find_node("grid", true, false)
	if grid == null or grid.get_child_count() < 1:
		__wait(coop, POLL_INTERVAL)
		return
	var card = grid.get_child(0)
	var button = null
	if card != null:
		button = card.find_node("button", true, false)
	if button == null:
		__fail(coop, "the theme picker has a card with no button")
		__advance(coop)
		return
	__ok(coop, "the theme picker drew its cards", true, String(grid.get_child_count()) + " theme(s)")
	__press(coop, button, "the first theme card")
	__advance(coop)


static func __step_create(coop):
	var form = __form(coop)
	if form == null:
		__wait(coop, POLL_INTERVAL)
		return
	var theme_row = form.find_node("theme", true, false)
	var theme_valid = false
	if theme_row != null and theme_row.has_method("valid"):
		theme_valid = bool(theme_row.call("valid"))
	__ok(coop, "pressing a card gave the form a theme", theme_valid, "")

	# The game disables Create until every part of the form says it is usable, so this flag is the
	# game's own opinion that a player could go ahead.
	var create = form.find_node("create", true, false)
	if create == null:
		__fail(coop, "the form has no Create button")
		__advance(coop)
		return
	var disabled = bool(create.call("is_disabled"))
	__ok(coop, "the game enabled its own Create button", not disabled,
		"disabled, so the form is not complete" if disabled else "enabled")
	if disabled:
		__report_form_gaps(coop, form)
		__advance(coop)
		return
	__press(coop, create, "the form's Create button")
	__advance(coop)


# Why a form refuses to let a player go ahead is itself useful evidence, and this is the game's own
# answer from each part of the form.
static func __report_form_gaps(coop, form):
	var parts = ["theme", "size", "studio", "platform", "name", "online", "genre"]
	for part in parts:
		var node = form.find_node(part, true, false)
		if node == null or not node.has_method("valid"):
			continue
		coop_log.info(coop.config.log_name, "pilot: form part %s valid=%s" % [
			part, String(bool(node.call("valid")))
		])


static func __step_design(coop):
	var design = __scene(coop, DESIGN_SCENE)
	if design == null:
		__wait(coop, POLL_INTERVAL)
		return
	__ok(coop, "creating a game from the UI opened the design step", true, "")
	var game = __pilot_game(coop)
	if game == null:
		__fail(coop, "the game the UI created is not in the catalogue")
		__advance(coop)
		return
	__ok(coop, "the catalogue holds the game the UI created", true,
		String(game["name"]) + " step=" + String(game["step"]))

	var next = design.find_node("next", true, false)
	if next == null:
		__fail(coop, "the design step has no Next button")
		__advance(coop)
		return
	__press(coop, next, "the design step's Next button")
	__advance(coop)


static func __step_competitor_button(coop):
	var menu = __scene(coop, GAME_MENU_SCENE)
	if menu == null:
		__wait(coop, POLL_INTERVAL)
		return
	var competitor = menu.find_node("competitor", true, false)
	if competitor == null:
		__fail(coop, "the game menu has no competitor button")
		__advance(coop)
		return
	__press(coop, competitor, "the game menu's competitor button")
	coop.__pilot_press_at = coop.__elapsed
	coop.__pilot_sub = 0
	__advance(coop)


# The rival list is the client's view of the other player. Each row is a scene whose company name the
# game itself filled in, so a name here is the game saying "this company exists in my world".
static func __step_rivals(coop):
	var list = __scene(coop, CONCURRENT_SCENE)
	if list == null:
		# Same two-phase rule as the project button: the panel may need a submenu first.
		if coop.__pilot_sub == 0 and coop.__elapsed - coop.__pilot_press_at >= SUBMENU_GRACE:
			coop.__pilot_sub = 1
			var menu = __scene(coop, GAME_MENU_SCENE)
			var competitor = menu.find_node("competitor", true, false) if menu != null else null
			var index = __popup_item(coop, competitor, OVERALL)
			if index < 0:
				__fail(coop, "the competitor submenu has no enabled company-list entry")
				__advance(coop)
				return
			var popup = __popup_of(competitor)
			popup.emit_signal("item_pressed", index)
			coop_log.info(coop.config.log_name, "pilot: pressed the submenu's company list item")
			coop.__pilot_press_at = coop.__elapsed
		__wait(coop, POLL_INTERVAL)
		return

	var rows = __company_rows(list)
	if rows == null or rows.get_child_count() < 1:
		# The rows are instanced per company after the panel's own _ready, so an empty list right after it
		# opens is a "not yet", not a failure. The step timeout still bounds the wait.
		__wait(coop, POLL_INTERVAL)
		return
	var names = []
	for row in rows.get_children():
		if row != null and row.has_method("get_company_name"):
			names.push_back(String(row.call("get_company_name")))
	__ok(coop, "the rival list drew a row per company", names.size() > 0,
		String(names.size()) + " row(s): " + company.join(names, ", "))

	var wanted = []
	for other in coop.ui_other_players():
		wanted.push_back(coop.ui_player_name(other))
	__ok(coop, "the rival list has the other player to look at", wanted.size() > 0,
		String(wanted.size()) + " player(s)")
	for name in wanted:
		__ok(coop, "the rival list shows %s by name" % [name], names.has(String(name)),
			"not among " + company.join(names, ", "))

	var close = list.find_node("close", true, false)
	if close != null:
		__press(coop, close, "the rival list's close button")
	__advance(coop)


static func __step_offer(coop):
	var menu = __scene(coop, GAME_MENU_SCENE)
	if menu == null:
		__wait(coop, POLL_INTERVAL)
		return
	var button = menu.find_node("coop_button", true, false)
	if button == null:
		__fail(coop, "no Multiplayer button to press")
		__advance(coop)
		return
	if not coop.__pilot_panel_pressed:
		coop.__pilot_panel_pressed = true
		__press(coop, button, "the Multiplayer button")
		__wait(coop, POLL_INTERVAL)
		return

	if coop.__game_panel == null:
		__wait(coop, POLL_INTERVAL)
		return
	__ok(coop, "pressing the Multiplayer button opened the panel", coop.__game_panel.is_visible(),
		"visible" if coop.__game_panel.is_visible() else "still hidden")

	var players = coop.__game_panel.find_node("players", true, false)
	var listed = 0
	if players != null:
		listed = int(players.call("get_item_count"))
	__ok(coop, "the panel offers the other player to give to", listed > 0,
		String(listed) + " player(s)")

	var amount = coop.__game_panel.find_node("amount", true, false)
	if amount != null and amount.has_method("set_text"):
		amount.set_text("25k")
		coop_log.info(coop.config.log_name, "pilot: typed 25k into the money box")

	var before = coop.__ui_offer_count()
	var offer_button = coop.__game_panel.find_node("offer_money", true, false)
	if offer_button == null:
		__fail(coop, "the panel has no Offer money button")
		__advance(coop)
		return
	__press(coop, offer_button, "the panel's Offer money button")
	var after = coop.__ui_offer_count()
	__ok(coop, "pressing Offer money made a real offer", after > before,
		"%s -> %s offer(s)" % [String(before), String(after)])

	var close = coop.__game_panel.find_node("close", true, false)
	if close != null:
		__press(coop, close, "the panel's Close button")
		__ok(coop, "Close put the panel away", not coop.__game_panel.is_visible(), "")
	__advance(coop)


static func __finish(coop):
	coop.__pilot_done = true
	coop_log.info(coop.config.log_name, "pilot: finished, %s check(s), %s failed" % [
		String(coop.__pilot_checks), String(coop.__pilot_failures)
	])
	# What a player would look at afterwards: the game the UI started, still in the catalogue.
	var game = __pilot_game(coop)
	coop_log.info(coop.config.log_name, "pilot: the game created from the UI is %s" % [
		("still there, step " + String(game["step"])) if game != null else "gone from the catalogue"
	])
	if coop.__pilot_failures == 0:
		coop_log.info(coop.config.log_name, "pilot: ALL OK")
	else:
		coop_log.warning(coop.config.log_name, "pilot: PROBLEMS FOUND")


# --- pressing a button the way a click does ------------------------------

static func __press(coop, node, what):
	if node == null:
		__fail(coop, "nothing to press for " + String(what))
		return
	if node.has_method("is_disabled") and bool(node.call("is_disabled")):
		coop_log.info(coop.config.log_name, "pilot: %s is disabled, not pressing it" % [what])
		return

	var connections = []
	if node.has_method("get_signal_connection_list"):
		connections = node.call("get_signal_connection_list", "pressed")

	if connections.size() > 0:
		node.emit_signal("pressed")
		coop_log.info(coop.config.log_name, "pilot: pressed %s (pressed signal, %s handler(s))" % [
			what, String(connections.size())
		])
		return

	# The game's own menu entries do their work in _pressed() rather than in a connection.
	if node.has_method("_pressed"):
		node.call("_pressed")
		coop_log.info(coop.config.log_name, "pilot: pressed %s (_pressed)" % [what])
		return

	__fail(coop, "%s has no way to be pressed (no handler, no _pressed)" % [what])


# The PopupMenu a generic menu entry builds for itself. It is added as a child of that button in
# scripts/game/menu/generic.gd _create_popup_menu.
static func __popup_of(button):
	if button == null:
		return null
	for child in button.get_children():
		if child != null and child.has_method("get_item_metadata"):
			return child
	return null


# Index of an enabled item, by the button name the entry stores in the item's metadata, or -1.
static func __popup_item(coop, button, wanted):
	var popup = __popup_of(button)
	if popup == null:
		return -1
	var count = int(popup.call("get_item_count"))
	for index in range(count):
		var meta = popup.call("get_item_metadata", index)
		if meta == null or typeof(meta) != TYPE_DICTIONARY or not meta.has("button_name"):
			continue
		if String(meta["button_name"]) != wanted:
			continue
		var disabled = false
		if popup.has_method("is_item_disabled"):
			disabled = bool(popup.call("is_item_disabled", index))
		if disabled:
			coop_log.info(coop.config.log_name, "pilot: submenu item %s is disabled" % [wanted])
			return -1
		return index
	return -1


# --- helpers ------------------------------------------------------------

static func __scene(coop, path):
	return automation.find_by_scene(coop.get_tree().get_root(), path)


static func __form(coop):
	var panel = __scene(coop, PROJECT_SCENE)
	if panel == null:
		return null
	return automation.find_by_scene(panel, KICKOFF_SCENE)


# The VBoxContainer holding one row per company in the rival list.
static func __company_rows(concurrent_panel):
	var company_list = automation.find_by_scene(concurrent_panel, COMPANY_LIST_SCENE)
	if company_list == null:
		return null
	return company_list.find_node(COMPANY_ROWS, true, false)


# The game the UI created, found by the name this pilot typed, so a catalogue entry left over from
# another run cannot satisfy the check.
static func __pilot_game(coop):
	if not models.has_model("game") or coop.__pilot_game_name == "":
		return null
	var catalog = models.get_model("game").get_data()["catalog"]
	for bucket in ["dev", "hold", "published", "released", "canceled"]:
		if not catalog.has(bucket) or catalog[bucket] == null:
			continue
		for game_id in catalog[bucket]:
			var game = catalog[bucket][game_id]
			if game != null and game.has("name") and String(game["name"]) == coop.__pilot_game_name:
				return game
	return null


static func __name(step):
	if step < 0 or step >= STEP_NAMES.size():
		return "?"
	return String(STEP_NAMES[step])


static func __wait(coop, seconds):
	coop.__pilot_next_at = coop.__elapsed + seconds


static func __advance(coop):
	coop.__pilot_step += 1
	coop.__pilot_sub = 0
	coop.__pilot_at = coop.__elapsed
	coop.__pilot_next_at = coop.__elapsed + POLL_INTERVAL
	coop_log.info(coop.config.log_name, "pilot: next, step %s (%s)" % [
		String(coop.__pilot_step), __name(coop.__pilot_step)
	])


static func __ok(coop, what, ok, detail):
	coop.__pilot_checks += 1
	if not ok:
		coop.__pilot_failures += 1
	coop_log.info(coop.config.log_name, "pilot %s %s%s" % [
		"PASS" if ok else "FAIL", what,
		(" (" + String(detail) + ")") if String(detail) != "" else ""
	])
	return 0 if ok else 1


static func __fail(coop, what):
	__ok(coop, what, false, "")
