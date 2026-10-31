extends Reference

# Competitive co-op: turn each human player's company into one the game already understands.
#
# The game simulates one player studio plus a set of AI competitors ("concurrent" model). A
# competitor record is tiny and its shape is documented by the game itself
# (scripts/models/concurrent.gd, create_concurrent):
#
#     id, fanbase, fanbase_change, studio (list), note, currency,
#     locked, concurrent_bought, angryness, "self-publish"
#
# and the display data (name, logo, engine royalties) comes from the static catalogue
# static_data.get_data("concurrent").list[id], which is a plain dictionary we can add to at
# runtime.
#
# So a human company is transplanted by building those two dictionaries from the player models.
# That is why this mode is stable: each machine remains the only authority for its own company,
# and the only thing on the wire is one competitor-shaped record per player - about 120 bytes,
# against 8 MB for a whole game state.
#
# This is also why nothing else is sent. The studio layout, staff, projects, saves and catalogue
# never leave the machine; the other player's company is presented at competitor fidelity, the
# same fidelity the game gives its AI rivals.

const RECORD_VERSION = 1
const ID_PREFIX = "coop-"
# The name the mod gives the office it opens for a player. Any office the game created for the player
# carries the name they chose, which is how the two are told apart when cleaning up duplicates.
const HOME_STUDIO_NAME = "Home"

const pngloader_utils = preload("res://scripts/utils/png-loader.gd")
const coop_log = preload("res://coop/log.gd")
const saves_lib = preload("res://coop/saves.gd")

# Starting balance for a company made from scratch on a joined world.
const STARTING_CURRENCY = 100000

# Fields of a competitor record we exchange. Everything else a competitor has is generated
# locally by the game (games, staff, studios) and is deliberately absent here.
const FIELDS = ["id", "name", "note", "fanbase", "currency", "studios"]


# The client boots the host's save, so player.id is the host's save id on both machines and cannot
# identify a player. The company id is derived from the player's name instead, and deliberately
# stable: a player who leaves and comes back with the same name is the same company, which is what
# lets them continue it rather than start again.
static func make_id(name):
	var base = ""
	var lowered = String(name).to_lower()
	for i in range(lowered.length()):
		var ch = lowered.substr(i, 1)
		if ch == " " or ch == "-" or ch == "_" or ch == "." or ch == "'":
			continue
		base += ch
	if base == "":
		base = "player"
	return ID_PREFIX + base


# Hands a returning player their company back: identity, money, prestige, fanbase, and every office
# with the furniture and build options it had when they left. The offices are recreated on the same
# map tiles, which is what makes this the same company rather than a new one.
static func restore_from_world(entry):
	if entry == null or not models.is_loaded():
		return "nothing to restore"

	var player = models.get_model("player")
	if entry.has("name"):
		player.set("_company_name", String(entry["name"]))
		player.set("_player_name", String(entry["name"]))
	if entry.has("note"):
		player.set("_note", float(entry["note"]))
	if entry.has("currency"):
		models.get_model("currency").force_currency(int(entry["currency"]))
	if entry.has("fanbase"):
		models.get_model("fanbase").update_fanbase(int(entry["fanbase"]))

	var restored = 0
	var restored_tiles = []
	var first_tile = ""
	# Two shapes reach this function. A world save section carries `studios`; a record handed back by the
	# relay carries `offices` (that is what company.record() writes, and all the store keeps). Reading
	# only `studios` meant a returning player's company arrived, was recognised - and then had no offices
	# to restore, so they were given a brand new one and everything the relay had kept was discarded.
	var offices = null
	if entry.has("studios") and typeof(entry["studios"]) == TYPE_ARRAY:
		offices = entry["studios"]
	elif entry.has("offices") and typeof(entry["offices"]) == TYPE_ARRAY:
		offices = entry["offices"]
	if offices != null:
		for saved in offices:
			if saved == null or not saved.has("t"):
				continue
			# A saved office carries only its tile id here; its furniture lives in `layouts`. The two are
			# joined before restoring, or a returning player gets the room back with nothing in it.
			var with_items = __with_layout(saved, entry)
			if restore_studio(with_items):
				restored += 1
				restored_tiles.push_back(String(saved["t"]))
				if first_tile == "":
					first_tile = String(saved["t"])

	# None of the saved offices exist on this map. That is the normal case for a returning player: the
	# tiles were on the previous host's map, and this world is somebody else's with its own tile ids. The
	# company still comes back - identity, money, fanbase, games, consoles - and so does the *interior*,
	# which is what the player actually built and the part worth keeping. The room is reopened on a free
	# tile and furnished from the saved layout.
	if restored == 0 and offices != null and offices.size() > 0:
		var reopened = __reopen_from_layout(entry, String(entry["name"]))
		if reopened != "":
			restored = 1
			restored_tiles.push_back(reopened)
			first_tile = reopened
		else:
			coop_log.warning("coop", "restore: %s saved office(s) could not be reopened on this map"
				% [String(offices.size())])

	if restored == 0:
		return "restored %s but had no offices, opening one" % [String(entry["name"])] \
			+ ", " + open_first_studio(String(entry["name"]))

	# Collapse the duplicate "Home" offices *before* re-seating the staff, and then re-seat them onto an
	# office that survived. Doing it the other way round was a real bug: the staff were moved into the
	# first saved office, the collapse then closed that office because it was a duplicate, and every
	# employee was left pointing at a room that no longer existed - the player had 0 developers.
	ensure_single_home(String(entry["name"]))
	var seat = __surviving_office(restored_tiles)

	# The office the player ends up in has to be one they can actually work in. A record restored from
	# the host's save can be several joins old: it describes rooms whose furniture was never filled, so
	# resting on "there are offices" left the player with one office, no desk, nobody seated and no
	# developers - the reported "client actually has 0 developers". So the seat is furnished and the
	# player is seated, exactly as a brand-new office is.
	if seat != "" and not has_workstation(seat):
		__stock_first_office(seat, __office_for(seat))

	var rebound = __rebind_staff(seat)
	if rebound > 0:
		coop_log.info("coop", "restore: %s employee(s) re-seated into office %s" % [
			String(rebound), seat.substr(0, 8)
		])
	# Nobody at all in the company means the saved record carried no staff. Hiring through the game's
	# own create_admin() puts the player themselves back in their office.
	if seat != "" and not _staff_present():
		__admin()
		__ensure_workstation(seat)
		rebound = __rebind_staff(seat)
		coop_log.info("coop", "restore: the saved record held no staff, seated %s" % [String(rebound)])
	var studio_model = models.get_model("studio")
	if studio_model.has_method("select_studio"):
		studio_model.select_studio(seat)
	return "restored %s with %s office(s), %s employee(s) re-seated" % [
		String(entry["name"]), String(restored), String(rebound)
	]


# Folds a saved record's `layouts` entry into one of its `offices`, so the furniture travels with the
# room. company.record() writes the two lists separately (an office is a tile and a name, a layout is
# what is standing in it); restore_studio() wants one dictionary holding both.
static func __with_layout(office, entry):
	if office == null:
		return office
	if office.has("items") and office["items"] != null and office["items"].size() > 0:
		return office
	if not entry.has("layouts") or typeof(entry["layouts"]) != TYPE_ARRAY:
		return office
	var tile = String(office["t"])
	for layout in entry["layouts"]:
		if layout == null or not layout.has("t"):
			continue
		if String(layout["t"]) != tile:
			continue
		var joined = {}
		for key in office.keys():
			joined[key] = office[key]
		for key in layout.keys():
			joined[key] = layout[key]
		return joined
	return office


# Reopens a returning player's office on this map and furnishes it from the saved layout.
#
# A tile id is a map tile id, and the map belongs to whoever is hosting: a company restored from a world
# its player has not joined yet is pointing at tiles that do not exist here. The room cannot be carried
# across, but its *contents* can - and the contents are the part the player made.
static func __reopen_from_layout(entry, label):
	if not entry.has("layouts") or typeof(entry["layouts"]) != TYPE_ARRAY or entry["layouts"].size() == 0:
		return ""
	var layout = entry["layouts"][0]
	if layout == null:
		return ""
	# open_first_studio() answers with a sentence, not a tile id - using that sentence as an id is why
	# this silently did nothing on the first attempt. The tile is read back from the studio model.
	var opened = open_first_studio(label)
	if opened == "" or opened.begins_with("could not"):
		return ""
	var tile = first_player_studio()
	if tile == "":
		tile = opened
	var studio_model = models.get_model("studio")
	var studio = studio_model.get_studio_by_id(tile)
	if studio == null:
		return ""
	if layout.has("items") and layout["items"] != null and layout["items"].size() > 0:
		studio["items"] = __own_items(layout["items"])
	if layout.has("buildMod") and layout["buildMod"] != null:
		studio["buildMod"] = layout["buildMod"]
	if layout.has("area"):
		studio["area"] = int(layout["area"])
	var furnished = 0
	if studio.has("items") and studio["items"] != null:
		furnished = studio["items"].size()
	coop_log.info("coop", "restore: reopened the office on this map with %s piece(s) of the saved layout"
		% [String(furnished)])
	return opened


# Whether the company has any employee at all, in any specialty group.
static func _staff_present():
	if not models.has_model("staff"):
		return false
	var data = models.get_model("staff").get_data()
	for specialty in data.keys():
		var group = data[specialty]
		if group == null or typeof(group) != TYPE_DICTIONARY:
			continue
		for employee_id in group:
			if group[employee_id] != null:
				return true
	return false


# The tile record an office sits on, which is what furnishing needs.
static func __office_for(studio_id):
	if not models.has_model("map"):
		return null
	return models.get_model("map").get_tile_by_id(studio_id)


# Which office to put the staff in: the first saved one that still exists, else whatever this player has.
static func __surviving_office(preferred):
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	for tile_id in preferred:
		if concurrent.is_studio_owned(tile_id):
			continue
		if studio_model.get_studio_by_id(tile_id) != null:
			return String(tile_id)
	var own = first_player_studio()
	if own != "":
		return own
	return String(preferred[0]) if preferred.size() > 0 else ""


# Puts a competitor back into the world from its saved company section. Used when something removed a
# player's company while that player is still connected: an AI rival buying them out, for instance.
static func restore_competitor(player_id, entry):
	if entry == null:
		return false
	var offices = []
	if entry.has("offices") and entry["offices"] != null:
		for office in entry["offices"]:
			if office != null and office.has("t"):
				offices.push_back(String(office["t"]))
	spawn(
		String(player_id),
		String(entry["name"]) if entry.has("name") else String(player_id),
		null,
		int(entry["fanbase"]) if entry.has("fanbase") else 0,
		float(entry["note"]) if entry.has("note") else 0.0,
		int(entry["currency"]) if entry.has("currency") else 0,
		offices
	)
	return true


# True for a company another person is playing, as opposed to one the game generated as a rival.
# Player companies all carry this mod's id prefix, and the world's company section is the authority on
# which ids are people.
static func is_player_company(company_id):
	var id = String(company_id)
	if id.begins_with(ID_PREFIX):
		return true
	if not models.has_model("coop-state"):
		return false
	return models.get_model("coop-state").has_player(id)


