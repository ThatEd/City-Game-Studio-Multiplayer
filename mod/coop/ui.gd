extends Reference

# The in-game half of the multiplayer UI: one "Multiplayer" button in the game's own menu bar, and a
# panel behind it holding the transfers between players - money, technology and the IP of a published
# game - plus the offers waiting for this player.
#
# Built at runtime, like the main-menu button, and added inside the game's own GUI so the game's theme
# applies. Nothing here is drawn until the button is pressed, so a single-player session never sees it.

const coop_log = preload("res://coop/log.gd")
const dict_lib = preload("res://coop/dict.gd")
const trade = preload("res://coop/trade.gd")

const BUTTON_NODE = "coop_button"
const PANEL_NODE = "coop_panel"
const BUTTON_TEXT = "Multiplayer"

const MAX_OFFER_ROWS = 6
const WINDOW_WIDTH = 700
const WINDOW_HEIGHT = 520


# `bar` is the HBoxContainer holding the game's own menu buttons; the new button goes at its end,
# beside "options". Returns false when there is no bar to add to.
static func patch_game(gui, bar, coop, log_name, warn = true):
	if gui == null or bar == null:
		if warn:
			coop_log.error(log_name, "ui: no game menu bar to put the multiplayer button in")
		return false
	if bar.has_node(BUTTON_NODE) and gui.has_node(PANEL_NODE):
		return true

	if not bar.has_node(BUTTON_NODE):
		var button = Button.new()
		button.set_name(BUTTON_NODE)
		button.set_text(BUTTON_TEXT)
		button.set_tooltip("Multiplayer: give money, technology or a game's IP to the other player.")
		button.set_custom_minimum_size(Vector2(130, 56))
		button.connect("pressed", coop, "ui_toggle_panel")
		bar.add_child(button)

	if not gui.has_node(PANEL_NODE):
		var panel = __build_panel(coop)
		panel.set_name(PANEL_NODE)
		panel.hide()
		gui.add_child(panel)

	coop_log.info(log_name, "ui: multiplayer button added to the game menu bar")
	return true


# Sizes the panel and centres it. The size comes from the caller because the game draws at a fixed
# 1600x900 and lets the engine stretch it, so the window size is not the space controls live in.
# It is also done explicitly rather than with anchors: a Control added hidden never receives the layout
# notification that would resolve its anchors, so it stayed a zero-sized rectangle.
static func layout(panel, screen):
	if panel == null:
		return
	panel.set_pos(Vector2(0, 0))
	panel.set_size(screen)

	var backdrop = panel.find_node("backdrop", true, false)
	if backdrop != null:
		backdrop.set_pos(Vector2(0, 0))
		backdrop.set_size(screen)

	var window = panel.find_node("window", true, false)
	if window != null:
		window.set_size(Vector2(WINDOW_WIDTH, WINDOW_HEIGHT))
		window.set_pos(Vector2(
			(screen.x - WINDOW_WIDTH) * 0.5,
			(screen.y - WINDOW_HEIGHT) * 0.5
		))


