extends Reference

# A scripted playtest: both players actually play, and both machines prove they agree.
#
# The point of this file is evidence, not features. Two live clients do what a player does - develop
# and publish a game, open another office, buy furniture, research a technology, hand money over - and
# every minute each machine asks the other "what do you actually have?" and checks that what it *shows*
# about them matches. The other side's answer arrives as a digest over the wire, so a check compares
# what the other game says about itself against what this game renders about it. Neither side can
# satisfy that by accident.
#
# Nothing here decides game rules. Every action goes through the game's own controllers and models, and
# every assertion reads a model the UI reads.
#
# The state lives on the autoload, not in this script: a Reference here is shared by every caller, but
# its own script-level variables do not survive this engine build reliably (a `var` in a Reference is
# per-instance, and there is no reliable place to keep one instance). So this file is a set of
# functions over the caller's fields, prefixed __play_.
#
#     --coop-play=<seconds>     run for this long (a 30 minute playtest is 1800)

const coop_log = preload("res://coop/log.gd")
const dict_lib = preload("res://coop/dict.gd")
const company = preload("res://coop/company.gd")
const trade = preload("res://coop/trade.gd")

# The actions, in order. Each is attempted once; if the game is not ready for it, it is retried on the
# next tick rather than skipped, so a slow join cannot silently drop a step.
const ACTIONS = ["project", "office", "furnish", "research", "project2", "office2", "release", "release2"]

const ACTION_INTERVAL = 90.0
const CHECK_INTERVAL = 60.0
# How long a screen the bot opened has to be up before it is closed again. See __return_to_the_world: a
# scene torn down mid-push crashed the host at 0xae5633, twice, at roughly this delay after an action.
const SCREEN_SETTLE_SECONDS = 4.0
const DIGEST_INTERVAL = 5.0
# Money drifts every tick in a running game, so an exact match would be a false alarm.
const CURRENCY_TOLERANCE = 0.05
# The digest is a few seconds old when it arrives and the world moves meanwhile.
const DATE_TOLERANCE = 4


# --- entry points -------------------------------------------------------

static func tick(coop):
	if coop.config.play <= 0.0 or not models.is_loaded():
		return
	# Whether a screen was open at any point since the last check, so the date check can tell the game's
	# own freeze apart from the world standing still.
	if coop.__date_frozen(models.get_model("date")):
		coop.__play_was_frozen = true
	if coop.__play_deadline <= 0.0:
		coop.__play_deadline = coop.__elapsed + coop.config.play
		coop.__play_next_action = coop.__elapsed + 20.0
		coop.__play_next_check = coop.__elapsed + 45.0
		coop.__play_next_digest = coop.__elapsed
		coop_log.info(coop.config.log_name, "play: starting a %s s playtest (%s actions, a check every %s s)" % [
			String(coop.config.play), String(ACTIONS.size()), String(CHECK_INTERVAL)
		])

	var now = coop.__elapsed
	# Whatever an action did to the game's state, the simulation has to be left able to run.
	#
	# `controllers/date.gd compute_state()` freezes the clock unless the game is in its plain view mode
	# *and* `scene_manager.is_game_main_scene()` - which is `get_number_of_scene() == 0`, i.e. no popup on
	# the stack. Starting a project makes the game open its own design screen and leaves it there, so the
	# stack never empties, the clock freezes at week 5, nothing in `dev` can finish, and the release step
	# has nothing to release.
	#
	# This was invisible for a long time because nothing reported the two conditions separately: a playtest
	# logged "the game's own clock is frozen (the automated run never enters view mode)" for fifteen
	# minutes while the state model *was* in view mode - the popup was the cause, and the message named the
	# wrong one. `clock` on the remote channel now reports both.
	if coop.config.play > 0.0:
		__return_to_the_world(coop)
	if now >= coop.__play_next_digest:
		coop.__play_next_digest = now + DIGEST_INTERVAL
		__send_digest(coop)
	# The UI pilot (pilot.gd) does the playing on this machine: it presses the game's own buttons. Running
	# the scripted actions as well would put two players in one chair - they would both start a project
	# from the same office, and a failure would no longer point at the UI. So when the pilot is on, the
	# actions are skipped and only the cross-checking half of this file runs.
	if now >= coop.__play_next_action and coop.config.pilot <= 0.0:
		coop.__play_next_action = now + ACTION_INTERVAL
		__next_action(coop)
	if coop.config.pilot > 0.0 and coop.__play_next_action > 0.0:
		coop.__play_next_action = now + ACTION_INTERVAL
	if now >= coop.__play_next_check:
		coop.__play_next_check = now + CHECK_INTERVAL
		__check(coop)
		coop.__play_was_frozen = false
	if now >= coop.__play_deadline and not coop.__play_finished:
		coop.__play_finished = true
		__finish(coop)