# True when a company is another player's, and therefore not something this player may buy out.
static func is_other_player(company_id, own_id):
	return is_player_company(company_id) and String(company_id) != String(own_id)


# Recreates one saved office on its map tile, keeping its furniture and build options.
static func restore_studio(saved):
	var studio_model = models.get_model("studio")
	var tile_id = String(saved["t"])
	if studio_model.get_studio_by_id(tile_id) != null:
		return false
	var tile = models.get_model("map").get_tile_by_id(tile_id)
	if tile == null:
		# The tile is not on this map, so the office cannot come back here.
		return false

	var date = models.get_model("date").get_date()
	var area = int(saved["area"]) if saved.has("area") else 20
	var studio = studio_model.create_studio("Home", area, tile_id, "buy", date)
	var had_items = false
	if saved.has("items") and saved["items"] != null and saved["items"].size() > 0:
		studio["items"] = __own_items(saved["items"])
		had_items = true
	if saved.has("buildMod") and saved["buildMod"] != null:
		studio["buildMod"] = saved["buildMod"]
	if saved.has("productivity"):
		studio["productivity"] = saved["productivity"]
	if saved.has("happiness"):
		studio["happiness"] = saved["happiness"]
	studio_model.open_studio(studio, false)
	# A company saved before the home office was furnished comes back with an empty room, and a room
	# with no desk and no computer cannot develop anything, so it is stocked the way a new one is.
	if not had_items:
		__stock_first_office(studio.id, tile)
	if saved.has("name") and String(saved["name"]) != "":
		__name_tile(tile_id, __unique_name(String(saved["name"])))
	return true


# Furniture copied from a saved office is given fresh item ids and loses its employee binding.
#
# A captured layout is a copy of a room that already had desks assigned to people, so copying it as-is
# put the same employee at a desk in two different offices, and the same item id twice in the model.
# The staff are re-seated by __rebind_staff() onto the office that actually exists here.
static func __own_items(items):
	var out = {}
	for key in items:
		var item = items[key]
		if item == null:
			continue
		var copy = {}
		for field in item.keys():
			copy[field] = item[field]
		var new_id = "coop-item-%s-%s" % [String(OS.get_ticks_msec()), String(randi())]
		copy["id"] = new_id
		copy["employee_id"] = null
		if copy.has("employee"):
			copy["employee"] = null
		out[new_id] = copy
	return out


# Every employee this player has is put in the office that exists on this map, so nobody is left pointing
# at a studio id from the machine the company was created on.
static func __rebind_staff(tile_id):
	if not models.has_model("staff"):
		return 0
	var staff = models.get_model("staff")
	var data = staff.get_data()
	var rebound = 0
	for specialty in data.keys():
		var group = data[specialty]
		if group == null or typeof(group) != TYPE_DICTIONARY:
			continue
		for employee_id in group:
			var employee = group[employee_id]
			if employee == null or typeof(employee) != TYPE_DICTIONARY:
				continue
			if employee.has("studio_id") and String(employee["studio_id"]) == tile_id:
				continue
			employee["studio_id"] = tile_id
			rebound += 1
	return rebound


# Moves only the employees who were in `from_tile` into `to_tile`. Used when a duplicate office is
# closed, so nobody is left pointing at a room that no longer exists.
static func __rebind_staff_from(from_tile, to_tile):
	if from_tile == "" or to_tile == "" or not models.has_model("staff"):
		return 0
	var staff = models.get_model("staff")
	var data = staff.get_data()
	var moved = 0
	for specialty in data.keys():
		var group = data[specialty]
		if group == null or typeof(group) != TYPE_DICTIONARY:
			continue
		for employee_id in group:
			var employee = group[employee_id]
			if employee == null or typeof(employee) != TYPE_DICTIONARY:
				continue
			if not employee.has("studio_id"):
				continue
			if String(employee["studio_id"]) != from_tile:
				continue
			employee["studio_id"] = to_tile
			moved += 1
	if moved > 0:
		coop_log.info("coop", "office: %s employee(s) moved from %s to %s" % [
			String(moved), from_tile.substr(0, 8), to_tile.substr(0, 8)
		])
	return moved


# A name that is not already used by one of the player's offices, so two restored offices cannot both
# be called "Home".
static func __unique_name(base):
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var used = []
	var data = studio_model.get_data()
	if data.has("list") and data["list"] != null:
		for studio_id in data["list"]:
			if concurrent.is_studio_owned(studio_id):
				continue
			var studio = data["list"][studio_id]
			if studio != null and studio.has("name"):
				used.push_back(String(studio["name"]))
	if not used.has(base):
		return base
	var index = 2
	while used.has("%s %s" % [base, String(index)]):
		index += 1
	return "%s %s" % [base, String(index)]


# This player's company, in the shape saved into the world (see scripts/models/coop-state.gd).
#
# Everything needed to bring the company back later without the player being connected: identity,
# money, prestige, fanbase, the offices on the map, the games released, and the layout of each office.
static func snapshot():
	if not models.is_loaded():
		return null
	var player = models.get_model("player").get_data()
	return {
		name = String(player.company_name),
		note = float(player.note),
		currency = int(models.get_model("currency").get_currency()),
		fanbase = int(models.get_model("fanbase").get_fanbase()),
		offices = owned_studios(),
		games = my_games(),
		studios = studio_layouts(),
		# The genres this company knows. Kept so another player's machine can see what it is missing,
		# which is what makes gifting a technology a specific act rather than a guess.
		genres = my_genres()
	}


static func my_genres():
	if not models.has_model("game-type"):
		return []
	var genres = models.get_model("game-type").get_unlocked_game_types()
	var out = []
	if genres == null:
		return out
	for genre_id in genres:
		out.push_back(String(genre_id))
	return out


# The layout of every office the player owns, so a saved company keeps its furniture and build
# options. Item ids inside an office are per-machine, so they are kept exactly as they are.
static func studio_layouts():
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var data = studio_model.get_data()
	var layouts = []
	if not data.has("list") or data["list"] == null:
		return layouts
	var list = data["list"]
	for studio_id in list:
		if concurrent.is_studio_owned(studio_id):
			continue
		var studio = list[studio_id]
		layouts.push_back({
			t = String(studio_id),
			name = String(studio["name"]) if studio.has("name") else "",
			area = int(studio["area"]) if studio.has("area") else 20,
			items = studio["items"] if studio.has("items") else {},
			buildMod = studio["buildMod"] if studio.has("buildMod") else {},
			productivity = studio["productivity"] if studio.has("productivity") else 1.0,
			happiness = studio["happiness"] if studio.has("happiness") else 0.5
		})
	return layouts


# Writes this player's company into the save section, so the company is part of the world rather than
# something rebuilt from network traffic.
static func save_into_world(player_id, present = true):
	if not models.has_model("coop-state"):
		return false
	var coop = models.get_model("coop-state")
	var previous = coop.get_player(player_id)
	# Never save the debris forward: whatever the world arrived with, the company that goes back into it
	# holds one home office, not one per session. Done *before* the snapshot, or the duplicate would be
	# in the payload that is about to be written.
	ensure_single_home(String(previous["name"]) if previous != null and previous.has("name") else "")
	var payload = snapshot()
	if payload == null:
		return false
	payload["present"] = present
	payload["host_confirmed"] = false
	# Offers are a ledger, not part of the company snapshot, so they must survive being rewritten.
	if previous != null and previous.has("offers") and previous["offers"] != null:
		payload["offers"] = previous["offers"]
	if previous != null and previous.has("host_confirmed"):
		payload["host_confirmed"] = previous["host_confirmed"]
	coop.set_player(player_id, payload)
	return true


# Reads a company back out of the save section.
static func load_from_world(player_id):
	if not models.has_model("coop-state"):
		return null
	return models.get_model("coop-state").get_player(player_id)


# This player's released games, trimmed to what another machine needs to list them.
#
# The other player's company has to show the same games, not an empty catalog, so the games travel
# with the company record and are rebuilt as that competitor's releases on the receiving side.
static func my_games(exclude = null):
	if not models.is_loaded():
		return []
	var data = models.get_model("game").get_data()
	var catalog = {}
	if data.has("catalog") and data["catalog"] != null:
		catalog = data["catalog"]

	# A player's finished games sit in "published"; "released" is the bucket the rival model uses, and
	# old titles live in "discontinued". A game in development is announced, which is what the rival
	# model calls the same thing.
	var buckets = [
		{name = "published", state = "released"},
		{name = "released", state = "released"},
		{name = "discontinued", state = "released"},
		{name = "dev", state = "announced"}
	]
	var games = []
	for bucket in buckets:
		if not catalog.has(bucket["name"]) or catalog[bucket["name"]] == null:
			continue
		var entries = catalog[bucket["name"]]
		for game_id in entries:
			var game = entries[game_id]
			if game == null:
				continue
			var entry = {id = String(game_id), state = bucket["state"]}
			# Games inserted here for the other player are not ours; without this the player's own
			# catalog appears to grow every time a remote company is transplanted.
			if exclude != null and exclude.has(String(game_id)):
				continue
			entry["name"] = String(game_id)
			if game.has("name"):
				entry["name"] = String(game["name"])
			entry["note"] = 0.0
			if game.has("computed_note"):
				entry["note"] = float(game["computed_note"])
			elif game.has("note"):
				entry["note"] = float(game["note"])
			entry["units"] = 0.0
			if game.has("unit_sold_total"):
				entry["units"] = float(game["unit_sold_total"])
			entry["platform"] = ""
			if game.has("platform"):
				entry["platform"] = String(game["platform"])
			# The platform *id*, not only its name. The rival sales pass does
			# `platform_model.get_unit_sold(game_published.platform_id)` and
			# `get_amount_of_games_released(game_published.platform_id)`, and both dereference
			# `get_platform_by_id(id)` with no null check - so an empty id kills the receiving machine with
			# 0xc0000005 at 0xae5633 on the first monthly sales pass after a released game arrives. That is
			# the blocker this pass was written to clear: it took a released game crossing the wire, which
			# no run had managed before.
			entry["platform_id"] = ""
			if game.has("platform_id"):
				entry["platform_id"] = String(game["platform_id"])
			# The trade screen builds its rows from these two, so they travel with the offer.
			entry["types"] = game["type_list"] if game.has("type_list") else []
			entry["theme"] = String(game["theme"]) if game.has("theme") else ""
			entry["cycle"] = 1
			if game.has("cycle"):
				entry["cycle"] = int(game["cycle"])
			# `computed_note` is what the sales pass reads; `note` is what the offer screen shows.
			entry["computed_note"] = float(entry["note"])
			if game.has("release_date"):
				entry["date"] = game["release_date"]
			games.push_back(entry)
	return games