static func __build_panel(coop):
	var root = Control.new()
	root.set_size(Vector2(WINDOW_WIDTH, WINDOW_HEIGHT))

	var backdrop = ColorFrame.new()
	backdrop.set_name("backdrop")
	# ColorRect does not exist in this build; the game's own replacement is ColorFrame (scripts/theme).
	backdrop.set_frame_color(Color(0, 0, 0, 0.6))
	root.add_child(backdrop)

	var window = PanelContainer.new()
	window.set_name("window")
	window.set_size(Vector2(WINDOW_WIDTH, WINDOW_HEIGHT))
	root.add_child(window)

	var box = VBoxContainer.new()
	box.set_name("box")
	window.add_child(box)

	var title_row = HBoxContainer.new()
	box.add_child(title_row)

	var title = Label.new()
	title.set_text("Multiplayer")
	title_row.add_child(title)

	var close = Button.new()
	close.set_name("close")
	close.set_text("Close")
	close.connect("pressed", coop, "ui_close_panel")
	title_row.add_child(close)

	var status = Label.new()
	status.set_name("status")
	status.set_text("")
	box.add_child(status)

	var players_row = HBoxContainer.new()
	box.add_child(players_row)
	var players_label = Label.new()
	players_label.set_text("Give to")
	players_row.add_child(players_label)
	var players = OptionButton.new()
	players.set_name("players")
	players.set_custom_minimum_size(Vector2(220, 32))
	players_row.add_child(players)

	# --- money -------------------------------------------------------------
	var money_row = HBoxContainer.new()
	box.add_child(money_row)
	var money_label = Label.new()
	money_label.set_text("Money")
	money_row.add_child(money_label)
	var amount = LineEdit.new()
	amount.set_name("amount")
	amount.set_text("100000")
	amount.set_custom_minimum_size(Vector2(160, 32))
	money_row.add_child(amount)
	var money_button = Button.new()
	money_button.set_name("offer_money")
	money_button.set_text("Offer money")
	money_button.connect("pressed", coop, "ui_offer_money")
	money_row.add_child(money_button)

	# --- technology --------------------------------------------------------
	var tech_row = HBoxContainer.new()
	box.add_child(tech_row)
	var tech_label = Label.new()
	tech_label.set_text("Technology")
	tech_row.add_child(tech_label)
	var genres = OptionButton.new()
	genres.set_name("genres")
	genres.set_custom_minimum_size(Vector2(300, 32))
	tech_row.add_child(genres)
	var tech_button = Button.new()
	tech_button.set_name("offer_tech")
	tech_button.set_text("Offer technology")
	tech_button.connect("pressed", coop, "ui_offer_technology")
	tech_row.add_child(tech_button)

	# --- IP ----------------------------------------------------------------
	var ip_row = HBoxContainer.new()
	box.add_child(ip_row)
	var ip_label = Label.new()
	ip_label.set_text("IP")
	ip_row.add_child(ip_label)
	var games = OptionButton.new()
	games.set_name("games")
	games.set_custom_minimum_size(Vector2(300, 32))
	ip_row.add_child(games)
	var ip_button = Button.new()
	ip_button.set_name("offer_ip")
	ip_button.set_text("Offer IP")
	ip_button.connect("pressed", coop, "ui_offer_ip")
	ip_row.add_child(ip_button)

	# --- offers waiting for this player ------------------------------------
	var offers_title = Label.new()
	offers_title.set_text("Offers waiting for you")
	box.add_child(offers_title)

	var offers = VBoxContainer.new()
	offers.set_name("offers")
	box.add_child(offers)

	# --- carrying on without a departed player ------------------------------
	#
	# The host is told, when somebody leaves, to "confirm whether to carry on without them
	# (--coop-continue-without, or the Continue action)" - but there was no Continue action. The mod
	# paused the world for a player who had gone and offered no way to disagree, so the only exits were
	# a command-line flag fixed at launch or killing the process. __confirm_continue() existed and was
	# reachable only from an inbound message nobody sends.
	var departed_title = Label.new()
	departed_title.set_text("Carry on without")
	box.add_child(departed_title)

	var departed_row = HBoxContainer.new()
	box.add_child(departed_row)
	var departed = OptionButton.new()
	departed.set_name("departed")
	departed.set_custom_minimum_size(Vector2(300, 32))
	departed_row.add_child(departed)
	var continue_button = Button.new()
	continue_button.set_name("continue_without")
	continue_button.set_text("Continue without them")
	continue_button.connect("pressed", coop, "ui_continue_without")
	departed_row.add_child(continue_button)

	return root


# Repaints the panel from the game's own models. Called when it opens and after every action, so what
# is on screen is always what the world currently says.
static func refresh(panel, coop, log_name):
	if panel == null:
		return
	var players = panel.find_node("players", true, false)
	if players != null:
		var ids = coop.ui_other_players()
		__fill_options(players, coop.ui_player_labels(ids), ids)

	var target = __selected_id(players)

	var genres = panel.find_node("genres", true, false)
	if genres != null:
		var missing = coop.ui_missing_genres(target)
		var labels = []
		var genre_ids = []
		for entry in missing:
			labels.push_back(dict_lib.text(entry, "label", "?"))
			genre_ids.push_back(dict_lib.text(entry, "id", ""))
		__fill_options(genres, labels, genre_ids)
		if genre_ids.size() == 0:
			genres.add_item("nothing they are missing")
			genres.select(0)
			genres.set_meta("ids", [""])

	var games = panel.find_node("games", true, false)
	if games != null:
		var mine = coop.ui_published_games()
		var labels = []
		var game_ids = []
		for entry in mine:
			labels.push_back(dict_lib.text(entry, "name", "?"))
			game_ids.push_back(dict_lib.text(entry, "id", ""))
		if game_ids.size() == 0:
			labels.push_back("no published game")
			game_ids.push_back("")
		__fill_options(games, labels, game_ids)

	__refresh_offers(panel, coop)

	var departed = panel.find_node("departed", true, false)
	if departed != null:
		var gone = coop.ui_departed_players()
		var gone_labels = []
		var gone_ids = []
		for entry in gone:
			gone_labels.push_back(dict_lib.text(entry, "label", "?"))
			gone_ids.push_back(dict_lib.text(entry, "id", ""))
		if gone_ids.size() == 0:
			gone_labels.push_back("nobody has left")
			gone_ids.push_back("")
		__fill_options(departed, gone_labels, gone_ids)