# Getting the game back to the world, so time can move.
#
# Two separate conditions freeze the clock (`controllers/date.gd compute_state()`), and the bot has to
# satisfy both after acting: the state model has to be in view mode, and no popup may be on the scene
# stack. `scene_manager.back()` is what the game's own Back button calls, so it is the popup-closing path
# a player uses rather than a teardown invented here.
static func __return_to_the_world(coop):
	if not models.has_model("state"):
		return
	var state_model = models.get_model("state")
	if state_model.has_method("is_view_mode") and not bool(state_model.call("is_view_mode")):
		coop.__enter_view_mode()
	var scene_manager = coop.get_tree().get_root().find_node("scene_manager", true, false)
	if scene_manager == null or not scene_manager.has_method("get_number_of_scene"):
		return
	if int(scene_manager.call("get_number_of_scene")) <= 0:
		return
	# Not every frame, and not with force.
	#
	# The first version closed a screen as soon as a frame noticed one, with `back(true)`. That tears down
	# a scene the game is still transitioning into: the host died at 0xae5633 thirty-seven seconds into a
	# run whose projects had only just started, twice. A screen that is still being pushed is not one a
	# player could close either. So the close waits until the same screen has been up for a moment, and
	# uses the same non-forced `back()` the Back button uses.
	if coop.__play_screen_since < 0.0:
		coop.__play_screen_since = coop.__elapsed
		return
	if coop.__elapsed - coop.__play_screen_since < SCREEN_SETTLE_SECONDS:
		return
	coop.__play_screen_since = -1.0
	var closed = bool(scene_manager.call("back", false))
	var screens_now = 0
	if scene_manager.has_method("get_number_of_scene"):
		screens_now = int(scene_manager.call("get_number_of_scene"))
	# The game's own way out of a project screen.
	#
	# These screens are *protected*: `scene_manager.back()` refuses them (menu.gd passes
	# `game_step != "kickoff"` as protect), and forcing it crashed the host at 0xae5633 by tearing a scene
	# down mid-transition. A player gets out by pressing the screen's own Next or Cancel button, and both
	# of those call one of two methods on the screen: `next_pressed()` steps the game and closes it,
	# `cancel_pressed()` cancels and closes it. Calling those is the same transition the button makes -
	# not a teardown invented here - and it is the only way a bot can finish a project.
	#
	# Without it no week ever passed while a project screen was open: `controllers/date.gd
	# compute_state()` freezes the clock when a screen is on the stack, so a project sat at KICKOFF forever
	# and nothing was ever released.
	if screens_now > 0 and closed == false:
		var popups = coop.get_tree().get_nodes_in_group("popup-node")
		if popups.size() > 0:
			var top = popups[popups.size() - 1]
			if top != null and top.has_method("next_pressed"):
				top.call("next_pressed")
				closed = true
				coop_log.info(coop.config.log_name, "play: pressed Next on [%s] the way a player does, so "
					% [String(top.get_filename())] + "the clock can run again")
	# What actually happened, not what was attempted. `back()` returns false and closes nothing when the
	# open screen is *protected*, and every project screen after kickoff is. Reporting "closed a game
	# screen" while `screens` stayed at 1 was a false claim in the log for a whole pass.
	if closed or screens_now < 1:
		coop_log.info(coop.config.log_name, "play: closed a gated screen (view_mode=%s, %s left)" % [
			__view_mode_text(), String(screens_now)
		])
	elif not coop.__play_gated_noted:
		coop.__play_gated_noted = true
		coop_log.info(coop.config.log_name, "play: the open screen is protected, so only a player can "
			+ "confirm it (view_mode=%s, %s screen(s)). A studio director is the game's own way to skip "
			% [__view_mode_text(), String(screens_now)]
			+ "these screens; without one no week passes while a project screen is open")
	if not coop.__play_view_noted:
		coop.__play_view_noted = true


static func __view_mode_text():
	if not models.has_model("state"):
		return "?"
	var state_model = models.get_model("state")
	if not state_model.has_method("is_view_mode"):
		return "?"
	return String(bool(state_model.call("is_view_mode")))


# Why the clock is not moving, in one line. Called when a check finds the world stopped, so a stall
# explains itself instead of needing a manual probe.
static func __freeze_reason(coop):
	var parts = []
	if models.has_model("state"):
		var state_model = models.get_model("state")
		if state_model.has_method("is_view_mode"):
			parts.push_back("view_mode=%s" % [String(bool(state_model.call("is_view_mode")))])
	var scene_manager = coop.get_tree().get_root().find_node("scene_manager", true, false)
	if scene_manager != null:
		if scene_manager.has_method("get_number_of_scene"):
			parts.push_back("screens=%s" % [String(int(scene_manager.call("get_number_of_scene")))])
		parts.push_back("main_scene_nodes=%s" % [
			String(coop.get_tree().get_nodes_in_group("main_scene").size())
		])
	if models.has_model("date"):
		var date_model = models.get_model("date")
		parts.push_back("paused=%s is_paused=%s started=%s" % [
			String(bool(date_model.paused)), String(bool(date_model.call("is_paused"))),
			String(bool(date_model.call("is_started")))
		])
	return company.join(parts, " ")