# A player's published games, offered to the others through the game's own trade-proposal feed.
#
# The "publish game offers from IP holders" screen (scenes/game/project/kickoff-trade) is built by walking
# every competitor and reading concurrent_game_model.get_concurrent_proposals(id). Anything written there
# for a player's competitor shows up in that screen as an offer, with that player's name and logo, and can
# be picked as a project - which is exactly the connection wanted between players, using the game's own
# screen rather than a new one.
#
# The proposal has to be a *complete* game record, not a summary. The game builds these itself in
# controllers/concurrent-game.gd `_create_trade_publish_game()` with fifteen fields; the screen and the
# project it starts read all of them. A shorter dictionary compiles, logs and looks fine, and then the
# first frame that reads a missing member is a native access violation at 0xae5633 - which is exactly
# what happened the first time a released game crossed the wire: the host crashed one second after
# `competitor coop-tester ... games_sent=1 new_games=1`, twice in a row. The screen had never been opened
# before that, because releasing was switched off, so the incomplete record had never been read.
static func publish_offers(player_id, games):
	if games == null or not models.has_model("concurrent-game"):
			return 0
	var model = models.get_model("concurrent-game")
	var proposals = []
	for game in games:
			if game == null or not game.has("id"):
				continue
			var name = String(game["name"]) if game.has("name") else String(game["id"])
			var theme = String(game["theme"]) if game.has("theme") else ""
			var types = game["types"] if game.has("types") and game["types"] != null else []
			if types.size() == 0:
				continue
			# The royalty a publisher would pay is derived from the note, the way the game derives it: a
			# better game is worth a bigger cut, and this is the number the offer screen displays.
			var note = float(game["note"]) if game.has("note") else 0.0
			note = clamp(note, 0.0, 100.0)
			var royalties = int(round(clamp(5.0 + note / 10.0, 5.0, 15.0)))
			var platform = String(game["platform"]) if game.has("platform") else ""
			# The platform id travels when the other machine sent one this world can resolve, because the
			# sales pass needs a resolvable id and cannot cope without one. A *chosen* offer like this one
			# never reaches that pass until somebody accepts it, but sending an id that cannot resolve
			# would be handing over the same fault the transplant side just had to repair.
			var platform_id = String(game["platform_id"]) if game.has("platform_id") else ""
			if platform_id != "" and not __platform_known(platform_id):
				platform_id = ""
			proposals.push_back({
				id = String(game["id"]),
				concurrent_id = String(player_id),
				name = name,
				online = false,
				platform = platform,
				platform_id = platform_id,
				theme = theme,
				theme_label = "LABEL_THEME_%s" % [theme.to_upper()],
				date = game["date"] if game.has("date") else null,
				presequel = null,
				size = "normal",
				size_label = "LABEL_GAME_SIZE_NORMAL",
				type_list = types,
				target = "all",
				target_label = "LABEL_TARGETTED_AUDIENCE_ALL",
				royalties = royalties,
				minimum_note = note,
				income = 0.0,
				penalty = 0.0,
				cracked = false,
				engine_id = null
			})
	model.set_concurrent_proposals(String(player_id), proposals)
	return proposals.size()


# The player's own studios, as map tiles.
#
# A studio is a tile on the map, and both machines boot the same map, so tile ids are meaningful on
# both sides. Sending them is what makes a player's company exist on the map for everyone else:
# without it the other player's studios are just unowned "Studio" tiles.
static func owned_studios():
	if not models.is_loaded():
		return []
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var data = studio_model.get_data()
	var list = {}
	if data.has("list") and data["list"] != null:
		list = data["list"]

	var studios = []
	for studio_id in list:
		if concurrent.is_studio_owned(studio_id):
			continue
		var studio = list[studio_id]
		var name = String(studio_id)
		if studio != null and studio.has("name"):
			name = String(studio["name"])
		studios.push_back({t = String(studio_id), n = name})
	return studios


# The local player's company as a competitor record, or null when no game is loaded.
static func record(player_id, slot = null, exclude_games = null, session_save_id = ""):
	if not models.is_loaded():
		return null

	var player = models.get_model("player").get_data()

	var fanbase = 0
	if models.has_model("fanbase"):
		fanbase = int(models.get_model("fanbase").get_fanbase())

	var currency = 0
	if models.has_model("currency"):
		currency = int(models.get_model("currency").get_currency())

	var studios = 0
	if models.has_model("studio"):
		studios = int(models.get_model("studio").get_number_of_studios())

	return {
		v = RECORD_VERSION,
		id = player_id,
		slot = slot,
		name = String(player.company_name),
		note = float(player.note),
		fanbase = fanbase,
		currency = currency,
		studios = studios,
		offices = owned_studios(),
		layouts = studio_layouts(),
		consoles = my_consoles(),
		games = my_games(exclude_games),
		genres = my_genres(),
		# The name of the save this player's own game would write. It travels with the company so the
		# relay can tell a returning player which save is theirs; the file itself never leaves the
		# machine that wrote it.
		save = saves_lib.save_name(String(session_save_id), String(player_id)),
		session = String(session_save_id),
		# The conventions this machine knows about. Conventions are half shared and half personal: which
		# events exist is the world's, what a player did with them is not. Carrying the catalogue here is
		# what stops one player seeing a convention the other cannot.
		conventions = convention_catalogue()
	}


# The shared half of the convention model: the events themselves. See state_sync.convention_catalogue
# for why only this half travels.
static func convention_catalogue():
	if not models.is_loaded() or not models.has_model("convention"):
		return null
	var convention = models.get_model("convention")
	var data = convention.get_data()
	var known = 0
	# The list a player is actually shown: the shipped conventions plus anything generated this session.
	# Counting only `generated`/`announced` reports 0 in a young game even though the catalogue is fine,
	# which is what made the shared-catalogue check fail on two healthy machines.
	if convention.has_method("list_existing_conventions"):
		var existing = convention.call("list_existing_conventions")
		if existing != null:
			known = existing.size()
	return {
		known = known,
		generated = data["generated"] if data.has("generated") else {},
		announced = data["announced"] if data.has("announced") else {}
	}


# What this player has done with conventions, for the log and for the checks: their own plans, what is
# running for them, what they have attended, and whether they auto-attend.
static func my_conventions():
	if not models.is_loaded() or not models.has_model("convention"):
		return {planned = 0, running = 0, attended = 0, autoattend = false}
	var convention = models.get_model("convention")
	var autoattend = false
	if convention.has_method("is_autoattending_convention"):
		autoattend = bool(convention.call("is_autoattending_convention"))
	return {
		planned = convention.list_planned_conventions().size(),
		running = convention.list_running_conventions().size(),
		attended = convention.list_archived_conventions().size(),
		autoattend = autoattend
	}


# Whether this machine's per-save trend table has an entry for a theme.
#
# `get_trend_by_theme()` indexes the table without checking, so anything that will be handed to the
# game's sale maths has to be validated against it first. The static catalogue (`game_themes`) is not
# enough: a theme can exist as art and still have no trend entry in this save.
static func theme_known(name):
	if not models.has_model("game-theme"):
		return false
	var model = models.get_model("game-theme")
	# get_data()["trends"], not call("get_trends"): calling a method by name on this build's model nodes
	# returns nothing. A `trends` of null here made every theme look unknown, so nothing was ever given a
	# theme and the neutral path was used even when the theme did exist - the guard was inert, which is the
	# failure it was written to prevent.
	if not model.has_method("get_data"):
		return false
	var data = model.get_data()
	if data == null or typeof(data) != TYPE_DICTIONARY or not data.has("trends"):
		return false
	var trends = data["trends"]
	if trends == null or typeof(trends) != TYPE_DICTIONARY:
		return false
	return trends.has(String(name))


# A theme key this world's trend table actually holds, or "" if it holds none.
static func __first_known_theme():
	if not models.has_model("game-theme"):
		return ""
	var model = models.get_model("game-theme")
	if not model.has_method("get_data"):
		return ""
	var data = model.get_data()
	if data == null or typeof(data) != TYPE_DICTIONARY or not data.has("trends"):
		return ""
	var trends = data["trends"]
	if trends == null or typeof(trends) != TYPE_DICTIONARY:
		return ""
	for name in trends:
		# `get_trend_by_theme` also indexes a twelve-entry series, so a key with no series is no better
		# than a missing one.
		var series = trends[name]
		if series != null and series.size() > 0:
			return String(name)
	return ""


# Is this a platform id this machine can resolve? `get_platform_by_id` returning null is what kills the
# sales pass, so the question is asked before the id is used rather than after.
static func __platform_known(platform_id):
	if platform_id == "" or not models.has_model("platform"):
		return false
	var model = models.get_model("platform")
	if not model.has_method("get_platform_by_id"):
		return false
	# Called directly rather than through call(): a method called by name on these model nodes returns
	# nothing on this build, which would make every platform look unknown.
	var found = model.get_platform_by_id(String(platform_id))
	return found != null


# The first platform id this machine can resolve, or "".
static func __first_known_platform():
	if not models.has_model("platform"):
		return ""
	var model = models.get_model("platform")
	var date = models.get_model("date").get_date()
	if not model.has_method("get_platforms"):
		return ""
	for entry in model.get_platforms(date, false):
		if entry != null and entry.has("id"):
			return String(entry["id"])
	return ""


# The player's own game consoles, as data. Everything the player released or discontinued.
static func my_consoles():
	if not models.is_loaded() or not models.has_model("custom-platform"):
		return []
	var model = models.get_model("custom-platform")
	var list = []
	if model.has_method("list_platform_released"):
		for entry in model.list_platform_released():
			list.push_back(entry)
	if model.has_method("list_platform_discontinued"):
		for entry in model.list_platform_discontinued():
			list.push_back(entry)
	return list


# Puts another player's console into the world on this machine as a platform that company owns.
#
# The model that means "my consoles" is custom-platform, so a console copied into it is one the client
# can edit, price and release on - which is exactly what was happening. A console built by another
# company belongs in concurrent-platform, the same model that holds the rivals' platforms, and it needs
# the game's own platform registration so it is an ordinary platform with the right name and stats
# rather than a private record.
#
# What must NOT happen is the client's own digital store adopting it. A platform in the platform model is
# a platform in the world, and the store auto-supports whatever is compatible
# (controllers/digital-store-platform.gd _customplatform_released -> toggle_platform), so registering
# somebody else's console here made its customers the client's customers: the store computed a userbase
# for it and its server usage followed. The publisher link is therefore cleared for a console this
# machine does not own.
static func apply_consoles(owner_id, consoles, local_id = ""):
	if consoles == null or not models.has_model("concurrent-platform"):
		return 0
	var rival_platforms = models.get_model("concurrent-platform")
	var platform_model = models.get_model("platform")
	var controller = controllers.get_controller("custom-platform")
	var added = 0

	for entry in consoles:
		if entry == null or not entry.has("id"):
			continue
		var platform_id = String(entry["id"])
		var platform = entry
		# Ownership has to be on the platform record itself, not only in the catalog that indexes it: the
		# model reads `concurrent_id` off the platform when it decides whose console this is, and a copy
		# without it showed up as nobody's - which is how the client kept seeing the host's console
		# customers as its own.
		platform["concurrent_id"] = String(owner_id)
		var existing = rival_platforms.get_platform_by_id_slow(platform_id)
		if existing == null:
			rival_platforms.release_platform(String(owner_id), platform, false)
			added += 1
		else:
			# Already here: make sure it is still attributed to that company and not to us.
			existing["concurrent_id"] = String(owner_id)
		if controller != null and controller.has_method("_load_platform"):
			# The game's own registration step: this is what gives the console its name, generation,
			# power and market data in the platform model.
			controller.call("_load_platform", platform)
		var registered = platform_model.get_platform_by_id(platform_id)
		coop_log.info("coop", "net: console [%s] is a platform owned by %s (generation=%s type=%s)" % [
			String(registered["name"]) if registered != null and registered.has("name") else platform_id,
			String(owner_id),
			String(platform_model.get_platform_generation(platform_id)),
			String(platform_model.get_platform_type(platform_id))
		])

		# Somebody else's console is not a platform this company sells on. Without this the digital store
		# supports it, computes a userbase for it, and the player sees another company's customers as
		# their own - and their server usage with them.
		if models.has_model("digital-store"):
			var store = models.get_model("digital-store")
			var support = store.get_platform_if_exists(platform_id)
			if support != null:
				if support.has("supported") and support["supported"]:
					store.set_platform_supported(platform_id, false)
					coop_log.info("coop", "net: console %s is no longer one of ours to publish on" % [
						platform_id.substr(0, 8)
					])
				# Its customers are that company's, not this one's.
				support["userbase"] = 0
		# And it must not be reachable as one of *our* custom platforms either: the store builds its
		# compatible list from customplatform_model.list_platform_released() (see
		# controllers/digital-store-platform.gd list_compatible_platforms), so a console sitting in that
		# model is auto-supported every time support is recomputed, and its users become ours again.
		__detach_from_own_platforms(platform_id)

	if controller != null and controller.has_method("_compute_static_data_from_platforms"):
		controller.call("_compute_static_data_from_platforms")
	return added