static func __refresh_offers(panel, coop):
	var offers_box = panel.find_node("offers", true, false)
	if offers_box == null:
		return
	for child in offers_box.get_children():
		offers_box.remove_child(child)
		child.queue_free()

	var waiting = coop.ui_pending_offers()
	var shown = 0
	for offer in waiting:
		if shown >= MAX_OFFER_ROWS:
			break
		shown += 1
		var row = HBoxContainer.new()
		var label = Label.new()
		label.set_text(trade.describe(offer))
		row.add_child(label)

		var offer_id = dict_lib.text(offer, "id", "")
		var take = Button.new()
		take.set_name("take_" + String(shown))
		take.set_text("Take")
		take.connect("pressed", coop, "ui_accept_offer", [offer_id])
		row.add_child(take)

		var refuse = Button.new()
		refuse.set_name("refuse_" + String(shown))
		refuse.set_text("Refuse")
		refuse.connect("pressed", coop, "ui_refuse_offer", [offer_id])
		row.add_child(refuse)

		offers_box.add_child(row)

	if waiting.size() > shown:
		var more = Label.new()
		more.set_text("and %s more" % [String(waiting.size() - shown)])
		offers_box.add_child(more)
	if waiting.size() == 0:
		var none = Label.new()
		none.set_name("none")
		none.set_text("nothing yet")
		offers_box.add_child(none)


static func set_status(panel, text):
	if panel == null:
		return
	var status = panel.find_node("status", true, false)
	if status != null and status.has_method("set_text"):
		status.set_text(String(text))


static func amount_text(panel):
	if panel == null:
		return ""
	var amount = panel.find_node("amount", true, false)
	if amount == null or not amount.has_method("get_text"):
		return ""
	return String(amount.get_text())


# Money a player can type: 2500, 2k, 5m, and commas are ignored. Anything else is refused, and a
# negative is always refused - an offer must never turn into taking money off the other player.
# Returns the amount, or -1 when it is not usable.
static func parse_amount(text):
	var cleaned = String(text).strip_edges().to_lower().replace(",", "").replace(" ", "")
	if cleaned == "":
		return -1

	var multiplier = 1
	var last = cleaned.substr(cleaned.length() - 1, 1)
	if last == "k":
		multiplier = 1000
		cleaned = cleaned.substr(0, cleaned.length() - 1)
	elif last == "m":
		multiplier = 1000000
		cleaned = cleaned.substr(0, cleaned.length() - 1)

	if cleaned == "":
		return -1
	for i in range(cleaned.length()):
		if "0123456789".find(cleaned.substr(i, 1)) < 0:
			return -1

	var amount = cleaned.to_int() * multiplier
	if amount <= 0:
		# Also catches an overflow that wrapped round to a negative.
		return -1
	return amount


static func selected_player(panel):
	return __selected_id(panel.find_node("players", true, false))


static func selected_genre(panel):
	return __selected_id(panel.find_node("genres", true, false))


static func selected_game(panel):
	return __selected_id(panel.find_node("games", true, false))


static func selected_departed(panel):
	return __selected_id(panel.find_node("departed", true, false))


# --- small helpers ------------------------------------------------------

static func __fill_options(option, labels, ids):
	while option.get_item_count() > 0:
		option.remove_item(option.get_item_count() - 1)
	for label in labels:
		option.add_item(String(label))
	if labels.size() > 0:
		option.select(0)
	option.set_meta("ids", ids)


static func __selected_id(option):
	if option == null or not option.has_method("get_selected"):
		return ""
	var index = option.get_selected()
	if index < 0:
		return ""
	var ids = option.get_meta("ids")
	if ids == null or typeof(ids) != TYPE_ARRAY or index >= ids.size():
		return ""
	return String(ids[index])