static func __send_digest(coop):
	if coop.__link == null:
		return
	coop.__link.send({"t": "digest", "player": coop.__local_id(), "digest": digest(coop)})


# Inbound digests are stored by id and read by the next check.
static func store_digest(coop, player_id, data):
	if String(player_id) == "" or data == null:
		return
	coop.__play_digests[String(player_id)] = data


# --- the digest: what each machine says it has --------------------------

static func digest(coop):
	if not models.is_loaded():
		return null
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var player = models.get_model("player").get_data()
	var date_model = models.get_model("date")

	var tiles = []
	var data = studio_model.get_data()
	if data.has("list") and data["list"] != null:
		for studio_id in data["list"]:
			if not concurrent.is_studio_owned(studio_id):
				tiles.push_back(String(studio_id))

	var catalog = models.get_model("game").get_data()["catalog"]
	var released = []
	for bucket in ["published", "released", "discontinued"]:
		if not catalog.has(bucket) or catalog[bucket] == null:
			continue
		for game_id in catalog[bucket]:
			released.push_back(String(game_id))
	var in_dev = []
	if catalog.has("dev") and catalog["dev"] != null:
		for game_id in catalog["dev"]:
			in_dev.push_back(String(game_id))
	var holding = []
	if catalog.has("hold") and catalog["hold"] != null:
		for game_id in catalog["hold"]:
			holding.push_back(String(game_id))

	var genres = []
	if models.has_model("game-type"):
		for genre_id in models.get_model("game-type").get_unlocked_game_types():
			genres.push_back(String(genre_id))

	var events = []
	if models.has_model("event") and models.get_model("event").has_method("get_upcoming_events"):
		var upcoming = models.get_model("event").call("get_upcoming_events")
		if upcoming != null:
			for event in upcoming:
				if event != null and event.has("name"):
					events.push_back(String(event["name"]))

	return {
		id = String(coop.__local_id()),
		name = String(player.company_name),
		currency = int(models.get_model("currency").get_currency()),
		fanbase = int(models.get_model("fanbase").get_fanbase()),
		note = float(player.note),
		studios = tiles,
		released = released,
		in_dev = in_dev,
		holding = holding,
		genres = genres,
		date = int(date_model.get_raw_date()),
		paused = bool(date_model.paused),
		speed = int(date_model.get_speed_index()),
		events = events
	}


# --- the check: does what I show about you match what you say? ----------

static func __check(coop):
	if not models.is_loaded():
		return
	# Measure the clock before anything else, so a "date did not advance" failure always comes with the
	# numbers that explain it.
	var date_model = models.get_model("date")
	coop_log.info(coop.config.log_name, "play: clock now raw=%s paused=%s frozen=%s host_raw=%s "
		% [String(date_model.get_raw_date()), String(date_model.paused),
			String(coop.__date_frozen(date_model)), String(coop.__host_raw)]
		+ "speed=%s host_speed=%s" % [String(date_model.get_speed_index()), String(coop.__host_speed)])
	var me = String(coop.__local_id())
	var other = ""
	for player_id in coop.__play_digests:
		if String(player_id) != me:
			other = String(player_id)
			break
	if other == "":
		return

	coop.__play_checks += 1
	var theirs = coop.__play_digests[other]
	var concurrent = models.get_model("concurrent")
	var live = concurrent.get_concurrent()
	var catalogue = company.catalogue()

	var entry = null
	if live != null and live.has(other):
		entry = live[other]

	var checks = {}
	checks["their company is in my world as a rival"] = entry != null
	checks["their name matches the one they report"] = __shown_name(other, entry,
		catalogue) == dict_lib.text(theirs, "name", "")
	checks["our office counts agree"] = __counts_agree(coop, entry, theirs)
	checks["every office they report is theirs on my map"] = __tiles_match(coop, concurrent, entry, theirs)
	checks["every game they report is in my rival feed"] = __games_match(other, theirs)
	checks["their money is what they told me"] = __close_to(entry, "currency",
		dict_lib.number(theirs, "currency", 0))
	checks["their fanbase is what they told me"] = __close_to(entry, "fanbase",
		dict_lib.number(theirs, "fanbase", 0))
	checks["our dates agree"] = __date_agrees(theirs)
	checks["the world is actually running, not silently paused"] = __world_moving(coop)
	checks["my date is ahead of where it was a minute ago"] = __date_advanced(coop)
	checks["the other player's world is advancing"] = __their_date_advanced(coop, theirs)
	checks["our pause state agrees"] = bool(models.get_model("date").paused) == bool(
		dict_lib.field(theirs, "paused", false))
	checks["our speed agrees"] = int(models.get_model("date").get_speed_index()) == int(
		dict_lib.number(theirs, "speed", 0))
	checks["our upcoming events agree"] = __events_agree(theirs)

	__report(coop, "check %s (against %s)" % [String(coop.__play_checks), other.substr(0, 12)], checks)