# A player company that has been bought out is a tombstone in the world: it must not be re-created as
# a competitor by the next company-table update, and the player it belonged to must be told.
static func mark_acquired(player_id, buyer_id):
	if not models.has_model("coop-state"):
		return false
	var coop = models.get_model("coop-state")
	var entry = coop.get_player(player_id)
	if entry == null:
		return false
	entry["acquired"] = true
	entry["acquired_by"] = buyer_id
	entry["present"] = false
	return true


static func is_acquired(player_id):
	if not models.has_model("coop-state"):
		return false
	var entry = models.get_model("coop-state").get_player(player_id)
	return entry != null and entry.has("acquired") and bool(entry["acquired"])


static func acquired_by(player_id):
	if not models.has_model("coop-state"):
		return ""
	var entry = models.get_model("coop-state").get_player(player_id)
	if entry == null or not entry.has("acquired_by"):
		return ""
	return String(entry["acquired_by"])


# The company logo is a base64 PNG of a few tens of kilobytes, so it does not ride in the record:
# that is republished every few seconds and the logo almost never changes. It travels once, in its
# own message, and receivers keep it here.
static func logo():
	if not models.is_loaded():
		return null
	var player = models.get_model("player").get_data()
	if not player.has("company_logo"):
		return null
	return player["company_logo"]


# Percentage change from the previous record, so the log shows what actually moved.
static func change(previous, current):
	if previous == null:
		return "new"
	var parts = []
	for key in ["note", "fanbase", "currency", "studios"]:
		if previous.has(key) and current.has(key) and previous[key] != current[key]:
			parts.push_back("%s %s->%s" % [key, String(previous[key]), String(current[key])])
	if parts.size() == 0:
		return "unchanged"
	return join(parts, ", ")


# A logo arrives either inside a record or in the separate logo message, and once one is shown a
# later record without a logo must not wipe it.
#
# The catalogue holds a Texture, not the base64 string the player model keeps: the rival UI assigns
# it straight to a texture rect and calls get_path() on it, so a string breaks the company list.
static func __logo_for(company, id, catalogue, logos):
	var data = null
	if company.has("logo") and company["logo"] != null:
		data = company["logo"]
	elif logos != null and logos.has(id):
		data = logos[id]
	elif catalogue.has(id) and catalogue[id] != null and catalogue[id].has("logo"):
		return catalogue[id]["logo"]
	if data == null:
		return null
	if typeof(data) != TYPE_STRING:
		return data
	if data == "":
		return null
	return pngloader_utils.base64_to_variant(data)


# The live rival record for an id, read straight out of the model's dictionary.
#
# concurrent.get_concurrent_by_id() routes the id through a helper that this decompiled source shows
# as print(id); looking the key up here avoids depending on what that returns.
static func __rival(id):
	var live = models.get_model("concurrent").get_concurrent()
	if live == null:
		return null
	if live.has(id):
		return live[id]
	return null


static func catalogue():
	return __catalogue_data()


static func catalogue_name(company_id):
	var catalogue = __catalogue_data()
	if catalogue != null and catalogue.has(String(company_id)) and catalogue[String(company_id)] != null:
		var entry = catalogue[String(company_id)]
		if entry.has("name"):
			return String(entry["name"])
	return String(company_id)


# Every company in this world that a joining player could take over.
#
# Two sources, because two kinds of company exist:
#   * the AI rivals, which live in the concurrent model and are in `catalogue`;
#   * other co-op players' companies, which live in the coop-state section and carry their own name.
#
# There is no network round trip here and none is needed: a client only asks this once the host's world
# has arrived, and by then every company in it is already local. That is deliberate - a listing that
# came over the wire could disagree with the world it describes.
#
# Returns a list of {id, name, offices, currency, fanbase, kind, away}, which is what lobby.gd renders.
static func takeover_candidates():
	var out = []
	if not models.is_loaded() or not models.has_model("concurrent"):
		return out

	var own_id = ""
	var own_name = ""
	if models.has_model("player"):
		var me = models.get_model("player").get_data()
		if me != null and me.has("id"):
			own_id = String(me["id"])
		if me != null and me.has("company_name"):
			own_name = String(me["company_name"])

	var concurrent = models.get_model("concurrent")
	var live = concurrent.get_concurrent()
	if live != null:
		for company_id in live:
			var id = String(company_id)
			# Never offer this machine's own company as something to take over. The id check is the
			# reliable one; the name check below covers the case where a previous session wrote this
			# company's own name onto another rival's record.
			if id == own_id:
				continue
			var entry = live[company_id]
			if entry == null:
				continue
			var entry_name = catalogue_name(id)
			if entry.has("coop_name"):
				entry_name = String(entry["coop_name"])
			# Skip an entry that is this machine's own company wearing another id: a stale write from an
			# older build could leave the player's own name on a rival record, and offering it would let
			# a player "take over" themselves.
			if own_name != "" and entry_name == own_name:
				continue
			out.push_back({
				id = id,
				name = entry_name,
				offices = int(concurrent.get_concurrent_studio_amount(id)),
				currency = int(entry.currency) if entry.has("currency") else 0,
				fanbase = int(entry.fanbase) if entry.has("fanbase") else 0,
				kind = "rival",
				away = false
			})

	# Companies the world remembers from previous co-op sessions. These are players who are not
	# connected right now, which is exactly who a new joiner most likely wants to pick up.
	if models.has_model("coop-state"):
		var coop_state = models.get_model("coop-state")
		var remembered = []
		if coop_state.has_method("ids"):
			remembered = coop_state.ids()
		for player_id in remembered:
			var id = String(player_id)
			if id == own_id:
				continue
			if __has_candidate(out, id):
				continue
			var record = null
			if coop_state.has_method("get_player"):
				record = coop_state.get_player(player_id)
			if record == null or typeof(record) != TYPE_DICTIONARY:
				continue
			var offices = 0
			if record.has("studios") and typeof(record["studios"]) == TYPE_ARRAY:
				offices = record["studios"].size()
			elif record.has("offices") and typeof(record["offices"]) == TYPE_ARRAY:
				offices = record["offices"].size()
			elif record.has("studios") and typeof(record["studios"]) == TYPE_INT:
				# A count, not a list. Reading .size() off it is a native crash, not an error.
				offices = int(record["studios"])
			var away = true
			if record.has("present"):
				away = not bool(record["present"])
			out.push_back({
				id = id,
				name = String(record["name"]) if record.has("name") else id,
				offices = offices,
				currency = int(record["currency"]) if record.has("currency") else 0,
				fanbase = int(record["fanbase"]) if record.has("fanbase") else 0,
				kind = "player",
				away = away
			})

	return out


static func __has_candidate(entries, id):
	for entry in entries:
		if String(entry["id"]) == String(id):
			return true
	return false


static func __catalogue_data():
	# The dictionary the concurrent model itself reads. static_data.get_data("concurrent") is not the
	# same object at this point in a join, and writing a catalogue entry into that copy left the entry
	# invisible: names read back empty and no rival could be found by id.
	var model = models.get_model("concurrent")
	var holder = model.static_concurrent_data
	if holder.list == null:
		holder.list = {}
	return holder.list


# Makes a player's company exist as a real competitor, in the same order the game uses when it
# generates a rival (scripts/controllers/concurrent.gd::generate_new_concurrent):
#
#   1. the static catalogue entry, because create_concurrent() reads it for its log line and the
#      trading handler reads it for the stock count. A missing entry there is a null dereference,
#      which is what killed earlier attempts to create one from a network message.
#   2. create_concurrent(), which writes the live rival record.
#   3. buy_studio() per map tile, which is how a rival owns offices.
#   4. _emit_signal_concurrent_created(), exactly once, so the game's own handlers build the trading
#      data and UI rows for it.
#
# Doing it in this order is the difference between the competitor being visible everywhere the game
# shows rivals, and the company being an impostor in someone else's slot.
static func spawn(id, name, logo, fanbase, note, currency, tiles):
	var catalogue = __catalogue_data()

	var texture = logo
	if texture == null:
		texture = ImageTexture.new()
	elif typeof(texture) == TYPE_STRING:
		texture = pngloader_utils.base64_to_variant(texture)

	catalogue[id] = {
		name = name,
		logo = texture,
		engine = {royalties = [25, 35], interval = 108}
	}

	var concurrent = models.get_model("concurrent")
	concurrent._initialize_list()
	if __rival(id) == null:
		concurrent.create_concurrent(id, fanbase, note, currency)
	else:
		var entry = __rival(id)
		entry.fanbase = fanbase
		entry.note = note
		entry.currency = currency

	for tile_id in tiles:
		if not concurrent.is_studio_owned(String(tile_id)):
			concurrent.buy_studio(id, String(tile_id))
		__name_tile(String(tile_id), name)

	concurrent._emit_signal_concurrent_created(id)
	return true