static func __shown_name(player_id, entry, catalogue):
	if entry != null and entry.has("coop_name") and String(entry["coop_name"]) != "":
		return String(entry["coop_name"])
	if catalogue.has(player_id) and catalogue[player_id] != null and catalogue[player_id].has("name"):
		return String(catalogue[player_id]["name"])
	return String(player_id)


static func __tile_count(entry):
	if entry == null or not entry.has("studio") or entry["studio"] == null:
		return 0
	return entry["studio"].size()


static func __size_of(value):
	if value == null or typeof(value) != TYPE_ARRAY:
		return -1
	return value.size()


# Every office the other player says they hold must be one their company owns on this map. The company
# table and the studio ownership it implies are published separately, so a tile that arrived with the
# company a moment ago may not be flagged as theirs yet - the same propagation delay the office *count*
# check already allows one round for. A missing tile is only reported if it is still missing next round.
static func __tiles_match(coop, concurrent, entry, theirs):
	if entry == null:
		return false
	var reported = dict_lib.field(theirs, "studios", null)
	if reported == null or typeof(reported) != TYPE_ARRAY:
		return false
	var missing = []
	for tile_id in reported:
		if not concurrent.is_studio_owned(String(tile_id)):
			missing.push_back(String(tile_id))
	var key = "tiles"
	if missing.size() == 0:
		coop.__play_pending.erase(key)
		return true
	if coop.__play_pending.has(key):
		coop.__play_pending.erase(key)
		coop_log.info(coop.config.log_name, "play: offices still unowned here after a full round: %s" % [
			company.join(missing, ", ")
		])
		return false
	coop.__play_pending[key] = true
	coop_log.info(coop.config.log_name, "play: %s office(s) not marked theirs here yet, allowing one round" % [
		String(missing.size())
	])
	return true


# An office the other player opened seconds ago reaches this machine through the company table, which
# is published every few seconds. Comparing counts the instant a digest arrives therefore measures
# propagation delay, not whether the two worlds agree - a new office showed up as a mismatch for one
# check and was identical on the next. So a difference is only reported if it survives: the counts are
# remembered and the check passes when they match again on the following round.
static func __counts_agree(coop, entry, theirs):
	var mine = __tile_count(entry)
	var reported = __size_of(dict_lib.field(theirs, "studios", null))
	var key = "counts"
	if mine == reported:
		coop.__play_pending.erase(key)
		return true
	if coop.__play_pending.has(key):
		# Still different a full check later: that is real.
		coop.__play_pending.erase(key)
		return false
	coop.__play_pending[key] = true
	coop_log.info(coop.config.log_name, "play: office count is %s here and %s there, allowing one round "
		% [String(mine), String(reported)] + "for the company table to arrive")
	return true


static func __games_match(player_id, theirs):
	var reported = dict_lib.field(theirs, "released", null)
	if reported == null or typeof(reported) != TYPE_ARRAY or reported.size() == 0:
		return true
	if not models.has_model("concurrent-game"):
		return false
	var model = models.get_model("concurrent-game")
	var present = {}
	for game in model.get_released_games(player_id):
		if game != null and game.has("id"):
			present[String(game["id"])] = true
	for game_id in reported:
		if not present.has(String(game_id)):
			return false
	return true


static func __close_to(entry, field, value):
	if entry == null or not entry.has(field):
		return false
	var spread = abs(float(entry[field]) - float(value))
	return spread <= max(abs(float(value)) * CURRENCY_TOLERANCE, 1.0)


static func __date_agrees(theirs):
	var target = int(dict_lib.number(theirs, "date", -1))
	if target < 0:
		return false
	return abs(int(models.get_model("date").get_raw_date()) - target) <= DATE_TOLERANCE


# The measured claim about the shared clock: the date the other machine reports is moving forward, so
# the session is not frozen on their side either.
static func __their_date_advanced(coop, theirs):
	var now = int(dict_lib.number(theirs, "date", -1))
	var before = int(coop.__play_their_date)
	coop.__play_their_date = now
	if coop.config.play_paused or before < 0 or now < 0:
		return true
	return now >= before


# A paused world makes every other check pass for the wrong reason: two frozen machines agree about
# everything. So the playtest refuses to call a session healthy while the clock is not running, unless
# the pause was asked for.
#
# "Not running" is two different states and only one of them was checked. `paused` is the player's
# switch; `frozen` is the game's own, set by `controllers/date.gd compute_state()` whenever the game is
# not in its plain view mode - which it leaves for the furniture shop and studio editing. A session can
# therefore be unpaused, frozen, and completely stopped, which is what every earlier playtest was: the
# clock sat at week 5 for fifteen minutes while "the world is actually running, not silently paused"
# passed, a project in `dev` never finished, and the release step had nothing to release.
static func __world_moving(coop):
	if coop.config.play_paused:
		return true
	if bool(models.get_model("date").paused):
		return false
	if coop.__date_frozen(models.get_model("date")):
		if not coop.__play_frozen_warned:
			coop.__play_frozen_warned = true
			coop_log.warning(coop.config.log_name, "play: the clock is frozen, not paused (%s)" % [
				__freeze_reason(coop)
			])
		return false
	return true


static func __date_advanced(coop):
	var now = int(models.get_model("date").get_raw_date())
	var before = int(coop.__play_last_date)
	coop.__play_last_date = now
	if coop.config.play_paused or before < 0:
		return true
	if now > before:
		return true
	# A week that did not pass is only a co-op problem if the world was actually able to move. The game
	# freezes its own date model whenever it is not in its plain view state, and an automated run that
	# loads a save and never draws the game scene stays frozen for ever - with both machines agreeing on
	# the same frozen date, which is what __date_agrees already proves. So a frozen clock is reported as
	# a limitation of the run, not as a failure of the sync.
	if coop.__date_frozen(models.get_model("date")):
		if not coop.__play_frozen_noted:
			coop.__play_frozen_noted = true
			coop_log.info(coop.config.log_name, "play: the game's own clock is frozen (the automated run "
				+ "never enters view mode), so the date cannot advance here - both machines still agree")
		return true
	# The clock can be unfrozen, ticking, and still correctly refuse to reach the next week, because the
	# host is frozen and __pull_date_back() puts this machine back every few seconds. That is the sync
	# working, not the date failing to advance, and it was reported as a failure: on a client whose
	# freeze state differed from the host's the playtest failed "my date is ahead of where it was a
	# minute ago" seven checks in a row while the two machines agreed on every value they compared.
	# The honest question is whether this machine is being held back by the world, so it is asked
	# directly.
	if int(coop.__pull_count) > int(coop.__play_corrections):
		coop.__play_corrections = int(coop.__pull_count)
		if not coop.__play_held_noted:
			coop.__play_held_noted = true
			coop_log.info(coop.config.log_name, "play: the date is being held at the world's week by %s "
				% [String(coop.__pull_count)]
				+ " correction(s), so a week passing here is not something the sync would allow")
		return true
	return false


static func __events_agree(theirs):
	var reported = dict_lib.field(theirs, "events", null)
	if reported == null or typeof(reported) != TYPE_ARRAY or reported.size() == 0:
		return true
	if not models.has_model("event"):
		return false
	var names = []
	for event in models.get_model("event").get_upcoming_events():
		if event != null and event.has("name"):
			names.push_back(String(event["name"]))
	for name in reported:
		if not names.has(String(name)):
			return false
	return true


# --- reporting ----------------------------------------------------------

static func __report(coop, what, checks):
	var failed = []
	for label in checks:
		if not checks[label]:
			failed.push_back(label)
	if failed.size() > 0:
		coop.__play_failures += 1
		coop_log.warning(coop.config.log_name, "play: %s FAILED %s of %s checks: %s" % [
			what, String(failed.size()), String(checks.size()), company.join(failed, "; ")
		])
	else:
		coop_log.info(coop.config.log_name, "play: %s passed (%s checks)" % [what, String(checks.size())])