# Makes the other players' companies exist on this machine, as real competitors.
#
# A player's company is created the way the game creates a rival (see spawn above), with the player's
# own id, name, logo, money and map tiles. It is not written into a rival that already existed, and no
# rival is ever renamed: that is what made one player's company wear another company's name and logo.
#
# Returns the ids handled, so the caller can log and prune.
static func apply(companies, log_name = "coop", logos = null, known_games = null):
	var concurrent = models.get_model("concurrent")
	var catalogue = __catalogue_data()
	concurrent._initialize_list()

	var ids = []
	for company in companies:
		var id = String(company.id)
		if is_acquired(id):
			# Bought out: it must not come back as a competitor just because the company table still
			# lists the player who used to own it.
			continue
		ids.push_back(id)

		var name = String(company.name)
		var fanbase = int(company.fanbase)
		var note = float(company.note)
		var currency = int(company.currency)
		var logo = __logo_for(company, id, catalogue, logos)

		if __rival(id) == null:
			spawn(id, name, logo, fanbase, note, currency, __tiles(company))
			var created = __rival(id)
			if created != null:
				# The static catalogue is not part of the world state, so a machine that receives this
				# competitor later cannot look its name up in it. The name travels on the record.
				created["coop_name"] = name
		else:
			var entry = __rival(id)
			entry.fanbase = fanbase
			entry.note = note
			entry.currency = currency
			entry["coop_name"] = name

		# The catalogue entry is written for a *newly spawned* rival as well as an updated one. It used
		# to be written only in the else branch, so the name of a company that appeared while this
		# machine was already playing never reached the catalogue - and the catalogue is what the rival
		# list reads its label from. With two players nobody noticed: the rival either existed already or
		# arrived with the world transfer. With three, the first client saw the third player's company
		# labelled with its raw id, "coop-underdog", while the host and the third player saw
		# "Underdog Studio". Caught by the verify suite the first time three players ran together.
		catalogue[id] = {
			name = name,
			logo = logo,
			engine = {royalties = [25, 35], interval = 108}
		}

		var offices = sync_studios(id, company, name)
		var games = sync_games(id, company, known_games)
		coop_log.info(log_name, "net: competitor %s is [%s] offices=%s games_sent=%s new_games=%s" % [
			id, name, String(offices),
			String(company["games"].size()) if company.has("games") and company["games"] != null else "0",
			String(games)
		])

	return ids


static func __tiles(company):
	var tiles = []
	if not company.has("offices") or company["offices"] == null:
		return tiles
	for office in company["offices"]:
		if office != null and office.has("t"):
			tiles.push_back(String(office["t"]))
	return tiles


# The player's released games, as this machine's releases for that competitor, so the other player's
# company has the same catalog instead of an empty one. Written straight into the rival catalog with
# the game's signal suppressed: the release handlers build UI rows and expect a game the game itself
# just generated.
static func sync_games(slot, company, known = null):
	if not company.has("games") or company["games"] == null:
		return 0
	var games = company["games"]
	var model = models.get_model("concurrent-game")
	var date = models.get_model("date").get_date()
	var added = 0
	var existing = model.get_concurrent_catalog(slot)["released"]

	for game in games:
		if game == null or not game.has("id"):
			continue
		var game_id = String(game["id"])
		if known != null:
			known[game_id] = true
		if existing.has(game_id):
			continue
		var name = game_id
		if game.has("name"):
			name = String(game["name"])
		var note = 0.0
		if game.has("note"):
			note = float(game["note"])
		var units = 0.0
		if game.has("units"):
			units = float(game["units"])
		var platform = ""
		if game.has("platform"):
			platform = String(game["platform"])
		# The platform id, because the sales pass needs it and cannot cope without one.
		#
		# `_compute_game_sale()` calls
		#   platform_model.get_unit_sold(game_published.platform_id)            -> get_platform_by_id(id).current_unit_sold
		#   platform_model.get_amount_of_games_released(...platform_id)         -> get_platform_by_id(id).has(...)
		# and neither checks for null, so an id this machine does not have is an instant 0xc0000005 at
		# 0xae5633. The record used to send "" here. The other player's id is used when this world has it;
		# otherwise the first platform this world can name, which is enough for the arithmetic to be real.
		var platform_id = ""
		if game.has("platform_id"):
			platform_id = String(game["platform_id"])
		if platform_id == "" or not __platform_known(platform_id):
			var substitute = __first_known_platform()
			if substitute != "":
				coop_log.info("coop", "net: [%s] arrived with platform id [%s] that this world does not "
					% [name, platform_id] + "know; using [%s]" % [substitute])
				platform_id = substitute
			elif platform_id == "":
				coop_log.warning("coop", "net: [%s] has no platform id and this world can name none, so its "
					% [name] + "sales cannot be simulated here")
		var released = date
		if game.has("date"):
			released = game["date"]

		# The theme the other player's game was made with must exist in THIS machine's trend table.
		#
		# `game_theme_model.get_trend_by_theme(name)` indexes `__trend_data[name]` without checking, and
		# `__trend_data` is per save - it holds the themes that save was created with, and nothing else.
		# An index that misses returns null, `_compute_game_sale()` reads `.trend` off that null, and the
		# process dies with 0xc0000005 at 0xae5633 on the first monthly sales pass.
		#
		# Sending no theme at all does not help: a record with `theme = ""` still looks up `__trend_data[""]`,
		# which can never exist. Observed as a released game crossing the wire and killing the receiving
		# machine one second later, four times - after a whole pass had assumed an empty theme "stays on
		# the neutral path", a path this build does not have. The fix is to substitute a theme the world
		# *does* know, so the arithmetic is real rather than skipped.
		var theme = ""
		var theme_label = ""
		if game.has("theme") and theme_known(String(game["theme"])):
			theme = String(game["theme"])
			theme_label = String(game["theme_label"]) if game.has("theme_label") else theme
		else:
			var fallback = __first_known_theme()
			if fallback != "":
				theme = fallback
				theme_label = fallback
				coop_log.info("coop", "net: [%s] arrived with theme [%s] that this world does not know; "
					% [name, String(game["theme"]) if game.has("theme") else ""]
					+ "using [%s] so the sales pass has a real trend" % [fallback])
		var types = []
		if game.has("types") and typeof(game["types"]) == TYPE_ARRAY:
			types = [] + game["types"]

		model.release_game(slot, {
			id = game_id,
			concurrent_id = slot,
			name = name,
			platform = platform,
			platform_id = platform_id,
			theme = theme,
			theme_label = theme_label,
			release_date = released,
			size = "",
			size_label = "",
			type_list = types,
			target = "",
			target_label = "",
			computed_note = note,
			cracked = false,
			cycle = 1,
			fanbase = 0.0,
			price = 0.0,
			income = 0.0,
			digitalstore = 0,
			last_unit_sold = 0.0,
			unit_sold_total = units,
			expected_unit_sold = units,
			engine_id = ""
		}, false)
		model.add_generated_game_id(slot, game_id)
		if game.has("state") and String(game["state"]) == "announced":
			# announce_game() reads game_data.id without checking (models/concurrent-game.gd), and
			# get_game_by_id() returns null when the catalog it just asked for is missing the entry.
			# Passing that null on is a null dereference inside the engine - the 0xc0000005 at
			# 0xae5633 that killed the host one second after the client's first project appeared.
			var announced = model.get_game_by_id(slot, game_id)
			if announced == null:
				coop_log.warning("coop", "games: %s reports %s as announced but the catalog has no such "
					% [slot, game_id] + "entry, not announcing it")
			else:
				model.announce_game(slot, announced, false)
		added += 1

	return added


# Puts the other player's studios onto this machine's map.
#
# Both machines boot the same map, so a studio's tile id identifies the same tile on both. The rival
# slot's studio list is authoritative for what that company owns, and the tile is renamed so the
# studio is recognisable on the map instead of a generic "Studio" label.
static func sync_studios(slot, company, company_name = ""):
	var concurrent = models.get_model("concurrent")
	var entry = __rival(slot)
	if entry == null:
		return 0

	var tiles = __tiles(company)
	var name = company_name
	if name == "":
		name = String(company.name)

	var kept = []
	var index = 0
	for tile_id in tiles:
		if not concurrent.is_studio_owned(tile_id):
			concurrent.buy_studio(slot, tile_id)
		index += 1
		# Same convention the game uses for its own rivals: "<Company> (#01)", so the map shows whose
		# office a building is rather than the name of whatever company used to hold that tile.
		__name_tile(tile_id, "%s (#%02d)" % [name, index])
		kept.push_back(tile_id)

	entry["studio"] = kept
	return kept.size()


static func __name_tile(tile_id, name):
	var tile = models.get_model("map").get_tile_by_id(tile_id)
	if tile == null or tile.metadata == null:
		return
	tile.metadata.name = name


# A player's company lives in a rival slot that already exists in the world, so it shows up in every
# company list without the game having to create anything. Slots are handed out by the host, which is
# the only machine that knows every player, and travel with the record.
static func prune(known_ids, keep_ids, log_name = "coop"):
	var concurrent = models.get_model("concurrent")
	var live = concurrent.get_concurrent()
	if live == null:
		return []

	# Deliberately nothing is erased: a player who leaves leaves their company behind as an ordinary
	# rival, which is what lets them take it over again when they come back.
	var removed = []
	for id in known_ids:
		if not keep_ids.has(id):
			removed.push_back(id)
	return removed


# Client: become the chosen company.
#
# Two ways to start, both needed:
#
#   new (or empty)  a company of the player's own. The client boots the host's world, so its company
#                   models were replaced with a captured fresh-game company before loading; all that
#                   is left is the identity and a first office on a real tile of the host's map.
#   <company id>    take over a company that already exists in the host's world. Its identity, money,
#                   prestige and fanbase become the player's, and it stops being an NPC on this
#                   machine. This is what lets a player continue: a company that survives in the
#                   world can be picked up again, either their own from last session or a rival's.
#
# The studio is created last, on an available map tile, because a studio id *is* a map tile id: a
# studio carried over from another game points at a tile that does not exist here, which put the map
# camera on a nil tile.
static func choose(choice, player_name):
	if not models.is_loaded():
		return "no game loaded"

	var player = models.get_model("player")
	var chosen = String(choice)

	if chosen == "" or chosen == "new":
		var label = String(player_name)
		if label == "":
			label = "Player"
		player.set("_company_name", label + " Studio")
		player.set("_player_name", label)
		player.set("_note", 0.0)
		player.set("_company_logo", null)

		models.get_model("currency").force_currency(STARTING_CURRENCY)
		models.get_model("fanbase").update_fanbase(0)

		return "started a new company, %s" % [open_first_studio(label)]

	var concurrent = models.get_model("concurrent")
	var competitor = __rival(chosen)
	if competitor == null:
		return "company %s is not in this world, nothing changed" % [chosen]

	var catalogue = models.get_model("concurrent").get_concurrent_data()
	var display = null
	if catalogue.has(chosen):
		display = catalogue[chosen]

	var name = chosen
	if display != null and display.has("name"):
		name = String(display["name"])
	elif competitor.has("coop_name"):
		# The catalogue is not part of the world, so a company that arrived from another machine
		# carries its own name on the record.
		name = String(competitor["coop_name"])
	player.set("_company_name", name)
	player.set("_player_name", name)
	player.set("_note", float(competitor.note))
	if display != null and display.has("logo") and typeof(display["logo"]) != TYPE_STRING:
		player.set("_company_logo", pngloader_utils.variant_to_base64(display["logo"]))
		player.set("company_logo_texture", display["logo"])

	models.get_model("currency").force_currency(int(competitor.currency))
	models.get_model("fanbase").update_fanbase(int(competitor.fanbase))

	# The offices are taken over through the game's own buyout, in full: the same call the game makes
	# when a player buys a competitor out. That is what gives the company real, furnished studios
	# (studio_generator.generate_competitor_studio builds the layout, the desks and the computers)
	# instead of empty tiles, and it is also what removes the competitor properly, staff, games,
	# platforms and all.
	var note = ""
	var controller = controllers.get_controller("concurrent")
	if controller != null and controller.has_method("_player_bought_concurrent_confirm"):
		controller.call("_player_bought_concurrent_confirm", chosen, true, true, true, true)
		note = "bought out through the game's own acquisition"
	else:
		# Fall back to the manual transplant, so a rename in a later build cannot leave a player with
		# no office at all.
		var released = release_studios(competitor)
		var live = concurrent.get_concurrent()
		if live != null and live.has(chosen):
			live.erase(chosen)
		if catalogue.has(chosen):
			catalogue.erase(chosen)
		concurrent.emit_signal("concurrent_removed", chosen, null, [])
		note = "%s tile(s) released by hand" % [String(released)]
		if count_player_studios() == 0:
			note = open_first_studio(name)

	return "took over %s (%s)" % [name, note]


# After a takeover, any employee still pointing at a studio that no longer exists is re-seated.
#
# The game's own acquisition (`_player_bought_concurrent_confirm`) hands over the rival's offices and
# their staff, but the offices it creates are new ids - so an employee whose `studio_id` was the old
# studio is left pointing at a room that no longer exists. Observed as
# `staff (developers:1), (orphans:[developer/3a74e8d0]), (seated_ok:True)` right after a lobby takeover:
# the person exists, has a desk nowhere, and their work goes nowhere.
static func reseat_after_takeover():
	if not models.is_loaded() or not models.has_model("staff"):
		return 0
	var seat = first_player_studio()
	if seat == "":
		coop_log.warning("coop", "takeover: no office of ours to seat anyone in")
		return 0
	# Only the employees whose room no longer exists are moved. __rebind_staff would skip them: it
	# compares against the seat, and an orphan's studio_id is a *stale* id, so it looks like a normal
	# assignment rather than a broken one.
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var staff = models.get_model("staff")
	var data = staff.get_data()
	var moved = 0
	for specialty in data.keys():
		var group = data[specialty]
		if group == null or typeof(group) != TYPE_DICTIONARY:
			continue
		for employee_id in group:
			var employee = group[employee_id]
			if employee == null or typeof(employee) != TYPE_DICTIONARY:
				continue
			if not employee.has("studio_id") or employee["studio_id"] == null:
				continue
			var current = String(employee["studio_id"])
			if studio_model.get_studio_by_id(current) != null and not concurrent.is_studio_owned(current):
				continue
			employee["studio_id"] = seat
			# The desk it sat at went with the old room, so its binding is dropped too; __ensure_workstation
			# below gives it a real one in the office it now belongs to.
			if employee.has("item_id"):
				employee["item_id"] = null
			moved += 1
	if moved > 0:
		__ensure_workstation(seat)
		coop_log.info("coop", "takeover: %s employee(s) moved out of a studio that no longer exists "
			% [String(moved)] + "into %s" % [seat.substr(0, 8)])
	return moved


# Applies the logo and specialisation a player picked in the lobby's company form.
#
# The form is the game's own, so its data has `company_logo` (base64) and `specialization` - the same
# keys `new-game/main.gd` puts into the player it creates. Nothing is invented here: a value that is
# absent is left alone rather than replaced with a default.
static func apply_logo(data):
	if data == null or typeof(data) != TYPE_DICTIONARY or not models.is_loaded():
		return false
	if not models.has_model("player"):
		return false
	var player = models.get_model("player")
	var applied = false
	if data.has("company_logo") and data["company_logo"] != null and String(data["company_logo"]) != "":
		var texture = pngloader_utils.base64_to_variant(String(data["company_logo"]))
		if texture != null:
			player.set("_company_logo", String(data["company_logo"]))
			player.set("company_logo_texture", texture)
			applied = true
	if data.has("company_name") and String(data["company_name"]) != "":
		player.set("_company_name", String(data["company_name"]))
		player.set("_player_name", String(data["company_name"]))
		applied = true
	return applied


# Sets the player's own company identity (name, prestige, logo) without touching the models that hold
# the company's progress, for the case where those already came from the captured fresh company.
static func name_self(player_name):
	var player = models.get_model("player")
	var label = String(player_name)
	if label == "":
		label = "Player"
	player.set("_company_name", label + " Studio")
	player.set("_player_name", label)
	player.set("_note", 0.0)
	player.set("_company_logo", null)
	return "named the company %s" % [label + " Studio"]


# Taking over a company means taking over its offices: its studio tiles become the player's own
# studios, entered in the studio model, which is what makes them the player's rather than unowned map
# tiles. Named after the company so the map reads correctly.
static func release_studios(competitor):
	if competitor == null or not competitor.has("studio") or competitor["studio"] == null:
		return 0
	var studio_model = models.get_model("studio")
	var date = models.get_model("date").get_date()
	var tiles = competitor["studio"]
	var released = 0
	for tile_id in tiles:
		if studio_model.get_studio_by_id(tile_id) != null:
			continue
		__name_tile(String(tile_id), String(competitor.id))
		var tile = models.get_model("map").get_tile_by_id(tile_id)
		var area = 20
		if tile != null and tile.metadata != null and tile.metadata.has("area"):
			area = tile.metadata.area
		var studio = studio_model.create_studio(String(competitor.id), area, tile_id, "buy", date)
		studio_model.open_studio(studio)
		released += 1
	competitor["studio"] = []
	return released


# What the player's own office actually contains, so a test can assert the things a new company needs:
# a desk, a computer on it, the player seated at it, and no other company owning the building.
static func my_home_office():
	var studio_model = models.get_model("studio")
	var item_model = models.get_model("item")
	var concurrent = models.get_model("concurrent")
	var data = studio_model.get_data()

	var result = {
		studio = "",
		desks = 0,
		computers = 0,
		seat = "",
		seated = false,
		owner = "",
		owned_elsewhere = false,
		building = "",
		home_building = false,
		bad_buildings = [],
		lot = false,
		homes = 0,
		shells = []
	}
	if not data.has("list") or data["list"] == null:
		return result

	var map = models.get_model("map")
	for studio_id in data["list"]:
		if concurrent.is_studio_owned(studio_id):
			# Another company's office: record the owner so a failure says who.
			result["owner"] = String(concurrent.get_owner_of_studio(studio_id)) \
				if concurrent.has_method("get_owner_of_studio") else "another company"
			result["owned_elsewhere"] = true
			continue
		var tile = map.get_tile_by_id(studio_id)
		var building = String(tile.tile) if tile != null else "missing"
		# Count the mod's own offices, so a regression where they pile up one per join is visible.
		var record = data["list"][studio_id]
		if record != null and record.has("name") and String(record["name"]) == HOME_STUDIO_NAME:
			result["homes"] += 1
		if building == "grass":
			# An office built on an empty lot: the tile should have become a studio building.
			result["lot"] = true
			result["bad_buildings"].push_back("%s is still an empty lot" % [String(studio_id).substr(0, 8)])
			continue
		if not is_home_building(building):
			# An office in a building nobody can work in: it must not be one of ours at all.
			result["bad_buildings"].push_back("%s is a %s" % [String(studio_id).substr(0, 8), building])
			continue
		# "The void": an office with no furniture at all. The player can open it and find nothing, and
		# nobody can work there, so it is reported whichever office it is.
		var items = studio_model.get_items(studio_id)
		if items == null or items.size() == 0:
			result["shells"].push_back("%s has no furniture" % [String(studio_id).substr(0, 8)])
		if result["studio"] != "":
			continue
		result["studio"] = String(studio_id)
		result["building"] = building
		result["home_building"] = true
		var items = studio_model.get_items(studio_id)
		if items == null:
			continue
		for item_id in items:
			var item = items[item_id]
			if item == null:
				continue
			var type = String(item_model.get_type(item))
			if type == "desk":
				result["desks"] += 1
				if item_model.get_computer(item) != null:
					result["computers"] += 1
				if item.has("employee_id") and item["employee_id"] != null:
					result["seat"] = String(item["employee_id"])
		if result["seat"] != "":
			result["seated"] = true
	return result


static func count_player_studios():
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var data = studio_model.get_data()
	var count = 0
	if data.has("list") and data["list"] != null:
		for studio_id in data["list"]:
			if not concurrent.is_studio_owned(studio_id):
				count += 1
	return count


# Hands the player the cheapest *empty* office on the host's map, the same way the game does when a
# player expands: create_studio + open_studio, with the tile's real price recorded. The controller
# path (studio_controller.rent) is avoided on purpose, because it plays a sound and a machine with no
# working audio device dies on that.
#
# "Empty" matters. An office that another company already owns, or that already holds someone's
# furniture, is not a home: taking it over would either evict a rival or drop the player into a
# building that already has desks. When no empty applicable building is left, a new one is built on an
# empty lot instead (see open_new_office).
static func open_first_studio(name, source = null):
	# Idempotent, and self-healing. This is called on every join, so the first thing to do is collapse
	# whatever the machine arrived with down to a single office - a player who joined six times used to
	# own six offices called "Home", most of them with a desk nobody could sit at.
	ensure_single_home(name)

	var existing = adopt_existing_office(name)
	if existing != "":
		log_studios("kept the office already held")
		return existing

	var tile = find_empty_office()
	if tile == null:
		coop_log.warning("coop", "office: no empty building left, building a new one")
		return open_new_office(name, source)
	return furnish_first_office(name, tile, source)


# Collapses the mod's own "Home" offices down to one, and nothing else.
#
# This runs on every join because the count only ever grew. The game opens a first studio of its own
# when the studio model is empty (controllers/studio.gd _create_first_studio), the mod then opened its
# own office on top, and the world saved the result - so each join left one more "Home" behind that
# nobody sat in. A dump of a client after a few joins showed six offices named "Home" (gym, gym, studio,
# cafe, apartment, apartment), five with a desk nobody could sit at, since there is only one player.
# The host had the same debris next to its real studios.
#
# Only offices the mod created are touched. They are the ones whose studio is called "Home" - a real
# studio carries the name the player gave it - so a company's genuine offices are never closed by this.
# The one kept is the workable one; if none is workable, the first, and the caller furnishes it.
static func ensure_single_home(name = ""):
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var map = models.get_model("map")
	var data = studio_model.get_data()
	if not data.has("list") or data["list"] == null:
		return 0

	var homes = []
	var workable = ""
	for studio_id in data["list"]:
		var id = String(studio_id)
		if concurrent.is_studio_owned(id):
			continue
		var studio = data["list"][studio_id]
		if studio == null or not studio.has("name") or String(studio["name"]) != HOME_STUDIO_NAME:
			continue
		var tile = map.get_tile_by_id(id)
		if tile != null and not is_home_building(String(tile.tile)):
			# Not a home at all: closed below with the rest.
			homes.push_back(id)
			continue
		homes.push_back(id)
		if workable == "" and has_workstation(id):
			workable = id
	if homes.size() <= 1:
		return 0

	var keep = workable
	if keep == "":
		keep = homes[0]

	var closed = 0
	for id in homes:
		if id == keep:
			continue
		__close_unfit_office(id)
		closed += 1
	if closed > 0:
		coop_log.info("coop", "office: closed %s duplicate home office(s), kept %s" % [
			String(closed), keep.substr(0, 8)
		])
		if name != "":
			__name_tile(keep, String(name) + " (Home)")
	log_studios("after collapsing duplicate homes")
	return closed