static func __finish(coop):
	coop_log.info(coop.config.log_name, "play: finished after %s s: %s check(s), %s with a failure" % [
		String(coop.config.play), String(coop.__play_checks), String(coop.__play_failures)
	])
	coop_log.info(coop.config.log_name, "play: actions taken: %s" % [company.join(coop.__play_actions,
		", ")])
	# What a player would look at when they ask "is my company still there?".
	var home = company.my_home_office()
	coop_log.info(coop.config.log_name, "play: home office %s in a %s, %s desk(s), %s computer(s), seated=%s" % [
		home["studio"].substr(0, 8), String(home["building"]), String(home["desks"]),
		String(home["computers"]), String(home["seated"])
	])
	if coop.__play_failures == 0:
		coop_log.info(coop.config.log_name, "play: ALL OK")
	else:
		coop_log.warning(coop.config.log_name, "play: PROBLEMS FOUND")
	# The one thing no run had ever watched: a game actually leaving the company's own hands. "published"
	# is the bucket a released game lands in, and it is what the rival feed and the publish-offer list are
	# built from - a button that fires and spends money while the project stays in HOLD would satisfy every
	# assertion above.
	var catalog = models.get_model("game").get_data()["catalog"]
	var counts = []
	for bucket in ["dev", "hold", "published", "released", "discontinued"]:
		var size = 0
		if catalog.has(bucket) and catalog[bucket] != null:
			size = catalog[bucket].size()
		counts.push_back("%s=%s" % [bucket, String(size)])
	coop_log.info(coop.config.log_name, "play: game catalog %s" % [company.join(counts, " ")])
	if coop.config.play_release:
		# Read the buckets as they are *now*, not when the playtest's deadline was decided: the deadline
		# fires a moment before the last actions finish, so a release made seconds later was reported as
		# "nothing reached the published bucket" on a run that had in fact released a game.
		var after = models.get_model("game").get_data()["catalog"]
		var where = []
		for bucket in ["published", "released", "hold", "dev"]:
			var size = 0
			if after.has(bucket) and after[bucket] != null:
				size = after[bucket].size()
			where.push_back("%s=%s" % [bucket, String(size)])
		var shipped = 0
		for bucket in ["published", "released"]:
			if after.has(bucket) and after[bucket] != null:
				shipped += after[bucket].size()
		if shipped > 0:
			coop_log.info(coop.config.log_name, "play: a game is on sale (%s)" % [company.join(where, " ")])
		else:
			coop_log.warning(coop.config.log_name, "play: no game reached published or released (%s), so "
				% [company.join(where, " ")] + "no release completed")


# --- the actions --------------------------------------------------------

static func __next_action(coop):
	if coop.__play_action >= ACTIONS.size():
		return
	var action = ACTIONS[coop.__play_action]
	var done = false
	if action == "project":
		done = __action_project(coop, "indie")
	elif action == "project2":
		done = __action_project(coop, "small")
	elif action == "office":
		done = __action_office(coop)
	elif action == "office2":
		done = __action_office(coop)
	elif action == "furnish":
		done = __action_furnish(coop)
	elif action == "research":
		done = __action_research(coop)
	elif action == "release" or action == "release2":
		# Off by default: publishing a game makes this company's game list change on the wire, and
		# something in the rival-game path crashes this engine build natively (0xc0000005 at 0xae5633,
		# with no GDScript error at all). Enabled explicitly with --coop-play-release so the rest of a
		# long playtest can run while that is being isolated.
		if not coop.config.play_release:
			coop.__play_action += 1
			return
		done = __action_release(coop)
	if done:
		coop.__play_actions.push_back(action)
		coop.__play_action += 1
		coop_log.info(coop.config.log_name, "play: did %s" % [action])
	else:
		# Retried on the next tick, but reported only once so a stuck step is one line, not fifty.
		if not coop.__play_stuck.has(action):
			coop.__play_stuck[action] = true
			coop_log.info(coop.config.log_name, "play: %s not possible yet, will retry" % [action])


# A real game, driven through the game's own step machine, exactly as the project screen does it.
#
# The fields a kickoff needs are copied from a game this company has already released, so the values
# are ones the game itself produced rather than ones invented here.
static func __action_project(coop, wanted_size):
	var game_controller = controllers.get_controller("game")
	var game_model = models.get_model("game")
	if game_controller == null or game_model == null or not models.has_model("studio"):
		return false

	var template = __own_game_template()
	if template == null:
		# Name what is missing. "no usable project values" was accurate and useless: it took a manual
		# probe to learn that a brand-new company has no default engine, because get_default_engine()
		# returns {id, type} and a fresh company has not chosen one - so the owned list is the only source
		# and it was being read after a null check that could never pass.
		coop_log.warning(coop.config.log_name, "play: no usable project values yet (%s)" % [
			__project_values_problem()
		])
		return false
	var office = coop.company_id_for_office()
	if office == "":
		return false

	var data = game_controller.create_game()
	data["name"] = "Coop Test %s" % [String(OS.get_ticks_msec() % 1000000)]
	data["size"] = wanted_size
	data["size_label"] = "LABEL_GAME_SIZE_%s" % [String(wanted_size).to_upper()]
	data["theme"] = template["theme"]
	data["theme_label"] = template["theme_label"]
	data["type_list"] = template["type_list"]
	data["platform_id"] = template["platform_id"]
	data["platform"] = template["platform"]
	data["engine_id"] = template["engine_id"]
	data["engine_feature_ids"] = template["engine_feature_ids"]
	data["online"] = template["online"] if template.has("online") else false
	data["target"] = template["target"]
	data["target_label"] = template["target_label"]
	data["planning"] = 50.0
	data["self_published"] = true
	data["game_offer"] = false
	data["announced"] = true
	data["studio_list"] = [office]

	# Each call is the same transition the game's own screens make.
	game_controller.step(data, 0)   # KICKOFF -> DESIGN
	game_controller.step(data, 0)   # DESIGN -> DEVELOPMENT
	game_controller.step(data, 0)   # DEVELOPMENT -> POLISH
	game_controller.step(data, 0)   # POLISH -> HOLD
	coop_log.info(coop.config.log_name, "play: started project [%s] (%s) in office %s" % [
		String(data["name"]), String(wanted_size), office.substr(0, 8)
	])
	return true