# How many of the mod's own "Home" offices this company holds.
# What this company's staff look like from the models the employee screens read: how many developers
# there are, and whether anybody is assigned to an office that no longer exists (the "0 developers"
# symptom, where the staff are all still in the model but pointing at a closed room).
static func my_staff_summary():
	var result = {
		developers = 0,
		total = 0,
		orphans = [],
		seated_ok = true
	}
	if not models.has_model("staff") or not models.has_model("studio"):
		return result
	var staff = models.get_model("staff")
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var data = staff.get_data()

	for specialty in data.keys():
		var group = data[specialty]
		if group == null or typeof(group) != TYPE_DICTIONARY:
			continue
		for employee_id in group:
			var employee = group[employee_id]
			if employee == null or typeof(employee) != TYPE_DICTIONARY:
				continue
			result["total"] += 1
			if specialty == "developer":
				result["developers"] += 1
			if not employee.has("studio_id") or employee["studio_id"] == null:
				# Not assigned anywhere: not an orphan, just unhired.
				continue
			var studio_id = String(employee["studio_id"])
			if studio_model.get_studio_by_id(studio_id) == null or concurrent.is_studio_owned(studio_id):
				result["orphans"].push_back("%s/%s" % [specialty, studio_id.substr(0, 8)])
			# And the desk that employee sits at must exist in that room.
			if employee.has("item_id") and employee["item_id"] != null:
				var item = studio_model.get_item_by_id(studio_id, String(employee["item_id"]))
				if item == null:
					result["seated_ok"] = false
	return result


static func home_office_count():
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var data = studio_model.get_data()
	if not data.has("list") or data["list"] == null:
		return 0
	var count = 0
	for studio_id in data["list"]:
		if concurrent.is_studio_owned(studio_id):
			continue
		var record = data["list"][studio_id]
		if record != null and record.has("name") and String(record["name"]) == HOME_STUDIO_NAME:
			count += 1
	return count


# A desk with a computer on it and somebody sitting there: what makes an office workable.
# Platforms another company owns that this machine's digital store still sells on, by name. A non-empty
# answer is the "client sees the host's console customers" bug.
static func foreign_consoles_supported():
	var names = []
	if not models.has_model("digital-store") or not models.has_model("concurrent-platform"):
		return names
	var store = models.get_model("digital-store")
	var rivals = models.get_model("concurrent-platform")
	for platform in rivals.list_platform_released():
		if platform == null or not platform.has("id"):
			continue
		var entry = store.get_platform_if_exists(String(platform["id"]))
		if entry != null and entry.has("supported") and entry["supported"]:
			names.push_back(String(platform.name) if platform.has("name") else String(platform["id"]))
	return names


# Server users that did not come from this company's own sales: any online players while this company
# has published nothing on a platform of its own is the symptom of another player's console feeding it.
static func foreign_server_users():
	if not models.has_model("server"):
		return 0
	var server = models.get_model("server")
	# Only meaningful when this company owns no console: then all of its users must be its own doing.
	if my_consoles().size() > 0:
		return 0
	return int(server.get_online_players())


# Takes a console that belongs to somebody else out of this machine's own console model.
#
# The player's own consoles live in `custom-platform`, and the digital store treats anything found there
# as a platform this company may publish on and therefore earns customers on. Another company's console
# appearing there is how the client ended up with the host's console customers and server load, so it is
# removed from that model and left where it belongs: concurrent-platform.
static func __detach_from_own_platforms(platform_id):
	if not models.has_model("custom-platform"):
		return false
	var model = models.get_model("custom-platform")
	var data = model.get_data()
	var removed = 0
	for bucket in ["released", "discontinued", "announced"]:
		if not data.has(bucket) or data[bucket] == null:
			continue
		if typeof(data[bucket]) != TYPE_DICTIONARY:
			continue
		if not data[bucket].has(platform_id):
			continue
		data[bucket].erase(platform_id)
		removed += 1
	if removed > 0:
		coop_log.info("coop", "net: console %s removed from this company's own platforms (%s bucket(s))"
			% [platform_id.substr(0, 8), String(removed)])
	return removed > 0


static func has_workstation(studio_id):
	var studio_model = models.get_model("studio")
	var item_model = models.get_model("item")
	var items = studio_model.get_items(studio_id)
	if items == null:
		return false
	for item_id in items:
		var item = items[item_id]
		if item == null:
			continue
		if String(item_model.get_type(item)) != "desk":
			continue
		if item_model.get_computer(item) == null:
			continue
		if item.has("employee_id") and item["employee_id"] != null:
			return true
	return false


# Picks which of the offices this player already holds to keep, and drops the ones that are not fit to
# work in. Returns the kept office's description, or "" when nothing usable was found.
#
# This is the case that was wrong: a client arriving with an office in a building that is not a home,
# or with a big empty room, ended up with no desk, no computer and no worker, and - once a second
# office was opened beside it - with two offices where one was expected.
static func adopt_existing_office(name):
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var map = models.get_model("map")
	var data = studio_model.get_data()
	if not data.has("list") or data["list"] == null:
		return ""

	var usable = []
	var unusable = []
	for studio_id in data["list"]:
		var id = String(studio_id)
		if concurrent.is_studio_owned(id):
			# Another company's office: never this player's to keep.
			continue
		var tile = map.get_tile_by_id(id)
		var why = ""
		if tile == null:
			why = "its tile is not on this map"
		elif not is_home_building(String(tile.tile)):
			why = "it is a %s, not a home" % [String(tile.tile)]
		elif tile.metadata != null and tile.metadata.has("owned") and tile.metadata["owned"]:
			why = "another company owns the building"
		if why == "":
			usable.push_back(id)
		else:
			unusable.push_back({id = id, why = why})

	# The cheapest usable one, so a player is not handed a location they could never have afforded.
	var keep = ""
	if usable.size() > 0:
		keep = usable[0]

	if keep == "":
		for entry in unusable:
			coop_log.info("coop", "office: dropping %s because %s" % [entry["id"].substr(0, 8), entry["why"]])
			__close_unfit_office(entry["id"])
		return ""

	for entry in unusable:
		coop_log.info("coop", "office: dropping %s because %s" % [entry["id"].substr(0, 8), entry["why"]])
		__close_unfit_office(entry["id"])
	for id in usable:
		if id != keep:
			coop_log.info("coop", "office: dropping %s, one home is enough" % [id.substr(0, 8)])
			__close_unfit_office(id)

	var tile = map.get_tile_by_id(keep)
	__stock_first_office(keep, tile)
	studio_model.set_studio_price(keep, __tile_price(keep))
	__name_tile(keep, String(name) + " (Home)")
	return "kept the office the game opened on tile %s" % [keep]


# Drops an office that is not fit to work in, so a replacement does not leave the player owning two -
# one usable and one not. Its staff are detached and the tile goes back to an empty lot.
static func __close_unfit_office(tile_id):
	var studio_model = models.get_model("studio")
	var studio_model_data = studio_model.get_data()
	var had_items = 0
	if studio_model_data.has("list") and studio_model_data["list"] != null \
			and studio_model_data["list"].has(tile_id):
		var record = studio_model_data["list"][tile_id]
		if record != null and record.has("items") and record["items"] != null:
			had_items = record["items"].size()
		studio_model_data["list"].erase(tile_id)
	if studio_model.has_method("close_studio"):
		studio_model.close_studio(tile_id)
	# Anybody who was working in this room has to land somewhere that still exists, or the player ends up
	# with employees pointing at a room that is gone - which reads as "0 developers".
	var seat = first_player_studio()
	if seat != "" and seat != tile_id:
		__rebind_staff_from(tile_id, seat)
	var tile = models.get_model("map").get_tile_by_id(tile_id)
	if tile != null:
		if tile.metadata == null:
			tile.metadata = {}
		# The building goes back to being an ordinary empty building. Leaving the name and the ownership
		# flags behind is what made a closed office keep showing up on the map as a studio with nothing
		# in it: an empty room the player could click and find void.
		tile.metadata["owned"] = false
		if tile.metadata.has("name"):
			tile.metadata.erase("name")
		# Any rival claim on the tile goes too, or the tile reads as somebody's office for ever.
		var concurrent = models.get_model("concurrent")
		if concurrent != null and concurrent.is_studio_owned(tile_id):
			for rival_id in concurrent.get_concurrent().keys():
				var rival = concurrent.get_concurrent()[rival_id]
				if rival != null and rival.has("studio") and rival["studio"] != null \
						and rival["studio"].has(tile_id):
					rival["studio"].erase(tile_id)
	coop_log.info("coop", "office: closed the office on tile %s (%s item(s) discarded)" % [
		tile_id.substr(0, 8), String(had_items)
	])


# The building types the game itself allows a company's first office in
# (controllers/studio.gd: _get_tile_for_first_studio), plus the purpose-built ones.
const HOME_BUILDING_TYPES = ["apartment", "office", "studio", "bigstudio", "cafe", "tower", "gym",
	"hotel", "restaurant"]
const HOME_BUILDINGS = HOME_BUILDING_TYPES


static func is_home_building(type):
	return HOME_BUILDINGS.has(String(type))


# The tile id of a studio this player already holds, or "" when there is none yet. Another company's
# office is not this player's, so it is skipped.
static func first_player_studio():
	if not models.has_model("studio"):
		return ""
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var data = studio_model.get_data()
	if not data.has("list") or data["list"] == null:
		return ""
	for studio_id in data["list"]:
		if not concurrent.is_studio_owned(studio_id):
			return String(studio_id)
	return ""


static func __tile_price(tile_id):
	var map_controller = controllers.get_controller("map")
	var tile = models.get_model("map").get_tile_by_id(tile_id)
	if map_controller == null or tile == null:
		return 0.0
	return float(map_controller.get_tile_price(tile))


# The cheapest building that is genuinely empty and suitable to be someone's home: a studio-sized tile
# no company owns, that holds no furniture, that is not the tile of any rival's office. The game's own
# first studio picks the first "apartment"/"office"/"cafe"... tile it finds; the same building types are
# used here, and "studio"/"bigstudio" are included because those are purpose-built offices.
static func find_empty_office():
	var map = models.get_model("map")
	var concurrent = models.get_model("concurrent")
	var studio_model = models.get_model("studio")
	var map_controller = controllers.get_controller("map")

	var candidates = []
	for type in HOME_BUILDINGS:
		for tile in map.get_tile_type(type):
			if tile == null:
				continue
			var tile_id = String(tile.id)
			# Somebody's office already, on the model or on the map.
			if studio_model.get_studio_by_id(tile_id) != null:
				continue
			if concurrent.is_studio_owned(tile_id):
				continue
			if tile.metadata == null:
				tile.metadata = {}
			# The map marks a building that a company has built as belonging to it.
			if tile.metadata.has("owned") and tile.metadata["owned"]:
				continue
			candidates.push_back(tile)

	if candidates.size() == 0:
		return null

	var cheapest = null
	var cheapest_price = 0.0
	for tile in candidates:
		var price = 0.0
		if map_controller != null:
			price = float(map_controller.get_tile_price(tile))
		if cheapest == null or price < cheapest_price:
			cheapest = tile
			cheapest_price = price
	return cheapest


# The player's own first office, on a real tile of this world.
#
# This mirrors the game's own _create_first_studio (controllers/studio.gd): a desk, the player
# themselves as the admin sitting at it, a computer on the desk, and the default furniture. That is
# what makes a new company playable - without a desk with a computer, the player has no chair to be
# seated in and no workstation, so no game can be developed.
static func furnish_first_office(name, tile, source = null):
	var studio_model = models.get_model("studio")
	var map_controller = controllers.get_controller("map")
	var existing = studio_model.get_studio_by_id(String(tile.id))
	if existing != null:
		return "tile %s already has an office" % [String(tile.id)]

	var price = 0.0
	if map_controller != null:
		price = float(map_controller.get_tile_price(tile))

	if tile.metadata == null:
		tile.metadata = {}
	var area = 20
	if tile.metadata.has("area"):
		area = int(tile.metadata.area)
	elif source != null and source.has("area"):
		area = int(source["area"])
	tile.metadata.area = area

	var date = models.get_model("date").get_date()
	var studio = studio_model.create_studio("Home", area, tile.id, "buy", date)

	# A company created in the game's own New Game dialogue brings its studio with it: the furniture
	# and the build options are what the player chose and paid for, so they move to this world's tile.
	var captured = {}
	if source != null and source.has("items") and source["items"] != null and source["items"].size() > 0:
		captured = source["items"]
	if source != null and source.has("buildMod") and source["buildMod"] != null:
		studio["buildMod"] = source["buildMod"]
	if source != null and source.has("productivity"):
		studio["productivity"] = source["productivity"]
	if source != null and source.has("happiness"):
		studio["happiness"] = source["happiness"]

	studio_model.open_studio(studio, false)
	studio_model.set_studio_price(tile.id, price)

	if captured.size() > 0:
		# A captured layout already has the desks, the computer and the admin's seat in it.
		studio["items"] = __own_items(captured)
	else:
		__stock_first_office(studio.id, tile)

	# The studio list builds a row per studio and then reads the selected one, so a fresh company with
	# studios but no selection leaves that panel indexing null.
	if studio_model.has_method("select_studio"):
		studio_model.select_studio(studio.id)
	__name_tile(String(tile.id), String(name) + " (Home)")
	log_studios("after first office")
	return "first office on tile %s for %s" % [String(tile.id), String(price)]


# Every studio this machine holds, with the things that decide whether it is usable: the tile type,
# whether another company owns it, and how much furniture it has. Logged whenever an office is created
# or found, so "the client ended up with two offices" can be explained instead of guessed at.
static func log_studios(reason):
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var map = models.get_model("map")
	var data = studio_model.get_data()
	var parts = []
	if data.has("list") and data["list"] != null:
		for studio_id in data["list"]:
			var studio = data["list"][studio_id]
			var tile = map.get_tile_by_id(studio_id)
			var items = 0
			if studio != null and studio.has("items") and studio["items"] != null:
				items = studio["items"].size()
			parts.push_back("%s[%s tile=%s owned_by_rival=%s items=%s]" % [
				String(studio_id).substr(0, 8),
				String(studio["name"]) if studio != null and studio.has("name") else "?",
				String(tile.tile) if tile != null else "missing",
				String(concurrent.is_studio_owned(studio_id)),
				String(items)
			])
	coop_log.info("coop", "studios %s: %s" % [reason, join(parts, ", ")])


# The furniture a brand-new company starts with, copied from the game's own first-studio routine
# (controllers/studio.gd: DEFAULT_ITEMS + a desk + the admin + a computer).
const HOME_ITEMS = [
	{id = "22", position = Vector2(-132, 114), rotation = 1},   # metal desk
	{id = "30", position = Vector2(-34, -20), rotation = 1},    # wood bookshelf
	{id = "16", position = Vector2(202, 117), rotation = 1},    # plant
	{id = "19", position = Vector2(-157, 208), rotation = 1}    # wastebasket
]


static func __stock_first_office(studio_id, tile):
	var added = __add_default_items(studio_id)
	__ensure_workstation(studio_id)
	return added


# A desk with a computer on it and the player seated there. Everything a company needs before it can
# develop anything, added only where it is missing - so this works for a brand-new office, an office
# restored from an older save, and an office whose furniture was cleared.
static func __ensure_workstation(studio_id):
	var item_model = models.get_model("item")
	var studio_model = models.get_model("studio")
	var date = models.get_model("date").get_date()

	var desk = __first_item_of_type(studio_id, "desk")
	if desk == null:
		desk = __make_item("22", item_model)
		if desk == null:
			return false
		item_model.set_position(desk, Vector2(-132, 114))
		desk["rotation_index"] = 1
		studio_model.add_item(studio_id, desk, false)

	var computers = item_model.list_available_computers(date)
	if computers != null and computers.size() > 0 and item_model.get_computer(desk) == null:
		desk["computer_id"] = String(computers[0].id)

	var admin = __admin()
	if admin == null:
		# The company has nobody: without a worker the office cannot develop anything, which is what a
		# player sees as "a desk but no me". create_admin() is the game's own path and hires the player.
		var staff_controller = controllers.get_controller("staff")
		coop_log.info("coop", "office: no admin found, staff controller=%s create_admin=%s" % [
			String(staff_controller != null),
			String(staff_controller.has_method("create_admin")) if staff_controller != null else "n/a"
		])
		if staff_controller != null and staff_controller.has_method("create_admin"):
			staff_controller.call("create_admin")
			admin = __admin()
			coop_log.info("coop", "office: after create_admin, admin=%s" % [String(admin != null)])
	if admin != null:
		if not desk.has("employee_id") or desk["employee_id"] == null:
			desk["employee_id"] = String(admin.id)
		# Both directions of the binding have to be set: the desk points at the worker, and the worker
		# points back at the desk and the room. Setting only one leaves the UI showing an empty office.
		if models.has_model("employee"):
			var employee_model = models.get_model("employee")
			employee_model.set_studio_id(admin, studio_id)
			employee_model.attach_item(admin, String(desk["id"]))
		studio_model.set_staff(studio_id)
	return true


static func __add_default_items(studio_id):
	if not models.has_model("item"):
		return 0
	var item_model = models.get_model("item")
	var studio_model = models.get_model("studio")
	var present = {}
	var items = studio_model.get_items(studio_id)
	if items != null:
		for item_id in items:
			if items[item_id] != null:
				present[String(item_model.get_type(items[item_id]))] = true
	var added = 0
	for spec in HOME_ITEMS:
		# Only what the room does not already have: the game furnishes its own first studio, and adding
		# a second desk beside that one leaves the player with furniture they did not buy.
		var template = __template_of(spec["id"], item_model)
		if template == null or present.has(String(template.type)):
			continue
		var item = __make_item(spec["id"], item_model)
		if item == null:
			continue
		item_model.set_position(item, spec["position"])
		item["rotation_index"] = spec["rotation"]
		studio_model.add_item(studio_id, item, false)
		present[String(template.type)] = true
		added += 1
	return added


static func __template_of(item_id, item_model):
	for item in item_model.get_items().values():
		if String(item.id) == String(item_id):
			return item
	return null


static func __make_item(item_id, item_model):
	var template = __template_of(item_id, item_model)
	if template == null:
		return null
	return {
		id = "coop-item-%s-%s" % [String(OS.get_ticks_msec()), String(randi())],
		item_id = String(item_id),
		bought = true,
		rotation_index = template.rotation_index,
		durability = template.durability,
		employee_id = null,
		collision = template.collision,
		position = [0.0, 0.0]
	}


static func __first_item_of_type(studio_id, type):
	var item_model = models.get_model("item")
	var studio_model = models.get_model("studio")
	var items = studio_model.get_items(studio_id)
	if items == null:
		return null
	for item_id in items:
		var item = items[item_id]
		if item == null:
			continue
		if String(item_model.get_type(item)) == type:
			return item
	return null


# The player's own employee record, created through the game's own hire path if the world has none.
static func __admin():
	if not models.has_model("staff"):
		return null
	var staff = models.get_model("staff")
	var admin = staff.get_admin()
	if admin != null:
		return admin
	var staff_controller = controllers.get_controller("staff")
	if staff_controller == null or not staff_controller.has_method("create_admin"):
		return null
	staff_controller.call("create_admin")
	return staff.get_admin()


# No empty building left on the map: buy an empty lot and put an office on it, which is what the
# game's own build flow does (map_controller.update_tile + building_controller.build).
#
# The controller path is not used directly because it ends in a UI sprite swap and a sound; the same
# model changes are made here instead.
static func open_new_office(name, source = null):
	var tile = __empty_lot()
	if tile == null:
		return "no empty lot left on this map, the player owns no studio"
	return __build_office(name, tile, source)


static func __empty_lot():
	var map = models.get_model("map")
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var cheapest = null
	var cheapest_price = 0.0
	for tile in map.get_tile_type("grass"):
		if tile == null:
			continue
		var tile_id = String(tile.id)
		if studio_model.get_studio_by_id(tile_id) != null or concurrent.is_studio_owned(tile_id):
			continue
		var price = 0.0
		if tile.metadata != null and tile.metadata.has("actions") and tile.metadata["actions"].has("buy"):
			price = float(tile.metadata["actions"]["buy"])
		if cheapest == null or price < cheapest_price:
			cheapest = tile
			cheapest_price = price
	return cheapest


# Turns an empty lot into a studio building, the way the game's construct screen does: the tile becomes
# a "studio" with the size, area and price written into its metadata, and the studio model gets the
# office that goes with it.
static func __build_office(name, tile, source = null):
	var map = models.get_model("map")
	var studio_model = models.get_model("studio")
	var date = models.get_model("date").get_date()

	var tile_id = String(tile.id)
	var area = 20
	if source != null and source.has("area"):
		area = int(source["area"])
	var price = 0.0
	if tile.metadata != null and tile.metadata.has("actions") and tile.metadata["actions"].has("buy"):
		price = float(tile.metadata["actions"]["buy"])

	var option = {}
	if tile.has("option") and tile["option"] != null and typeof(tile["option"]) == TYPE_DICTIONARY:
		option = tile["option"]
	option["size"] = 1

	tile["tile"] = "studio"
	tile["option"] = option
	if tile.metadata == null:
		tile.metadata = {}
	tile.metadata["area"] = area
	if not tile.metadata.has("actions"):
		tile.metadata["actions"] = {}
	tile.metadata["actions"]["buy"] = price
	tile.metadata["actions"]["rent"] = price / 8649.45
	map.set_map_tile(int(tile.row), int(tile.column), tile)

	return furnish_first_office(name, tile, source)



static func join(parts, separator):
	var text = ""
	var index = 0
	while index < parts.size():
		if index > 0:
			text += separator
		text += parts[index]
		index += 1
	return text