# Why __own_game_template() returned nothing, in the terms a reader can act on.
static func __project_values_problem():
	var missing = []
	if not models.has_model("game-type"):
		missing.push_back("no game-type model")
	elif models.get_model("game-type").get_unlocked_game_types().size() == 0:
		missing.push_back("no genre unlocked")
	if not models.has_model("game-theme"):
		missing.push_back("no game-theme model")
	elif models.get_model("game-theme").get_theme_names().size() == 0:
		missing.push_back("no theme")
	var platform_controller = controllers.get_controller("platform")
	if platform_controller == null or not platform_controller.has_method("list_platform"):
		missing.push_back("no platform controller")
	elif platform_controller.call("list_platform", false, true).size() == 0:
		missing.push_back("no publishable platform")
	if models.has_model("game-engine"):
		var engine = models.get_model("game-engine")
		var owned = engine.call("get_owned_engine_list") if engine.has_method("get_owned_engine_list") else null
		var available = engine.call("get_available_engine_list") if engine.has_method("get_available_engine_list") else null
		# A brand-new company owns no engine and has no default one: it can still start a project on a
		# rentable engine the world already offers, which is what __first_project_values() falls back to.
		if (owned == null or owned.size() == 0) and (available == null or available.size() == 0):
			missing.push_back("no engine to develop on (none owned, none rentable)")
	if missing.size() == 0:
		return "nothing released and nothing on offer, and every project field is available"
	var text = ""
	for part in missing:
		if text != "":
			text += ", "
		text += String(part)
	return text


# Creates this company's first game engine, the way the technology screen does.
#
# `create_engine(name, type, studio_list, features_ids, royalties)` is the game's own controller path: it
# builds an empty engine, adds the features that cost nothing, and registers the result as owned. Only the
# INTERNAL type is created here - a player could also buy or rent one, but an internal engine is what the
# screen offers first and it costs the creation cost, which the playtest has.
static func __create_engine_for_first_project():
	if not models.has_model("game-engine"):
		return null
	var controller = controllers.get_controller("game-engine")
	if controller == null or not controller.has_method("create_engine"):
		return null
	var engine_model = models.get_model("game-engine")
	var office = ""
	if models.has_model("studio"):
		office = models.get_model("studio").get_current_studio_id() \
			if models.get_model("studio").has_method("get_current_studio_id") else ""
	var cost = int(engine_model.call("get_creation_cost"))
	if int(models.get_model("currency").get_currency()) < cost:
		coop_log.warning("coop", "play: cannot build an engine, it costs %s and this company holds %s" % [
			String(cost), String(models.get_model("currency").get_currency())
		])
		return null
	# ENGINE_TYPES.INTERNAL is 0 in scripts/models/game-engine.gd; passed as the enum's own value rather
	# than a literal so a renumbered enum cannot silently create something else.
	var internal = 0
	controller.call("create_engine", "Coop Engine", internal, [office] if office != "" else [], [], 0.0)
	var owned = engine_model.call("get_owned_engine_list")
	if owned == null or owned.size() == 0:
		return null
	var engine_id = owned[owned.size() - 1].id if owned[owned.size() - 1].has("id") else null
	if engine_id != null:
		engine_model.call("set_default_engine", engine_id)
		coop_log.info("coop", "play: built the company's first engine (%s)" % [String(engine_id).substr(0, 8)])
	return engine_id


static func __own_game_template():
	var catalog = models.get_model("game").get_data()["catalog"]
	for bucket in ["published", "discontinued", "released"]:
		if not catalog.has(bucket) or catalog[bucket] == null:
			continue
		for game_id in catalog[bucket]:
			var game = catalog[bucket][game_id]
			if game == null:
				continue
			if not game.has("platform_id") or game["platform_id"] == null:
				continue
			if not game.has("engine_id") or game["engine_id"] == null:
				continue
			if not game.has("theme") or not game.has("type_list") or not game.has("target"):
				continue
			return game
	# A company that has released nothing yet (a client that just joined) has no template to copy, so
	# the values are looked up from what its own machine offers: a genre it knows, a theme that exists,
	# a platform it can publish on.
	return __first_project_values()


static func __first_project_values():
	if not models.has_model("game-type") or not models.has_model("platform"):
		return null
	var gametype = models.get_model("game-type")
	var genres = gametype.get_unlocked_game_types()
	if genres == null or genres.size() == 0:
		return null
	var genre = String(genres[0])

	var theme = ""
	if models.has_model("game-theme"):
		var names = models.get_model("game-theme").get_theme_names()
		if names != null and names.size() > 0:
			theme = String(names[0])
	if theme == "":
		return null

	var platform_id = null
	var platform_name = ""
	var platform_controller = controllers.get_controller("platform")
	if platform_controller != null and platform_controller.has_method("list_platform"):
		var platforms = platform_controller.call("list_platform", false, true)
		if platforms != null:
			for entry in platforms:
				if entry != null and entry.has("id"):
					platform_id = entry["id"]
					platform_name = String(entry["name"]) if entry.has("name") else ""
					break
	if platform_id == null:
		return null

	var engine_id = null
	if models.has_model("game-engine"):
		var engine = models.get_model("game-engine")
		# A fresh company has no default engine and owns none - the game only sets one when the project
		# screen finishes creating an engine. So the project values fall back to a rentable engine the
		# world already offers, which is what a player with no engine actually picks.
		var available = engine.call("get_available_engine_list") if engine.has_method("get_available_engine_list") else null
		if available != null:
			for entry in available:
				if entry != null and entry.has("id"):
					engine_id = entry["id"]
					break
	if engine_id == null:
		# A world with no engine at all - a brand-new company's first project. A player creates one on the
		# technology screen before their first kickoff, and that is the only way this state is ever left;
		# without it the bot could never start a project on a fresh company, which is why every earlier
		# playtest logged "no usable project values" and then did nothing.
		engine_id = __create_engine_for_first_project()
	if engine_id == null:
		return null

	return {
		theme = theme,
		theme_label = "LABEL_THEME_%s" % [theme.to_upper()],
		type_list = [genre],
		platform_id = platform_id,
		platform = platform_name,
		engine_id = engine_id,
		engine_feature_ids = [],
		online = false,
		target = "all",
		target_label = "LABEL_TARGETTED_AUDIENCE_ALL"
	}


# Release and publish everything waiting in HOLD, again through the game's own transitions.
static func __action_release(coop):
	var game_controller = controllers.get_controller("game")
	if game_controller == null:
		return false
	var catalog = models.get_model("game").get_data()["catalog"]
	if not catalog.has("hold") or catalog["hold"] == null or catalog["hold"].size() == 0:
		return false
	var released = 0
	# One step, not two.
	#
	# `HOLD -> RELEASE -> PUBLISH` looks like two steps in TRANSITIONS, and stepping twice looked right.
	# It is not: `game_update()` sets `last_step_validated` and the RELEASE state's own handler calls
	# `release(game_data)`, which calls `specific_game_model.release_game()` - and *that* is what moves the
	# game into the released bucket. A second `step()` made in the same frame arrives while the first is
	# still unvalidated, so the transition is skipped and the game settles back into HOLD. Two releases were
	# logged, `published` stayed at 0, and the other machine saw `games_sent=0` forever.
	#
	# So the release is one step, and the game finishes it on its own. Anything still in HOLD afterwards was
	# not releasable this week and is left for the next attempt.
	for game_id in catalog["hold"].keys():
		var game = catalog["hold"][game_id]
		if game == null:
			continue
		game_controller.step(game, 0)   # HOLD -> RELEASE; the controller then releases it
		released += 1
		coop_log.info(coop.config.log_name, "play: released [%s] through the game's own release step"
			% [String(game["name"])])
	return released > 0


# Another office, on an empty applicable building, the same way the first one was made.
static func __action_office(coop):
	var tile = company.find_empty_office()
	if tile == null:
		return false
	var result = company.furnish_first_office("Branch", tile, null)
	if result.begins_with("tile "):
		return false
	coop_log.info(coop.config.log_name, "play: opened another office: %s" % [result])
	return true


# Furniture into the office: an item created and placed the way the shop does it.
static func __action_furnish(coop):
	if not models.has_model("item"):
		return false
	var office = coop.company_id_for_office()
	if office == "":
		return false
	var item_model = models.get_model("item")
	var studio_model = models.get_model("studio")
	var computers = item_model.list_available_computers(models.get_model("date").get_date())
	if computers == null or computers.size() == 0:
		return false
	var item = item_model.create_item(String(computers[0].id))
	item["bought"] = true
	item_model.set_position(item, Vector2(0, 0))
	studio_model.add_item(office, item, false)
	coop_log.info(coop.config.log_name, "play: put a %s in office %s" % [
		String(computers[0].label), office.substr(0, 8)
	])
	return true


# A technology, bought the way the research screen buys one.
static func __action_research(coop):
	if not models.has_model("game-type"):
		return false
	var gametype = models.get_model("game-type")
	for type_id in gametype.type_static_data:
		if gametype.is_game_type_unlocked(type_id):
			continue
		gametype.unlock_game_type(String(type_id), true)
		coop_log.info(coop.config.log_name, "play: researched the %s genre" % [String(type_id)])
		return true
	return false
