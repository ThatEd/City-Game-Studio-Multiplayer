extends Node

# Co-op mod entry point, loaded as the `coop` autoload (autoload/coop in engine.cfb).
#
# Godot 2 adds autoloads as children of the root before the main scene, in the order they
# appear in the settings file; the build appends this one last, so every other singleton
# (models, controllers, scene_manager, soundfx_manager, ...) already exists when _ready runs.
#
# Nothing here replaces a game script by default: the mod is a set of plaintext files added to
# the pack plus this autoload entry. Game scripts are only swapped when there is no other way
# (see REPLACED in build_mod.py).
#
# Layout of this file:
#   _ready / _process      boot, argument parsing, the test schedule
#   selftest               menu -> new game (or load a save) -> in game, no human needed
#   clock                  starting the simulation after a load
#   report                 what the loaded game is, and how big its state is
#   difftest               capture -> play -> diff -> patch -> apply -> verify

const coop_log = preload("res://coop/log.gd")
const coop_args = preload("res://coop/args.gd")
const automation = preload("res://coop/automation.gd")
const state_sync = preload("res://coop/state.gd")
const updater = preload("res://coop/updater.gd")
const link_lib = preload("res://coop/link.gd")
const company = preload("res://coop/company.gd")
const trade = preload("res://coop/trade.gd")
const menu_lib = preload("res://coop/menu.gd")
const lobby_lib = preload("res://coop/lobby.gd")
const saves_lib = preload("res://coop/saves.gd")
const ui_lib = preload("res://coop/ui.gd")
const play_lib = preload("res://coop/play.gd")
const pilot_lib = preload("res://coop/pilot.gd")
const remote_lib = preload("res://coop/remote.gd")
const dict_probe = preload("res://coop/dictprobe.gd")
const dict_lib = preload("res://coop/dict.gd")

const VERSION = "0.1.0"

const MENU_SCENE = "res://scenes/main.tscn"
const NEW_GAME_SCENE = "res://scenes/new-game/main.tscn"
# The in-game GUI and the bar holding the game's own menu buttons (project, digitalstore, ...).
const GAME_GUI_SCENE = "res://scenes/game/gui/main.tscn"
const GAME_MENU_SCENE = "res://scenes/game/menu.tscn"
# The game's clock, drawn in the corner of the HUD. Its labels are the only place the date the player
# actually reads is visible.
const CALENDAR_SCENE = "res://scenes/game/gui/calendar.tscn"

# Long enough for the new-game form's own _process to fill player_data with its defaults.
const NEW_GAME_FORM_WAIT = 2.0
const MENU_POLL_SECONDS = 0.5

# How often this player'''s company record is re-sent. The record is ~120 bytes.
const COMPANY_INTERVAL = 5.0
# How often the host publishes pause and speed, so both machines advance identically.
const CLOCK_INTERVAL = 1.0
# After a machine's clock first agrees with the world, this long must pass before a difference is read
# as a player pressing pause: the game pauses itself while it loads.
const CLOCK_SETTLE_SECONDS = 20.0
# How often the host offers its upcoming events.
const EVENTS_INTERVAL = 5.0
# UI states in which time must not move for anyone: the game is busy doing something that cannot be
# interrupted half way.
const BLOCKING_STATES = ["saving_mode"]
# How often each player reports the screen it is on.
const STATE_INTERVAL = 1.0
const COMPANY_MODELS = ["player", "staff", "currency", "fanbase", "game",
	"game-sell", "game-purchase", "game-port", "remake", "game-update", "game-interview",
	"post-mortem", "review", "marketing", "market-research", "recruitment", "training",
	"notification", "contract", "building", "server", "achievements", "item",
	"studio-director", "twitch-employee", "product-sale",
	# The player's own consoles. Without this the client inherited the host's console - its name, its
	# price, and the players logged into it - so a company that had just started out already owned a
	# console with customers.
	"custom-platform",
	# The digital store. This is the one that actually produced "the client has 3 million server users
	# without owning anything": the store model holds, per platform, whether this company publishes on
	# it and how many customers it has there. Left as the host's, the client's own store believed it
	# supported the host's console and already had its userbase, and the very next weekly update pushed
	# that userbase into the client's server usage (controllers/digital-store-platform.gd
	# _update_platforms -> server_model.update_usage). A company with no console of its own must start
	# with no store platform support and no users.
	"digital-store"]
# A studio id is a map tile id, so a studio from another game points at a tile that does not exist in
# this world and puts the map camera on nil. The first office is therefore created on an available
# tile of the host's map instead (company.open_first_studio).

# Diagnostic round trip interval (--coop-ping).
const PING_INTERVAL = 2.0
# How often a client re-applies the competitor mute.
const MUTE_INTERVAL = 5.0
# Every signal scripts/models/date.gd declares.
const DATE_SIGNALS = ["freeze", "unfreeze", "first_week_of_the_month", "monthly_report_reset",
	"before_end_of_month", "end_of_week", "end_of_month", "new_week", "month", "update_season",
	"end_of_year", "year", "speed_changed", "start_game"]
# Every date-model handler that advances a rival's business, taken from the connects in
# scripts/models/concurrent.gd and scripts/controllers/concurrent-*.gd. Matching on the handler name
# avoids asking a connection what its target is, which this build cannot do safely: reading
# get_script() off a connection target killed the process, while the plain method string is free.
const COMPETITOR_HANDLERS = ["crack_player_game", "release_games", "compute_sales",
	"compute_end_of_month", "_increase_angryness", "announce_games", "_update_consoles",
	"generate_concurrents_employees", "_yearly_computation", "_generate_buy_each_others",
	"_update_concurrents", "compute_event", "_generate_trade_orders", "remove_concurrent",
	"_concurrent_created", "_concurrent_removed"]
# Model JSON is cut into slices this size so no single string operation is huge.
const WORLD_PART_SIZE = 60000

var config = {}
var __elapsed = 0.0
var __poll = 0.0
var __step = 0
var __form_wait = 0.0
var __settle_at = 0.0
var __diff_phase = 0
var __diff_reference = null
var __diff_second_at = -1.0
var __diff_capture_ms = 0

var __updater = null
var __stream_phase = 0
var __stream_shadow = {}
var __stream_end_at = 0.0
var __stream_updates = 0
var __stream_patches = 0
var __stream_models = 0
var __stream_bytes = 0
var __stream_gzip_bytes = 0
var __stream_update_ms = 0
var __stream_update_max_ms = 0
var __stream_touched = {}
var __stream_last_update = 0.0

var __link = null
var __announced = false
var __next_company_at = 0.0
var __last_company = null
var __known_ids = []
var __next_clock_at = 0.0
var __next_events_at = 0.0
var __last_event_count = -1
var __host_raw = -1
var __host_speed = -1
var __host_paused = false
var __clock_corrections = 0
var __overshoot_warned = false
var __overshoot_noted = false
var __next_time_request_at = 0.0
var __player_states = {}
var __joining = {}
var __next_state_at = 0.0
var __next_debug_at = 0.0
var __next_ping_at = 0.0
var __pings = 0
var __network_wanted = false
var __world_models = {}
var __world_expected = 0
var __world_parts = {}
var __competitors_muted = false
var __client_companies = {}
var __company_logos = {}
var __rival_game_ids = {}
var __player_id = ""
var __logo_sent = false


func __local_id():
	if __player_id == "":
		var name = String(config.name)
		if name == "" or name == "player":
			# Before a game exists there is nothing on the player model to take an id from, so the id
			# comes from the session name. Reported once, because an empty id here silently produced a
			# save called `coop--` and a lobby that could not name the player's own save.
			coop_log.info(config.log_name, "net: this player is unnamed, using [%s]" % [name])
		__player_id = company.make_id(name)
	return __player_id
var __world_received = false
var __own_company_ready = false
var __dialog_studio = null
var __local_company = null
var __restore = null
var __buy_test_done = false
var __buy_test_warned = false
var __buy_test_wait = 0.0
var __buyout_guard_on = false
var __console_phase = 0
var __console_at = 0.0
var __console_id = ""
var __console_before = 0.0
var __spam_at = 0.0
var __spam_tries = 0
var __spam_max = 0
var __spam_done = false
var __spam_waiting = false
var __time_request_at = {}
var __company_table_seen = false
var __join_ready_at = 0.0
var __pick_company_pending = false
# How long the lobby waits for a choice before the join proceeds on its own. Generous: a player reading
# a list is not a stalled program.
const LOBBY_PICK_SECONDS = 180.0
var __lobby_pick_deadline = 0.0
var __lobby_missing_reported = false
var __lobby_announced = false
var __lobby_summary_seen = false
var __lobby_entries = []
# What the player typed into the company form, applied to the new company after the world arrives.
var __lobby_new_company = {}
# The name of the save this world is, which every player's own save is named after.
var __world_save_id = ""
var __next_speed_at = 0.0
var __next_tutorial_at = 0.0
var __calendar_missing_reported = false
# When to clear up after a takeover. See the call site in __finish_join.
var __takeover_reseat_at = -1.0
var __takeover_reseat_done = false
var __last_other_count = -1


func _ready():
	var raw_args = OS.get_cmdline_args()
	config = coop_args.parse(raw_args)
	__updater = updater.new()

	coop_log.info(config.log_name, "coop mod " + VERSION + " booted")
	coop_log.info(config.log_name, "args=" + describe(raw_args))
	coop_log.info(config.log_name, "role=" + config.role + " port=" + String(config.port))

	if config.unknown.size() > 0:
		coop_log.warning(config.log_name, "unrecognised coop arguments: " + describe(config.unknown))

	__apply_test_settings()
	__probe_classes()
	__probe_helpers()
	if config.api_probe:
		__probe_api()
	if config.role != "off":
		__network_wanted = true
	set_process(true)


# Runtime API discovery for this engine build: list the methods the transport classes actually
# expose, instead of guessing from upstream Godot 2.1 (this build is a stripped custom one).
#
# It also compiles every mod script on its own. A helper file that fails to parse is otherwise invisible:
# the autoload keeps whatever the loader managed to register, and the first sign is "Nonexistent
# function" from a command that used the half that was dropped. The engine writes the reason to
# coop/coop-errors.log; this says which files to look at.
# Error codes are not exposed as globals in this engine build's GDScript. 22 is ERR_ALREADY_IN_USE,
# read off the game's own table in src/scripts/json/json-error.gd.
const COMPILE_PROBE_IN_USE = 22


func __probe_helpers():
	var paths = ["res://coop/remote.gd", "res://coop/pilot.gd", "res://coop/play.gd", "res://coop/ui.gd",
		"res://coop/menu.gd", "res://coop/lobby.gd", "res://coop/company.gd", "res://coop/state.gd",
		"res://coop/trade.gd", "res://coop/link.gd", "res://coop/log.gd", "res://coop/dict.gd",
		"res://coop/args.gd", "res://coop/automation.gd", "res://coop/updater.gd"]
	for path in paths:
		var script = load(String(path))
		if script == null:
			coop_log.error(config.log_name, "compile: %s did not load at all" % [path])
			continue
		var error = -1
		if script.has_method("reload"):
			# reload(true), not reload(): this mod keeps instances of these scripts (updater, and the
			# libs main.gd calls into), and reload() refuses with ERR_ALREADY_IN_USE the moment one
			# exists. That refusal was being reported as "FAILED" and read as a broken script for
			# several runs, when the file had compiled perfectly and was in use.
			error = script.call("reload", true)
		if int(error) == 0 or int(error) == COMPILE_PROBE_IN_USE:
			coop_log.info(config.log_name, "compile: %s ok" % [path])
		else:
			coop_log.error(config.log_name, "compile: %s FAILED (reload=%s); the reason is in coop-errors.log"
				% [path, String(error)])


func __probe_api():
	var tcp = StreamPeerTCP.new()
	coop_log.info(config.log_name, "api: StreamPeerTCP methods")
	for method in tcp.get_method_list():
		coop_log.info(config.log_name, "api: tcp.%s" % [String(method.name)])

	var udp = PacketPeerUDP.new()
	coop_log.info(config.log_name, "api: PacketPeerUDP methods")
	for method in udp.get_method_list():
		coop_log.info(config.log_name, "api: udp.%s" % [String(method.name)])


# This build of Godot has modules stripped, so nothing may be assumed about the engine's class
# list. A missing class is a *compile* error, and loading a script that references one kills
# this process outright, so each name is tried by compiling a one-line script at runtime: the
# reload returns an error code instead of dying.
func __probe_classes():
	var names = ["TCPServer", "StreamPeerTCP", "PacketPeerUDP", "StreamPeerSSL", "IP",
		"HTTPClient", "Thread", "Mutex", "Semaphore", "File", "Directory", "StreamPeerBuffer",
		"PacketPeerStream", "PacketPeer", "NetworkedMultiplayerPeer",
		"NetworkedMultiplayerENet", "Timer", "StreamPeer", "GDScript", "JSON"]

	for name in names:
		var script = GDScript.new()
		script.set_source_code("extends Reference\nfunc probe():\n\treturn " + name + ".new()\n")
		var error = script.reload()
		coop_log.info(config.log_name, "class: %s %s (reload=%s)" % [
			name, "present" if error == OK else "MISSING", String(error)
		])


# ---------------------------------------------------------------------------
# Network: competitive co-op with the host's save as the world.
#
# Host: owns the world (its save), owns time (pause and speed), collects the other players'
# company records and broadcasts the resulting competitor table.
# Client: joins, boots from the host's world, picks an existing company or creates one, and
# follows the host's clock.
#
# Time is paused while a player joins, so nobody advances a week into a half-built session, and
# speed always comes from the host so both machines advance identically.
# ---------------------------------------------------------------------------
func __start_network():
	__link = link_lib.new()
	if config.ping or config.trace:
		__link.trace_name = config.log_name
	coop_log.info(config.log_name, "net: connecting to %s:%d" % [config.host, config.port])

	if not __link.connect_to(config.host, config.port):
		coop_log.error(config.log_name, "net: " + __link.last_error)
		return

	__next_clock_at = 0.0
	__next_company_at = 0.0


# What happens when the host goes away.
#
# A client with no world of its own is playing a game whose authority has vanished: the clock is held by
# the host, the company table comes from the host, and nothing it does reaches anyone. Leaving it sitting
# in a frozen world is the worst outcome - the player cannot tell "the host quit" from "the game is
# broken". So the client is told, clearly, and returned to the main menu, which is the game's own
# "session over" screen.
#
# The session state it was part of is written out first, so a host can serve it again: the relay keeps
# per-player records, and a player who comes back finds the company and its interiors as they were.
const DISCONNECT_GRACE = 12.0
const DISCONNECT_MESSAGE = "The host left the session"

var __disconnect_at = -1.0
var __disconnect_notified = false
var __left_to_menu = false
var __screen_at = -1.0
var __left_at = -1.0
var __menu_missing_reported = false

# How long a test run keeps the disconnect screen on screen before giving up on the player dismissing
# it, and how long it lingers in the main menu afterwards so the state can be captured. Only used when
# the run has a time limit; a real player is never hurried along.
const SCREEN_LINGER = 20.0
const MENU_LINGER = 8.0


func __watch_disconnect():
	if config.role != "client" or not __world_received:
		return
	if __link == null or __link.is_live():
		__disconnect_at = -1.0
		return
	# The socket went away. Give it a moment: a relay restart reconnects, and a one-frame blip must not
	# throw the player out of a game they are in the middle of.
	if __disconnect_at < 0.0:
		__disconnect_at = __elapsed + DISCONNECT_GRACE
		coop_log.warning(config.log_name, "net: lost the connection to the host, waiting %s s" % [
			String(DISCONNECT_GRACE)
		])
		return
	if __elapsed < __disconnect_at or __disconnect_notified:
		return
	__disconnect_notified = true
	coop_log.warning(config.log_name, "net: the host is gone, ending the session")
	__leave_session_to_menu()


# Saves what this player would save, then returns them to the main menu with an explanation.
#
# The save happens first and goes through the game's own save path, so what a host can serve later is
# exactly what this player's own game would have written - not a re-derivation of it.
func __leave_session_to_menu():
	var saved = __save_own_company()
	coop_log.info(config.log_name, "net: " + saved)
	__hand_over_own_company()
	__show_disconnect_screen()


# Hands this player's company to the relay so it survives the session.
#
# The relay keeps a copy of every player from the host's periodic company table, but the host is the
# one that just vanished - so everything since its last publish, minutes of play, would go with it. The
# client can still reach the relay at this point (it is told the host is gone *before* its socket is
# closed), and the relay treats a client's "company" message as a record to keep.
func __hand_over_own_company():
	if __link == null or not __link.is_live():
		return
	var record = company.record(__local_id(), null, null, __world_save_id)
	if record == null:
		coop_log.warning(config.log_name, "net: no company to hand over")
		return
	__link.send({"t": "company", "company": record})
	coop_log.info(config.log_name, "net: company handed to the relay on the way out")


# Writes this player's company through the game's own save manager, which is the path the in-game Save
# button takes.
func __save_own_company():
	if not models.is_loaded():
		return "nothing to save, no game loaded"
	if save_manager == null:
		return "no save manager, company not written"
	if save_manager.is_saving():
		return "a save was already in progress, company not written"
	var started = OS.get_ticks_msec()
	# A co-op save is named after the session and the player, so it can never overwrite a single-player
	# save or another session's. See mod/coop/saves.gd.
	#
	# It goes through `_save_game_as(name)` rather than `save_game()`: the latter derives the filename
	# from `data.player.id` inside its worker thread, and `player.get_data()` hands back a fresh
	# dictionary each call, so writing to it changed nothing and the save landed under the host's id.
	# `_save_game_as` is the game's own "Save As" path and takes the name as an argument - which is
	# exactly what is needed here, and is the same path the in-game Save As button uses.
	var name = __coop_save_name()
	if name == "":
		if save_manager.save_game():
			return "company written in %s ms (no co-op name, used the game's own)" % [
				String(OS.get_ticks_msec() - started)
			]
		return "the save manager refused the write"
	if save_manager.has_method("_save_game_as") and save_manager.call("_save_game_as", name):
		# The write is on a worker thread; wait for it so the file exists before anything reads it.
		var waited = 0
		while save_manager.is_saving() and waited < 5000:
			waited += 10
			OS.delay_msec(10)
		return "company written in %s ms as %s" % [String(OS.get_ticks_msec() - started), name]
	if save_manager.save_game():
		return "company written in %s ms (save-as unavailable, used the game's own name)" % [
			String(OS.get_ticks_msec() - started)
		]
	return "the save manager refused the write"


# Whether a co-op save with this name is already on this machine.
func is_coop_save_present(name):
	if name == "":
		return false
	var file = File.new()
	return file.file_exists("user://%s.cgs" % [name])


# The name of the save this world is.
#
# For the host that is whatever save the game loaded, which the game remembers as `lastsavegame`. The mod
# reads it rather than deriving one, so the name a client's save is built from is the real name of the
# world they joined - and a player returning to the same host save finds their own save again.
#
# A *co-op* name is never adopted as the world's: `lastsavegame` is shared by every instance on a machine,
# so a host started after a client session would otherwise take the client's save name as its own - which
# it did, and reported itself under the client's company name.
func __learn_world_save_id():
	if config.role != "host":
		return __world_save_id
	var name = ""
	if save_manager != null and save_manager.has_method("get_last_savegame"):
		var last = save_manager.call("get_last_savegame")
		if last != null:
			name = String(last)
	if name.begins_with("user://"):
		name = name.substr(7, name.length())
	if name.ends_with(".cgs"):
		name = name.substr(0, name.length() - 4)
	# A co-op save name is another session's, not this world's. `lastsavegame` is shared by every instance
	# on a machine, so a host started after a client session otherwise adopts the client's save name as
	# its own - which it did, and then reported itself under the client's company name.
	if saves_lib.is_coop_save(name):
		coop_log.info(config.log_name, "save: ignoring [%s], it is another session's co-op save" % [name])
		name = ""
	if name == "":
		# A world started from New Game has no save name yet. It gets one from the session, so clients
		# still have a stable per-session name to build their own saves from.
		name = saves_lib.session_name_from(config.name)
		coop_log.info(config.log_name, "save: this world has no save yet, calling the session [%s]" % [
			name
		])
	__world_save_id = name
	if name != "":
		coop_log.info(config.log_name, "save: this world is [%s]" % [name])
	return name


# Launches the host world with a save name it did not have before.
func __tick_world_save_id():
	if __world_save_id != "":
		return
	if not models.is_loaded():
		return
	__learn_world_save_id()


# The name this player's save should have in this session, or "" when a co-op name does not apply.
func __coop_save_name():
	if config.role == "off":
		return ""
	var session = ""
	if models.is_loaded() and models.has_model("coop-state"):
		session = String(__world_save_id)
	return saves_lib.save_name(session, __local_id())


# The screen the player sees when the host is gone.
#
# Built from the game's own popup, so it looks like every other message the game shows, and its only
# action takes the player back to the main menu rather than leaving them in a dead world.
func __show_disconnect_screen():
	__screen_at = __elapsed
	var confirm = {
		context = self,
		method = "__back_to_main_menu",
		args = []
	}
	popup_manager.create_warning_popup(
		DISCONNECT_MESSAGE,
		"The session has ended. Your company has been saved and will be there the next time you host "
			+ "or join.\n\nReturn to the main menu to start again.",
		confirm,
		null
	)


func __back_to_main_menu():
	coop_log.info(config.log_name, "net: returning to the main menu after the host left")
	__left_to_menu = true
	__left_at = __elapsed
	scene_manager.main_menu(false, false)


# A test run ends the moment one side dies, instead of after its full duration.
#
# Every long run so far had to be watched to the end before its log could be read, because a crashed
# instance writes nothing at the end - its last lines look like ordinary work. Ending the run on the first
# sign of a dead peer makes a crash cost seconds instead of half an hour, and leaves the other machine's
# log stopping at the moment of interest rather than scrolling past it.
#
# This only applies when a run has a time limit (`--coop-quit`), i.e. to tests. A player is never thrown
# out of their own game by this.
const PEER_WATCH_INTERVAL = 2.0
const CLIENT_SILENCE_LIMIT = 45.0

var __peer_watch_at = 0.0
var __peer_gone = false
var __last_client_heard = 0.0


func __watch_peers():
	if config.quit_after <= 0.0 or __peer_gone:
		return
	# After the session is over the models are being torn down by the game's own menu transition, so the
	# only thing left to watch is the linger timer.
	if __left_to_menu:
		__linger_on_disconnect()
		return
	if not models.is_loaded():
		return
	# A handled disconnect is not a crash: the player is being shown what happened and is on their way
	# to the main menu. Ending the run here would cut that screen off before it could be observed - but
	# the linger timer still has to run, because that timer is what *does* the returning. Returning from
	# here instead of lingering left the client sitting on the disconnect screen until `--coop-quit`
	# ended the run, which is how run TRC2 finished at 600 s without ever reaching the menu.
	if __disconnect_notified and not __left_to_menu:
		__linger_on_disconnect()
		return
	if __elapsed < __peer_watch_at:
		return
	__peer_watch_at = __elapsed + PEER_WATCH_INTERVAL

	var gone = ""
	if config.role == "client" and __world_received:
		# The client is only useful while the host's world is being served to it. A disconnect the mod
		# has already handled is not a crash, so it is left to the linger timer below instead.
		if not __disconnect_notified and (__link == null or not __link.is_live()):
			gone = "the host"
	elif config.role == "host" and __elapsed > 60.0:
		# The host hears from every connected client every few seconds. Silence means that machine is
		# gone, and a run whose other half has died proves nothing further.
		if __last_client_heard > 0.0 and __elapsed - __last_client_heard > CLIENT_SILENCE_LIMIT:
			gone = "the other player"
	if gone == "":
		__linger_on_disconnect()
		return
	__peer_gone = true
	coop_log.warning(config.log_name, "test: %s went away, ending this run now" % [gone])
	set_process(false)
	get_tree().quit()


# In a test run, a handled disconnect has a fixed lifetime: long enough to see the screen, long enough
# to prove the main menu was reached. Without this the run would sit on the disconnect screen until its
# full `--coop-quit`, hiding the menu step behind the same wait.
func __linger_on_disconnect():
	if config.quit_after <= 0.0 or not __disconnect_notified:
		return
	if not __left_to_menu:
		if __screen_at > 0.0 and __elapsed - __screen_at > SCREEN_LINGER:
			coop_log.warning(config.log_name, "test: disconnect screen held %s s, returning to the menu"
				% [String(SCREEN_LINGER)])
			__back_to_main_menu()
		return
	if __left_at > 0.0 and __elapsed - __left_at > MENU_LINGER:
		# Only claimed when the menu is really there: a timer running out says nothing about whether the
		# scene transition worked, and "main menu reached" on a timer is the kind of unchecked claim that
		# makes a broken flow look verified.
		var menu = automation.find_by_scene(get_tree().get_root(), MENU_SCENE)
		if menu == null:
			if not __menu_missing_reported:
				__menu_missing_reported = true
				coop_log.error(config.log_name, "test: %s s after leaving, the main menu is NOT up"
					% [String(MENU_LINGER)])
			return
		coop_log.info(config.log_name, "test: main menu is up, ending this run")
		__peer_gone = true
		set_process(false)
		get_tree().quit()


func __poll_network():
	if __link == null:
		return

	var inbound = __link.poll()
	if inbound.size() > 0:
		coop_log.info(config.log_name, "net: %s message(s) in" % [String(inbound.size())])
	var index = 0
	for message in inbound:
		coop_log.info(config.log_name, "net: dispatching %s" % [String(index)])
		index += 1
		__handle_server_message(message)
	if index > 0:
		coop_log.info(config.log_name, "net: dispatched everything")

	__watch_disconnect()

	if not __link.is_live():
		return

	if not __announced:
		__announced = true
		var player_id = __local_id()
		var company_name = ""
		if models.is_loaded():
			var player = models.get_model("player").get_data()
			company_name = String(player.company_name)
		__link.send({"t": "role", "role": config.role, "player": player_id, "name": company_name})
		coop_log.info(config.log_name, "net: registered as %s (%s)" % [config.role, company_name])

		if config.role == "client":
			__link.send({"t": "join_request", "player": player_id, "auto": __lobby_bypassed()})
			coop_log.info(config.log_name, "net: asked the host to join%s" % [
				" (no lobby: auto)" if __lobby_bypassed() else ", lobby first"
			])

	if __elapsed >= __next_debug_at:
		__next_debug_at = __elapsed + 1.0
		coop_log.info(config.log_name, "net: " + __link.debug_line())

	# A regular round trip, to tell "this build cannot read a socket it has written to" apart from
	# anything specific to joining: each pong lands in the same poll() path a join request would.
	if config.ping and __announced and __elapsed >= __next_ping_at:
		__next_ping_at = __elapsed + PING_INTERVAL
		__pings += 1
		__link.send({"t": "ping", "echo": String(__pings)})
		coop_log.info(config.log_name, "net: ping %s (sent %s bytes so far)" % [
			String(__pings), String(__link.stats_sent)
		])

	# Every player reports the screen it is on, so the world can refuse a time change while somebody is
	# somewhere time cannot move.
	if __elapsed >= __next_state_at:
		__next_state_at = __elapsed + STATE_INTERVAL
		var current = ""
		if models.is_loaded() and models.has_model("state"):
			current = String(models.get_model("state").current_state)
		__player_states[__local_id()] = current
		if config.role == "client":
			__link.send({"t": "state", "player": __local_id(), "state": current})

	if config.role == "host":
		__poll_host_network()
	else:
		__poll_client_network()


# The logo is a base64 PNG of a few tens of kilobytes, so it is sent once rather than in every
# company record. A client can only send it after its own world exists, which is why this is called
# from each role's poll rather than from the handshake.
func __maybe_send_logo(force):
	if __link == null or not models.is_loaded():
		return
	if __logo_sent and not force:
		return
	var data = company.logo()
	if data == null or data == "":
		return
	var player_id = __local_id()
	__link.send({"t": "logo", "player": player_id, "data": data})
	__logo_sent = true
	coop_log.info(config.log_name, "net: logo sent for %s (%s bytes)" % [
		player_id, String(data.length())
	])


# --- host ---------------------------------------------------------------

func __poll_host_network():
	if not models.is_loaded():
		return

	__maybe_send_logo(false)

	if not config.no_clock and __elapsed >= __next_clock_at:
		__next_clock_at = __elapsed + CLOCK_INTERVAL
		var date_model = models.get_model("date")
		var world_raw = int(date_model.get_raw_date())
		var world_speed = int(date_model.get_speed_index())
		var world_paused = __world_paused()
		__link.send({
			t = "clock",
			raw_date = world_raw,
			speed = world_speed,
			paused = world_paused
		})
		# The host *is* the world, so these are its own values - but they still have to be recorded.
		# `__host_raw` is what the shared assertions measure this machine's clock against, and on the
		# host nothing else ever set it: `__broadcast_clock()` does, but this per-second path sends the
		# message inline and never went through it. The result was a host that failed its own check -
		# `verify FAIL date does not run ahead of the world (local 26 vs world 4)` - because "the world"
		# was still a value from the join, twenty weeks behind. A check that fails on a healthy host is
		# as damaging as one that passes on a broken client: it teaches you to ignore the suite.
		__host_raw = world_raw
		__host_speed = world_speed
		__host_paused = world_paused

	# Global events are the host's: it generates them from its own simulation, and a client whose
	# competitor simulation is muted cannot generate the same ones. Pushing the upcoming ones keeps both
	# machines firing them in the same week.
	if __elapsed >= __next_events_at:
		__next_events_at = __elapsed + EVENTS_INTERVAL
		var upcoming = __upcoming_events()
		if upcoming.size() != __last_event_count:
			__last_event_count = upcoming.size()
			__link.send({"t": "events", "list": upcoming})
			coop_log.info(config.log_name, "events: published %s upcoming" % [String(upcoming.size())])

	if not config.no_publish and __elapsed >= __next_company_at:
		__next_company_at = __elapsed + COMPANY_INTERVAL
		__detect_buyouts()
		__host_publish_companies()


# A player's company can be bought out through the game's own acquisition, on any machine that can see
# the rival. When that happens the competitor disappears from this machine's rival list, and the
# company table would otherwise put it straight back on the next update.
#
# The host is the authority: it records the buyout in the world's company section and tells everyone,
# including the player whose company it was.
func __detect_buyouts():
	for player_id in __client_companies.keys():
		if company.is_acquired(player_id):
			continue
		if __rival_exists(player_id):
			continue

		# A connected player's company must never disappear. If something removed it while they are
		# playing - an AI rival buying them out, say - it is put straight back from the world's company
		# section rather than being written off.
		if __player_present(player_id):
			var saved = company.load_from_world(player_id)
			if saved != null and company.restore_competitor(player_id, saved):
				coop_log.warning(config.log_name, "net: %s was removed while its player is connected, "
					% [player_id] + "restored it from the world")
				continue

		var buyer = __local_id()
		company.mark_acquired(player_id, buyer)
		__client_companies.erase(player_id)
		coop_log.info(config.log_name, "net: %s was bought out by %s, removed from the world" % [
			player_id, buyer
		])
		__link.send({"t": "acquired", "player": player_id, "by": buyer})


func __player_present(player_id):
	if not models.has_model("coop-state"):
		return false
	var entry = models.get_model("coop-state").get_player(player_id)
	return entry != null and entry.has("present") and bool(entry["present"])


# Players cannot buy each other out. Their companies are not prizes: a player is playing that company
# from another machine, so buying it would have to be undone on their side and the world would hold two
# ideas of who owns those offices.
#
# The gate is the trading model's `concurrent_bought` signal, because that is the only moment a buyout
# can start (buying the last stock emits it, and the game then opens its acquisition dialog). The
# controller's own handler is disconnected and replaced by this one, which refuses player companies and
# passes every ordinary rival straight through to the game's handler, unchanged.
func __install_buyout_guard():
	if __buyout_guard_on or not models.is_loaded():
		return
	var controller = controllers.get_controller("concurrent")
	var trading = models.get_model("concurrent-trading")
	if controller == null or trading == null:
		return
	if trading.is_connected("concurrent_bought", controller, "_player_bought_concurrent"):
		trading.disconnect("concurrent_bought", controller, "_player_bought_concurrent")
	if not trading.is_connected("concurrent_bought", self, "__on_concurrent_bought"):
		trading.connect("concurrent_bought", self, "__on_concurrent_bought")
	__buyout_guard_on = true
	coop_log.info(config.log_name, "net: players cannot buy each other out (acquisition guard on)")


func __on_concurrent_bought(concurrent_id):
	if company.is_player_company(concurrent_id):
		coop_log.warning(config.log_name, "net: refused a buyout of %s - that company belongs to a "
			% [concurrent_id] + "player, so it cannot be acquired")
		__restore_trading(concurrent_id)
		return

	var controller = controllers.get_controller("concurrent")
	if controller != null and controller.has_method("_player_bought_concurrent"):
		controller.call("_player_bought_concurrent", concurrent_id)


# Puts a refused company's trading data back, so the failed attempt changes nothing: buying the last
# stock had already cleared it before the signal arrived.
func __restore_trading(concurrent_id):
	var concurrent = models.get_model("concurrent")
	var trading = models.get_model("concurrent-trading")
	if trading == null or not models.has_model("concurrent"):
		return
	var entry = __rival_exists(concurrent_id)
	if not entry:
		return
	var bought = 0
	var stocks = 10
	var price = 0
	var controller = controllers.get_controller("concurrent")
	if controller != null and controller.has_method("get_concurrent_price"):
		price = controller.call("get_concurrent_price", concurrent_id)
		stocks = concurrent.get_stocks_per_concurrent()
	if stocks < 1:
		stocks = 10
	trading.set_trading_by_id(concurrent_id, {
		current_value = price,
		number_of_stocks = stocks,
		number_of_stocks_remaining = stocks,
		current_orders = null,
		history_orders = []
	})
	trading.emit_trading_data_updated()
	coop_log.info(config.log_name, "net: %s kept, trading data restored (%s shares)" % [
		concurrent_id, String(stocks)
	])


func __rival_exists(player_id):
	var live = models.get_model("concurrent").get_concurrent()
	return live != null and live.has(player_id)


# Stores another player's company in the world's company section, from the record that player sent.
# The offices' layouts travel inside the record, so a company that comes back later keeps its
# furniture even though it was saved by a different machine.
func __save_remote_player(player_id, record):
	if not models.has_model("coop-state"):
		return
	var coop = models.get_model("coop-state")
	var previous = coop.get_player(player_id)
	var payload = {
		name = dict_lib.text(record, "name", player_id),
		note = float(dict_lib.field(record, "note", 0.0)),
		currency = int(dict_lib.field(record, "currency", 0)),
		fanbase = int(dict_lib.field(record, "fanbase", 0)),
		offices = dict_lib.field(record, "offices", []),
		games = dict_lib.field(record, "games", []),
		studios = dict_lib.field(record, "layouts", []),
		genres = dict_lib.field(record, "genres", []),
		present = true,
		host_confirmed = false
	}
	if previous != null:
		if previous.has("offers") and previous["offers"] != null:
			payload["offers"] = previous["offers"]
		if previous.has("present"):
			payload["present"] = previous["present"]
		if previous.has("host_confirmed"):
			payload["host_confirmed"] = previous["host_confirmed"]
		if previous.has("acquired") and previous["acquired"]:
			payload["acquired"] = true
			payload["acquired_by"] = previous["acquired_by"]
	coop.set_player(player_id, payload)


# The host's own record plus every client record it has been told about.
func __host_publish_companies():
	var table = []
	var own = company.record(__local_id(), null, __rival_game_ids, __world_save_id)
	if own != null:
		table.push_back(own)
	for player_id in __client_companies:
		table.push_back(__client_companies[player_id])

	__link.send({"t": "companies", "companies": table})
	__apply_company_table(table)
	# Named, because a wrong id here silently renames this machine's own company to another player's.
	var table_ids = []
	for record in table:
		table_ids.push_back("%s=%s" % [
			dict_lib.text(record, "id", "?"), dict_lib.text(record, "name", "?")
		])
	coop_log.info(config.log_name, "net: publishing companies %s (mine is %s=%s)" % [
		desc(table_ids), __local_id(),
		String(models.get_model("player").get_data().company_name)
	])
	# The world's company section is part of the save, so a player who leaves is still in the world
	# next time it is loaded, with their offices and games intact.
	company.save_into_world(__local_id(), true)
	# Every player's company goes into the world, not only this machine's: the host is the one that
	# writes the save, so if it only saved its own company the others would be missing on reload.
	for player_id in __client_companies:
		__save_remote_player(player_id, __client_companies[player_id])
	if models.has_model("coop-state"):
		var coop = models.get_model("coop-state")
		var names = []
		for player_id in coop.ids():
			var entry = coop.get_player(player_id)
			names.push_back("%s(%s offices%s)" % [
				player_id,
				String(entry["studios"].size()) if entry != null and entry.has("studios") else "0",
				", away" if entry != null and entry.has("present") and not entry["present"] else ""
			])
		coop_log.info(config.log_name, "world: company section holds %s" % [desc(names)])

	coop_log.info(config.log_name, "net: company table published (%s records, %s client(s))" % [
		String(table.size()), String(__client_companies.size())
	])


# --- client -------------------------------------------------------------

func __poll_client_network():
	if not models.is_loaded():
		return

	__maybe_send_logo(false)

	if __elapsed >= __next_company_at:
		__next_company_at = __elapsed + COMPANY_INTERVAL
		var record = company.record(__local_id(), null, __rival_game_ids, __world_save_id)
		if record != null:
			__link.send({"t": "company", "company": record})
			var change = company.change(__last_company, record)
			__last_company = record
			coop_log.info(config.log_name, "net: company sent (%s)" % [change])


func __handle_server_message(message):
	if config.ping or config.trace:
		coop_log.info(config.log_name, "net: handler entered, %s keys" % [String(message.size())])
	if not message.has("t"):
		return

	if config.ping or config.trace:
		coop_log.info(config.log_name, "net: handling t=%s" % [dict_lib.text(message, "t", "?")])

	if message["t"] == "clock":
		__apply_clock(message)

	elif message["t"] == "pong":
		coop_log.info(config.log_name, "net: pong %s at %s s, received %s bytes" % [
			dict_lib.text(message, "echo", "?"), String(int(__elapsed)), String(__link.stats_received)
		])

	elif message["t"] == "logo":
		var who = dict_lib.text(message, "player", "")
		var data = dict_lib.text(message, "data", "")
		if who != "" and data != "":
			__company_logos[who] = data
			coop_log.info(config.log_name, "net: logo from %s (%s bytes)" % [
				who, String(data.length())
			])
			if config.role == "host":
				# Other clients need it too; the relay fans out everything the host sends.
				__link.send(message)

	elif message["t"] == "companies":
		__apply_company_table(dict_lib.field(message, "companies", []))

	elif message["t"] == "world_begin":
		__world_models = {}
		__world_expected = dict_lib.number(message, "count", 0)
		coop_log.info(config.log_name, "net: world transfer started (%s models)" % [
			String(__world_expected)
		])

	elif message["t"] == "world_part":
		var name = dict_lib.text(message, "name", "")
		var index = dict_lib.number(message, "i", 0)
		if not __world_parts.has(name):
			__world_parts[name] = {}
		__world_parts[name][index] = dict_lib.text(message, "data", "")
		if __world_parts[name].size() == dict_lib.number(message, "of", 1):
			__world_models[name] = __assemble(__world_parts[name])
			__world_parts.erase(name)
			if __world_models.size() % 10 == 0:
				coop_log.info(config.log_name, "net: world %s/%s" % [
					String(__world_models.size()), String(__world_expected)
				])

	elif message["t"] == "world_end":
		coop_log.info(config.log_name, "net: world complete (%s models)" % [
			String(__world_models.size())
		])
		__on_world(__world_models)

	elif message["t"] == "join_request":
		# A player is joining. They are *not* sent the world: they are shown a lobby first, and the
		# lobby only needs a summary of who is here. Sending the whole world before they had chosen who
		# they were was exactly why the lobby could not exist - the client had already booted into a
		# game, so there was nothing left to ask.
		var joiner = dict_lib.text(message, "player", "")
		__joining[joiner] = true
		coop_log.info(config.log_name, "net: %s wants in, offering the lobby (auto=%s)" % [
			dict_lib.text(message, "name", "?"), String(dict_lib.flag(message, "auto", false))
		])
		__send_lobby_summary(joiner)
		# An automated client has nobody to press the lobby, so it says so on its own behalf and the
		# world follows immediately.
		#
		# Read through dict_lib.flag and compared with == true: a value that arrived over the wire is not
		# reliably coerced by bool() in this build, and `bool(field(...))` silently read every `auto`
		# flag as false - so an automated client was offered a lobby it could not press and sat in the
		# main menu while the host ran on without it.
		if dict_lib.flag(message, "auto", false):
			coop_log.info(config.log_name, "net: %s joins without a lobby (auto)" % [joiner])
			__pause(true)
			__broadcast_clock()
			__maybe_send_logo(true)
			__send_world()

	elif message["t"] == "session_request":
		__send_lobby_summary(dict_lib.text(message, "player", ""))

	elif message["t"] == "lobby_pick":
		# The player has decided who they will be. Only now is the world sent.
		var picker = dict_lib.text(message, "player", "")
		coop_log.info(config.log_name, "net: %s chose [%s], sending the world" % [
			picker, dict_lib.text(message, "choice", "new")
		])
		var record = dict_lib.field(message, "company", null)
		if record != null:
			__client_companies[picker] = record
		__pause(true)
		__broadcast_clock()
		__maybe_send_logo(true)
		__send_world()

	elif message["t"] == "offer_request":
		# A player wants to give something to another player. The host is the register: it records the
		# offer in the world so both sides can find it, and passes it on to the recipient.
		var offer = dict_lib.field(message, "offer", null)
		if offer == null:
			return
		trade.store(offer)
		coop_log.info(config.log_name, "trade: %s" % [trade.describe(offer)])
		# The host may be the one being given something.
		__maybe_accept(offer)
		__link.send({"t": "offer", "offer": offer})

	elif message["t"] == "offer_accepted":
		var accepted_id = dict_lib.text(message, "offer", "")
		var accepted = __find_offer(accepted_id)
		if accepted != null and not trade.is_settled(accepted_id):
			var given = trade.apply(accepted, false, config.log_name)
			trade.set_status(accepted_id, "accepted")
			coop_log.info(config.log_name, "trade: our side of %s applied (%s)" % [accepted_id, given])
		__link.send({"t": "offer_accept", "offer": accepted_id})

	elif message["t"] == "offer_rejected":
		var declined = dict_lib.text(message, "offer", "")
		trade.set_status(declined, "rejected")
		coop_log.info(config.log_name, "trade: %s was turned down" % [declined])

	elif message["t"] == "peer_left":
		var left = dict_lib.text(message, "player", "")
		coop_log.info(config.log_name, "net: %s left" % [left])
		__client_companies.erase(left)
		# The company stays in the world; only its presence changes. Carrying on without the player is
		# the host's decision, so time stops until the host says so.
		__mark_present(left, false)
		__host_publish_companies()
		if config.role == "host" and not config.continue_without:
			__pause(true)
			coop_log.warning(config.log_name, "net: %s left. Paused: the host must confirm whether to "
				% [left] + "carry on without them (--coop-continue-without, or the Continue action)")

	elif message["t"] == "time_request":
		__on_time_request(message)

	elif message["t"] == "joined":
		var done = dict_lib.text(message, "player", "")
		__joining[done] = false
		coop_log.info(config.log_name, "net: %s is in, time may move again" % [done])
		# ...and it does: the join paused the world, so somebody has to resume it. The last joiner to
		# arrive resumes everyone, which is what the line above has always claimed.
		if config.role == "host" and not __anyone_joining():
			if bool(models.get_model("date").paused):
				__pause(false)
			__broadcast_clock()

	elif message["t"] == "host_left":
		# The relay tells a client when the authority has gone, before it closes the socket, so the
		# player is not left looking at a frozen world waiting for a timeout to expire.
		coop_log.warning(config.log_name, "net: the relay says the host has left the session")
		if not __disconnect_notified:
			__disconnect_notified = true
			__disconnect_at = __elapsed
			__leave_session_to_menu()

	elif message["t"] == "state":
		__player_states[dict_lib.text(message, "player", "?")] = dict_lib.text(message, "state", "")

	elif message["t"] == "digest":
		# What the other machine says it has, right now. Stored and compared by the playtest.
		var who = dict_lib.text(message, "player", "")
		play_lib.store_digest(self, who, dict_lib.field(message, "digest", null))
		if config.role == "host":
			# Every client needs every other client's digest, and the relay only fans out from the host.
			__link.send(message)

	elif message["t"] == "offer":
		var offer = dict_lib.field(message, "offer", null)
		if offer == null:
			return
		trade.store(offer)
		coop_log.info(config.log_name, "trade: %s" % [trade.describe(offer)])
		# The recipient takes it on their own machine; the host only relays and records.
		__maybe_accept(offer)

	elif message["t"] == "offer_accept":
		var offer_id = dict_lib.text(message, "offer", "")
		var offer = __find_offer(offer_id)
		if offer == null:
			return
		if trade.is_settled(offer_id):
			return
		var result = trade.apply(offer, false, config.log_name)
		trade.set_status(offer_id, "accepted")
		coop_log.info(config.log_name, "trade: our side of %s applied (%s)" % [offer_id, result])

	elif message["t"] == "offer_reject":
		var rejected = dict_lib.text(message, "offer", "")
		trade.set_status(rejected, "rejected")
		coop_log.info(config.log_name, "trade: %s was turned down" % [rejected])

	elif message["t"] == "events":
		__apply_events(dict_lib.field(message, "list", null))

	elif message["t"] == "continue_without":
		var who = dict_lib.text(message, "player", "")
		__confirm_continue(who)

	elif message["t"] == "acquired":
		var victim = dict_lib.text(message, "player", "")
		var buyer = dict_lib.text(message, "by", "")
		company.mark_acquired(victim, buyer)
		if victim == __local_id():
			# This player's own company has been bought out. The world carries on without them, and
			# their company is no longer theirs.
			__on_own_company_acquired(buyer)
		else:
			coop_log.info(config.log_name, "net: %s was bought out by %s" % [victim, buyer])

	elif message["t"] == "company":
		var record = dict_lib.field(message, "company", null)
		if record != null:
			var sender = String(record.id)
			__client_companies[sender] = record
			__last_client_heard = __elapsed
			coop_log.info(config.log_name, "net: company from %s" % [sender])
			# The relay replays a returning player's own company on join. Nothing else on this machine
			# knows about it: the host's world has no section for a player this save has never seen, so
			# without this the player would be handed a brand new company and everything they built on
			# the previous session would be gone even though the relay had it all along.
			if config.role != "host" and sender == __local_id() and __restore == null:
				__restore = record
				__own_company_ready = true
				# `studios` in a company record is a *count*, not a list; the offices themselves are in
				# `offices`. Sizing the count is what killed the client outright at this line.
				var kept_offices = 0
				if record.has("offices") and record["offices"] != null:
					kept_offices = record["offices"].size()
				coop_log.info(config.log_name, "net: the relay kept my own company (%s office(s))" % [
					String(kept_offices)
				])
				return
			# The other player's convention catalogue arrives with their record. Applying it is what
			# keeps the two machines seeing the same events; what each of them does with those events
			# stays local.
			if config.role != "host":
				var catalogue = dict_lib.field(record, "conventions", null)
				if catalogue != null:
					var known = state_sync.apply_convention_catalogue(catalogue)
					if known > 0 and not __conventions_noted:
						__conventions_noted = true
						coop_log.info(config.log_name, "net: took %s convention catalogue entr(ies) from %s" % [
							String(known), sender
						])
			__host_publish_companies()

	elif message["t"] == "session_summary":
		__on_lobby_summary(message)

	elif message["t"] == "error":
		coop_log.error(config.log_name, "net: server says " + dict_lib.text(message, "message", "?"))

	else:
		coop_log.info(config.log_name, "net: unhandled message %s" % [String(message["t"])])


# The lobby's data arrived. This is the point the client can show its choices - and only now, because
# before the summary it knows nothing about the host's world at all.
func __on_lobby_summary(message):
	if config.role != "client":
		return
	if not bool(dict_lib.field(message, "ready", false)):
		var why = dict_lib.text(message, "reason", "not ready")
		coop_log.warning(config.log_name, "lobby: the host is not ready yet (%s)" % [why])
		var panel = __ensure_lobby()
		lobby_lib.show_message(panel, "Waiting for the host: " + why)
		return
	var entries = dict_lib.field(message, "companies", [])
	__lobby_entries = entries
	__lobby_summary_seen = true
	# The session's save name, so this player's own save can be named after it.
	var session = dict_lib.text(message, "session", "")
	if session != "":
		__world_save_id = session
		var my_id = __local_id()
		var mine = saves_lib.save_name(session, my_id)
		coop_log.info(config.log_name, "lobby: this world is save [%s], my id [%s], my save [%s]" % [
			session, my_id, mine
		])
	__show_lobby_choices()


# The information a joining player needs to choose who they are, without the world.
#
# The world is megabytes and takes seconds; a lobby must be instant. The host therefore answers with a
# summary: the date, and every company in it - the host's own, the AI rivals worth taking over, and the
# co-op companies from earlier sessions. That is exactly what `company.takeover_candidates()` reads, so
# the host builds it from its own live models and sends only the list.
func __send_lobby_summary(player_id):
	if not models.is_loaded():
		coop_log.warning(config.log_name, "net: asked for a lobby summary before a game is loaded")
		__link.send({"t": "session_summary", "for": player_id, "ready": false,
			"reason": "the host has not loaded a game yet"})
		return

	var date = models.get_model("date").get_date()
	var entries = company.takeover_candidates()
	var mine = company.record(__local_id(), null, __rival_game_ids, __world_save_id)
	__link.send({
		"t": "session_summary",
		"for": player_id,
		"ready": true,
		"year": int(date.year),
		"month": int(date.month),
		"week": int(date.week),
		"host_name": String(mine["name"]) if mine != null and mine.has("name") else "",
		# The name of the save this world *is*, so each player's own save can be named after it and a
		# returning player can be told which save is theirs. The file never travels; the name does.
		"session": String(__world_save_id),
		"companies": entries
	})
	coop_log.info(config.log_name, "net: lobby summary for %s (%s company/companies, %s/%s)" % [
		String(player_id), String(entries.size()), String(date.year), String(date.month)
	])


# Time is shared, not owned. Any player may press pause or a speed, but the world answers first:
#
#   "can I change time?" -> yes -> everybody's time scale becomes that
#   "can I change time?" -> no  -> everybody is paused
#
# A change is refused while it would be unsafe for someone else: a player still receiving the world, or
# a player in a menu that cannot take time moving (saving). The host arbitrates because it is the only
# machine that sees every player, but the request can come from anyone.
func __request_time(speed, paused):
	if __elapsed < __next_time_request_at:
		return
	__next_time_request_at = __elapsed + 0.5
	__link.send({
		t = "time_request",
		player = __local_id(),
		speed = int(speed),
		paused = bool(paused)
	})
	coop_log.info(config.log_name, "time: asked the world for speed=%s paused=%s" % [
		String(speed), String(paused)
	])


func __can_change_time(who):
	for player_id in __joining:
		if __joining[player_id]:
			coop_log.info(config.log_name, "time: %s is still joining" % [player_id])
			return false
	for player_id in __player_states:
		var player_state = String(__player_states[player_id])
		if BLOCKING_STATES.has(player_state):
			coop_log.info(config.log_name, "time: %s is in %s" % [player_id, player_state])
			return false
	return true


func __on_time_request(message):
	var who = dict_lib.text(message, "player", "?")
	var speed = dict_lib.number(message, "speed", -1)
	var paused = dict_lib.flag(message, "paused", false)

	# A request to pause is always honoured. A request to run is honoured too, even while somebody is in
	# a menu: otherwise one spurious pause request freezes the session for good, which is what happened
	# when the two machines disagreed about their own state during a join. The only thing actually
	# refused is a *speed change* while another player could not survive it.
	if not paused and not __can_change_time(who):
		coop_log.warning(config.log_name, "time: %s asked to resume, not safe yet - unpausing at the "
			% [who] + "current speed without applying a speed change")
		if bool(models.get_model("date").paused):
			__pause(false)
		__broadcast_clock()
		return

	# One request per player per half second. A held button, or a client that keeps forcing a value,
	# must not become a flood of requests that the world has to answer.
	if __elapsed < float(dict_lib.field(__time_request_at, who, -1.0)):
		return
	__time_request_at[who] = __elapsed + 0.5

	# A request that asks for what is already true is not a change; ignore it silently.
	var date_model = models.get_model("date")
	if paused and bool(date_model.paused):
		return
	if not paused and not bool(date_model.paused) and speed == date_model.get_speed_index():
		return

	if paused:
		# In a timed test run a client's pause is not a decision anyone made - it is the game pausing
		# itself (a finished project with no studio director, a money warning) and being forwarded as a
		# request. Honouring it stopped a two-year run dead at week 74 while both machines looked healthy.
		# A real session still pauses for a real player.
		if config.game_speed_request > 0 and who != __local_id():
			coop_log.info(config.log_name, "time: %s asked to pause, ignored in a test run" % [who])
			__broadcast_clock()
			return
		__pause(true)
		coop_log.info(config.log_name, "time: %s paused the world" % [who])
	else:
		__pause(false)
		var date_model = models.get_model("date")
		if speed > 0 and speed != date_model.get_speed_index() and __can_change_time(who):
			date_model.set_speed(speed)
		coop_log.info(config.log_name, "time: %s set the world to speed %s" % [who, String(speed)])
	__broadcast_clock()


func __anyone_joining():
	for player_id in __joining:
		if __joining[player_id]:
			return true
	return false


# The clock the rest of the session should follow.
#
# `date_model.paused` is the player's pause button. `date_model.is_paused()` is *not* the same thing: it
# is also true whenever the game's own _freeze is set, which happens whenever the game is not in its
# plain view state - opening a menu, building, editing a studio. Broadcasting is_paused() therefore told
# the other machine "we are paused" every time a player opened a screen, and with two players somebody is
# always in a screen, so the shared world sat frozen.
func __client_could_have_pressed():
	# Before the join has finished the date model is paused and frozen by the game itself, and there is
	# no player in front of it pressing anything.
	if not __world_received or __host_raw < 0:
		return false
	# The client's own game pauses the clock when it loads a save with a date on it
	# (controllers/date.gd start_date: set_pause(true) once raw_date >= 1), which arrives a few seconds
	# after the world does. Reading that as a press made the client ask the world to pause and froze the
	# session for both players. So the first seconds in the world are not evidence of a press.
	if __elapsed < __clock_settled_at:
		return false
	# Time is frozen whenever the game is not in its plain view state (controllers/date.gd
	# compute_state), so a value that differs while frozen is the game's doing, not a player's.
	var date_model = models.get_model("date")
	if __date_frozen(date_model):
		return false
	return true


func __date_frozen(date_model):
	# Nothing here may call `date_model.get(...)`: Object.get() does not exist on this build's nodes, and
	# calling it is the same native access violation (0xc0000005 at 0xae5633) as Dictionary.get(). It
	# killed the host mid-playtest while it was only reading whether the game had frozen its own clock.
	# The freeze is inferred from what the model exposes instead: `is_paused()` is true for a freeze too,
	# and a paused date model whose own pause flag is false is frozen by the game, not by a player.
	if date_model == null or not date_model.has_method("is_paused"):
		return false
	return bool(date_model.is_paused()) and not bool(date_model.paused)


func __world_paused():
	var date_model = models.get_model("date")
	__watch_pause()
	return bool(date_model.paused)


# Whoever flips the pause or the freeze, the log says when and what the game's own flags were. Without
# this a "paused" line with no matching cause is indistinguishable from a bug in the mod itself.
func __watch_pause():
	if not models.is_loaded():
		return
	var date_model = models.get_model("date")
	var paused = bool(date_model.paused)
	var frozen = __date_frozen(date_model)
	if paused != __last_paused:
		__last_paused = paused
		coop_log.info(config.log_name, "clock: paused is now %s (freeze=%s, started=%s)" % [
			String(paused), String(frozen), String(bool(date_model.is_started()))
		])
	if frozen != __last_freeze:
		__last_freeze = frozen
		coop_log.info(config.log_name, "clock: freeze is now %s (paused=%s)" % [
			String(frozen), String(paused)
		])


func __broadcast_clock():
	var date_model = models.get_model("date")
	var message = {
		t = "clock",
		raw_date = int(date_model.get_raw_date()),
		speed = int(date_model.get_speed_index()),
		paused = __world_paused()
	}
	__link.send(message)
	__apply_clock(message)


# ---------------------------------------------------------------------------
# Self-check: asks the game's own models the questions that matter, on whichever machine it runs.
#
# Screenshots are poor evidence for a management sim - they show layout, not correctness, and a wrong
# number looks exactly like a right one. This reads the same model data the UI reads and reports
# PASS/FAIL per item, so a regression is a line in a log rather than a judgement call about pixels.
#
#   --coop-verify=12     run the checks 12 seconds after the world is up
# ---------------------------------------------------------------------------
var __verify_done = false
var __verify_skipped_reported = false
var __verify_at = 0.0
var __verify_pass = 0
var __verify_fail = 0
var __gift_sent = false
var __menu_patched = false
var __menu_warned = false
var __menu_dumped = false
var __menu_checked = false
var __game_panel = null
var __game_ui_warned = false
var __next_ui_at = 0.0
var __ui_tested = false
var __ui_layout = Rect2(0, 0, 0, 0)
var __tech_probed = false
var __office_tested = false
var __play_deadline = 0.0
var __play_next_action = 0.0
var __play_next_check = 0.0
var __play_next_digest = 0.0
var __play_release_at = 0.0
var __play_action = 0
var __play_checks = 0
var __play_failures = 0
var __play_finished = false
var __play_digests = {}
var __play_actions = []
var __play_stuck = {}
var __play_last_date = -1
var __play_was_frozen = false
var __play_their_date = -1
var __play_frozen_noted = false
var __play_pending = {}


# The UI pilot (pilot.gd): a client driven through the game's real panels and buttons.
var __pilot_started = false
var __pilot_done = false
var __pilot_step = 0
var __pilot_at = 0.0
var __pilot_next_at = 0.0
var __pilot_checks = 0
var __pilot_failures = 0
var __pilot_game_name = ""
var __pilot_rivals_pressed = false
var __pilot_panel_pressed = false
var __pilot_press_at = 0.0
var __pilot_sub = 0

# Stage tracing for a native crash with no GDScript error: each frame says it survived, so the last
# marker before the process dies is the call that killed it.
var __next_trace_at = 0.0

# The remote control (remote.gd): a command file read one line at a time, so a person can drive this
# instance's real UI by hand instead of running a scripted sequence.
var __remote_next_at = 0.0
var __remote_seq = 0
var __remote_done = {}
var __remote_reported = false
var __last_paused = false
var __dumped = false
var __host_office_cleaned = false
var __host_named = false
var __server_zeroed_noted = false
var __conventions_noted = false
var __last_freeze = false
# When this machine's clock first agreed with the world. Nothing before it counts as a player press.
var __clock_settled_at = 1e12
var __research_done = false
var __gift_skipped = false
var __offer_counts = {}
var __offer_seen = {}
var __gift_warned = false
var __gift_armed = false
var __calendar_cached = null


# What the clock in the corner of the game's own HUD actually says, as "month year", or "" when the
# calendar is not on screen. Read from the two Label nodes the calendar draws
# (scenes/game/gui/calendar: container/container/container/date/month and .../date/year), not from the
# date model - the point is to compare the two.
func __clock_label():
	var calendar = __calendar_node()
	if calendar == null:
		return ""
	var month = calendar.find_node("container/container/container/date/month", true, false)
	var year = calendar.find_node("container/container/container/date/year", true, false)
	if month == null or year == null:
		return ""
	return "%s %s" % [String(month.get_text()), String(year.get_text())]


# The calendar names a month and a year; the model holds a raw week. They agree when the label names the
# month the model computes for that same year. A calendar that is not on screen counts as agreeing: this
# check is about the two disagreeing, not about the HUD being present.
func __clock_shows_model():
	var calendar = __calendar_node()
	if calendar == null:
		return true
	var month = calendar.find_node("container/container/container/date/month", true, false)
	var year = calendar.find_node("container/container/container/date/year", true, false)
	if month == null or year == null:
		return true
	var shown = models.get_model("date").get_date()
	return String(month.get_text()) == tr(__month_name(int(shown.month))) \
		and String(year.get_text()) == String(int(shown.year))


func __month_name(month):
	var names = ["January", "February", "March", "April", "May", "June", "July", "August",
		"September", "October", "November", "December"]
	if month < 0 or month >= names.size():
		return "?"
	return String(names[month])


func __calendar_node():
	if __calendar_cached != null and is_instance_valid(__calendar_cached):
		return __calendar_cached
	var found = automation.find_by_scene(get_tree().get_root(), CALENDAR_SCENE)
	if found != null:
		__calendar_cached = found
	return found


func __check(name, ok, detail):
	if ok:
		__verify_pass += 1
		coop_log.info(config.log_name, "verify PASS %s (%s)" % [name, detail])
	else:
		__verify_fail += 1
		coop_log.warning(config.log_name, "verify FAIL %s (%s)" % [name, detail])


func __run_verify():
	if __verify_done or not models.is_loaded() or __host_raw < 0:
		# Say so once. A suite that silently never runs is worse than no suite: it looks like a pass.
		if config.verify > 0.0 and not __verify_done and not __verify_skipped_reported \
				and __elapsed > config.verify + 30.0:
			__verify_skipped_reported = true
			coop_log.warning(config.log_name, "verify: never ran (models=%s host_raw=%s)" % [
				String(models.is_loaded()), String(__host_raw)
			])
		return
	if config.verify <= 0.0:
		return

	# The checks must run after the join has finished, not when the world merely arrived. Firing early
	# reported "0 offices" and "0 rival players" because the office is opened and the company table
	# arrives a few seconds later - a false alarm that looked like two real bugs.
	if __verify_at == 0.0:
		__verify_at = __elapsed + config.verify
		coop_log.info(config.log_name, "verify: check scheduled in %s s" % [String(config.verify)])
		return
	if __elapsed < __verify_at:
		if __elapsed > __verify_at + 20.0 and not __verify_skipped_reported:
			__verify_skipped_reported = true
			coop_log.warning(config.log_name, "verify: waiting, pending=%s verify_at=%s elapsed=%s" % [
				String(__pick_company_pending), String(__verify_at), String(__elapsed)
			])
		return
	if config.role == "client" and __pick_company_pending:
		__verify_at = __elapsed + 5.0
		return
	__verify_done = true

	var me = __local_id()
	var player = models.get_model("player").get_data()
	var my_studios = company.count_player_studios()
	var live = models.get_model("concurrent").get_concurrent()
	var date_model = models.get_model("date")
	var catalogue = company.catalogue()

	coop_log.info(config.log_name, "verify: running on %s as %s" % [config.role, me])

	__check("own company has a name", String(player.company_name) != "", String(player.company_name))
	__check("own company has an office", my_studios > 0, "%s office(s)" % [String(my_studios)])
	var home = company.my_home_office()
	__check("the home office is in a home building", home["home_building"],
		String(home["building"]))
	__check("no office of ours is in a building we cannot work in",
		home["bad_buildings"].size() == 0, company.join(home["bad_buildings"], ", "))
	__check("the home office has a desk", home["desks"] > 0, "%s desk(s)" % [String(home["desks"])])
	__check("the home office has a computer", home["computers"] > 0,
		"%s computer(s)" % [String(home["computers"])])
	__check("the player is seated at a desk", home["seated"], "desk %s" % [String(home["seat"])])
	__check("the office belongs to nobody else", not home["owned_elsewhere"],
		"owner %s" % [String(home["owner"])])
	var staff = company.my_staff_summary()
	__check("this company has at least one developer", staff["developers"] > 0,
		"%s developer(s)" % [String(staff["developers"])])
	__check("every employee works in an office that exists", staff["orphans"].size() == 0,
		company.join(staff["orphans"], ", "))
	__check("the player is seated in an existing office", staff["seated_ok"], "")
	__check("only one home office, however many times this player joined",
		home["homes"] <= 1, "%s home office(s)" % [String(home["homes"])])
	__check("no office of ours is an empty shell", home["shells"].size() == 0,
		company.join(home["shells"], ", "))
	__check("another company's console is not one this company publishes on",
		company.foreign_consoles_supported().size() == 0,
		company.join(company.foreign_consoles_supported(), ", "))
	__check("the server holds nobody else's users", company.foreign_server_users() == 0,
		String(company.foreign_server_users()))
	# The calendar label is drawn from the date model, but it repaints only on the `month` signal, while
	# the mod corrects a drifted client with set_raw_date() - which emits nothing. A live session showed a
	# client whose model said 1978/01 and whose clock still read AUG 1977. Comparing what the game renders
	# against what its own model holds is the only way to catch that: both were internally consistent.
	__check("the clock on screen shows the week the game model holds",
		__clock_shows_model(), String(__clock_label()))
	# Conventions are half shared and half personal: the events are the world's, what a player did with
	# them is not. So the client must see a real convention catalogue (a shared world) while having
	# nothing of its own planned, running or attended (its own company).
	var conventions = company.my_conventions()
	__check("this company has planned no conventions of its own", int(conventions["planned"]) == 0,
		"%s planned" % [String(conventions["planned"])])
	__check("this company has attended no conventions yet", int(conventions["attended"]) == 0,
		"%s attended" % [String(conventions["attended"])])
	__check("this company has no convention running on its behalf", int(conventions["running"]) == 0,
		"%s running" % [String(conventions["running"])])
	# The other half: the catalogue must be the world's. If the two machines disagree about which
	# conventions exist, they are not looking at the same events and a stand booked on one side is
	# invisible on the other.
	#
	# What counts as "the catalogue" matters, and the first version of this check got it wrong. It
	# counted `generated` + `announced` from the model's `get_data()` - but those hold only the
	# conventions *generated during this session* and the ids already announced, and both are empty in a
	# young game while the shipped list in `game-convention.gd` is what the player actually sees. So the
	# check reported `0 entr(ies)` and FAILed on two healthy machines, which is worse than not checking:
	# a suite that cries wolf on a working session teaches you to ignore it.
	#
	# The honest question is "does this machine know the conventions it would show a player", so it is
	# answered from `list_existing_conventions()` - the static list plus anything generated - and the
	# generated and announced counts are reported alongside instead of deciding the result.
	var catalogue = company.convention_catalogue()
	var known_events = -1
	if catalogue != null:
		known_events = int(catalogue["known"])
	__check("this machine knows the shared convention catalogue", known_events > 0,
		"%s entr(ies); %s generated here, %s announced" % [
			String(known_events),
			String(catalogue["generated"].size()) if catalogue != null else "?",
			String(catalogue["announced"].size()) if catalogue != null else "?"
		])
	__check("own company has money", int(models.get_model("currency").get_currency()) > 0,
		String(models.get_model("currency").get_currency()))
	__check("own company has no console unless it earned one", company.my_consoles().size() >= 0,
		"%s console(s)" % [String(company.my_consoles().size())])

	__check("date does not run ahead of the world", date_model.get_raw_date() - __host_raw <= 1,
		"local %s vs world %s" % [String(date_model.get_raw_date()), String(__host_raw)])
	__check("speed matches the world", date_model.get_speed_index() == __host_speed,
		"local %s vs world %s" % [String(date_model.get_speed_index()), String(__host_speed)])
	__check("pause matches the world", bool(date_model.paused) == __host_paused,
		"local %s vs world %s" % [String(date_model.paused), String(__host_paused)])

	# Every other player must be a competitor here, with their real name, offices and games.
	var others = 0
	for rival_id in live:
		var rival = String(rival_id)
		if not company.is_player_company(rival) or rival == me:
			continue
		others += 1
		var entry = live[rival]
		var offices = 0
		if entry.has("studio") and entry["studio"] != null:
			offices = entry["studio"].size()

		var saved = company.load_from_world(rival)
		var expected_name = rival
		var expected_games = 0
		if saved != null:
			if saved.has("name"):
				expected_name = String(saved["name"])
			if saved.has("games") and saved["games"] != null:
				expected_games = saved["games"].size()

		var shown_name = rival
		if catalogue.has(rival) and catalogue[rival] != null and catalogue[rival].has("name"):
			shown_name = String(catalogue[rival]["name"])
		elif entry.has("coop_name"):
			shown_name = String(entry["coop_name"])

		__check("rival %s shows their real name" % [rival], shown_name == expected_name,
			"shown [%s] expected [%s]" % [shown_name, expected_name])
		__check("rival %s owns offices" % [rival], offices > 0, "%s office(s)" % [String(offices)])

		var released = models.get_model("concurrent-game").get_released_games(rival).size()
		__check("rival %s has their games" % [rival], released >= expected_games,
			"%s released, world says %s" % [String(released), String(expected_games)])

		var proposals = models.get_model("concurrent-game").get_concurrent_proposals(rival)
		if expected_games > 0:
			__check("rival %s offers titles to publish" % [rival], proposals.size() > 0,
				"%s offer(s)" % [String(proposals.size())])
			if proposals.size() > 0:
				var first = proposals[0]
				__check("an offer from %s is complete" % [rival],
					first != null and first.has("name") and String(first["name"]) != "",
					String(first["name"]) if first != null and first.has("name") else "no name")

	__check("at least one other player is present", others > 0,
		"%s rival player(s)" % [String(others)])

	__check_transfer()

	coop_log.info(config.log_name, "verify: %s passed, %s failed" % [
		String(__verify_pass), String(__verify_fail)
	])
	if __verify_fail == 0:
		coop_log.info(config.log_name, "verify: ALL OK")
	else:
		coop_log.warning(config.log_name, "verify: PROBLEMS FOUND")


# --- transfers between players ------------------------------------------
#
# Offers are made by id, not by screen: a money transfer needs an amount, a technology needs the genre,
# and an IP transfer needs one of the sender's published games. The recipient accepts or refuses, and
# only then does anything move.

# The command line can ask for one transfer (--coop-gift); by verify time it must have been settled,
# and on the machine that took it the effect must be present in the model the UI reads.
func __check_transfer():
	if config.gift == "" or __gift_skipped:
		return
	var parts = String(config.gift).split(":")
	var kind = parts[0]
	var settled = []
	var seen = {}
	var coop = null
	if models.has_model("coop-state"):
		coop = models.get_model("coop-state")
	if coop != null:
		var offer_total = 0
		for player_id in coop.ids():
			var entry = coop.get_player(player_id)
			if entry == null or not entry.has("offers") or entry["offers"] == null:
				continue
			offer_total += entry["offers"].size()
			for offer_id in entry["offers"]:
				var offer = entry["offers"][offer_id]
				if offer == null or seen.has(String(offer_id)):
					continue
				var accepted = coop.is_settled(String(offer_id))
				if offer.has("status") and String(offer["status"]) == "accepted":
					accepted = true
				if not accepted:
					continue
				seen[String(offer_id)] = true
				settled.push_back(offer)
		coop_log.info(config.log_name, "verify: coop-state has %s section(s), %s offer record(s)" % [
			String(coop.ids().size()), String(offer_total)
		])

	__check("the %s transfer was accepted" % [kind], settled.size() > 0,
		"%s accepted offer(s)" % [String(settled.size())])

	var mine = false
	for offer in settled:
		if String(offer["kind"]) != kind:
			continue
		if dict_lib.text(offer, "to", "") != __local_id():
			continue
		mine = true
		var payload = offer["payload"]
		if kind == trade.MONEY:
			__check("money was received", int(models.get_model("currency").get_currency()) > 0,
				"balance %s" % [String(models.get_model("currency").get_currency())])
		elif kind == trade.TECH:
			var genre_id = String(payload["type"])
			__check("the %s technology is known here" % [genre_id],
				models.get_model("game-type").is_game_type_unlocked(genre_id),
				dict_lib.text(payload, "label", genre_id))
		elif kind == trade.IP:
			var game_id = String(payload["game_id"])
			var catalog = models.get_model("game").get_data()["catalog"]
			var held = false
			if catalog.has("hold") and catalog["hold"] != null and catalog["hold"].has(game_id):
				held = true
			if catalog.has("published") and catalog["published"] != null and catalog["published"].has(game_id):
				held = true
			__check("the IP of %s is held here" % [game_id], held, game_id)
	if not mine:
		coop_log.info(config.log_name, "verify: this machine gave rather than took the transfer")


func __find_offer(offer_id):
	if not models.has_model("coop-state"):
		return null
	for player_id in models.get_model("coop-state").ids():
		var entry = models.get_model("coop-state").get_player(player_id)
		if entry == null or not entry.has("offers") or entry["offers"] == null:
			continue
		if entry["offers"].has(offer_id):
			return entry["offers"][offer_id]
	return null


func offer_money(to_id, amount):
	var offer = trade.make(__local_id(), to_id, trade.MONEY, {amount = int(amount)})
	__send_offer(offer)


func offer_technology(to_id, type_id):
	if String(type_id) == "":
		coop_log.warning(config.log_name, "trade: no technology to offer")
		return
	var gametype = models.get_model("game-type")
	var label = String(type_id)
	if gametype.type_static_data.has(String(type_id)):
		label = gametype.type_static_data[String(type_id)].label
	var offer = trade.make(__local_id(), to_id, trade.TECH, {
		type = String(type_id),
		label = label
	})
	__send_offer(offer)


func offer_ip(to_id, game_id):
	var game = __own_published_game(game_id)
	if game == null:
		coop_log.warning(config.log_name, "trade: %s is not one of our published games" % [game_id])
		return
	var name = String(game["name"]) if game.has("name") else String(game_id)
	var offer = trade.make(__local_id(), to_id, trade.IP, {
		game_id = String(game_id),
		name = name,
		game = game
	})
	__send_offer(offer)


func __own_published_game(game_id):
	var catalog = models.get_model("game").get_data()["catalog"]
	if catalog.has("published") and catalog["published"] != null and catalog["published"].has(game_id):
		return catalog["published"][game_id]
	return null


func __send_offer(offer):
	trade.store(offer)
	# A client asks the host to register it; the host registers and relays. Sent to the world either way,
	# so the host records what a client gives away.
	__link.send({"t": "offer_request", "offer": offer})
	coop_log.info(config.log_name, "trade: sent %s" % [trade.describe(offer)])


func __maybe_accept(offer):
	var offer_id = dict_lib.text(offer, "id", "")
	var target = dict_lib.text(offer, "to", "")
	if not __offer_seen.has(offer_id):
		__offer_seen[offer_id] = true
		coop_log.info(config.log_name, "trade: offer %s is for %s, I am %s, auto=%s" % [
			offer_id, target, __local_id(), String(config.offer_auto)
		])
	if target == "" or target != __local_id():
		return false
	if trade.is_settled(offer_id):
		return false
	if not config.offer_auto:
		return false
	__accept_offer(offer)
	return true


func __accept_offer(offer):
	if trade.is_settled(dict_lib.text(offer, "id", "")):
		return
	var result = trade.apply(offer, true, config.log_name)
	trade.set_status(String(offer["id"]), "accepted")
	coop_log.info(config.log_name, "trade: accepted %s (%s)" % [trade.describe(offer), result])
	if config.role == "client":
		__link.send({"t": "offer_accepted", "offer": String(offer["id"])})
	else:
		__link.send({"t": "offer_accept", "offer": String(offer["id"])})


func __reject_offer(offer):
	trade.set_status(String(offer["id"]), "rejected")
	coop_log.info(config.log_name, "trade: refused %s" % [trade.describe(offer)])
	__link.send({"t": "offer_reject" if config.role == "client" else "offer_rejected",
		"offer": String(offer["id"])})


# --- main menu ----------------------------------------------------------
#
# The two menu buttons call these. Hosting starts as soon as the host has a game loaded, because the
# host's save is the world; joining connects straight away and waits for the world to arrive.

func menu_host_pressed():
	config.role = "host"
	__network_wanted = true
	menu_lib.set_options_visible(automation.find_by_scene(get_tree().get_root(), MENU_SCENE), false)
	coop_log.info(config.log_name, "menu: hosting. Load or start a game and others will be able to join.")


func menu_join_pressed():
	var menu = automation.find_by_scene(get_tree().get_root(), MENU_SCENE)
	var typed = menu_lib.address_text(menu) if menu != null else ""
	if typed != "":
		__use_address(typed)
	config.role = "client"
	config.autojoin = true
	__network_wanted = true
	menu_lib.set_options_visible(menu, false)
	coop_log.info(config.log_name, "menu: joining %s:%s" % [config.host, String(config.port)])
	# The lobby appears straight away in its waiting state: the world has not arrived, so the list of
	# companies to take over does not exist yet. Showing it now, rather than after the transfer, is what
	# tells the player something is happening at all.
	__show_lobby_waiting("%s:%s" % [config.host, String(config.port)])
	__start_network()


# --- the lobby -----------------------------------------------------------
#
# Choosing *who you are* in the host's world, which the two menu buttons used to skip entirely.
# See mod/coop/lobby.gd for why it is a panel and not a scene.

func __show_lobby_waiting(address):
	var panel = __ensure_lobby()
	lobby_lib.show_waiting(panel, address)
	coop_log.info(config.log_name, "lobby: waiting for the host's world (%s)" % [String(address)])


# Called once the world is in and this machine knows which companies exist.
func __show_lobby_choices():
	if config.role != "client":
		return
	var panel = __ensure_lobby()
	var entries = __lobby_entries
	if entries == null or entries.size() == 0:
		entries = company.takeover_candidates()
	lobby_lib.show_choices(panel, self, entries)
	if not __lobby_announced:
		__lobby_announced = true
		coop_log.info(config.log_name, "lobby: %s company/companies to take over, plus a new one" % [
			String(entries.size())
		])
		for entry in entries:
			coop_log.info(config.log_name, "lobby:   [%s] %s  %s office(s)  $%s  (%s)" % [
				String(lobby_lib.value_of(entry, "id", "")),
				String(lobby_lib.value_of(entry, "name", "")),
				String(int(lobby_lib.value_of(entry, "offices", 0))),
				String(int(lobby_lib.value_of(entry, "currency", 0))),
				String(lobby_lib.value_of(entry, "kind", ""))
			])


# "Start a new company" opens the game's own company form rather than deciding silently. The player
# names their company, picks a logo and a specialisation there, and only then is anything sent.
func lobby_new_pressed():
	lobby_lib.show_create(__lobby_panel())
	coop_log.info(config.log_name, "lobby: showing the company setup screen")


# Reads the game's own form and joins with what the player typed.
func lobby_create_confirmed():
	var panel = __lobby_panel()
	var name = lobby_lib.company_name_text(panel)
	if name.strip_edges() == "":
		lobby_lib.show_message(panel, "Your company needs a name before you can join.")
		return
	var data = lobby_lib.company_form_data(panel)
	config.company_choice = "new"
	config.company_name = name
	__lobby_new_company = data
	coop_log.info(config.log_name, "lobby: new company called [%s] (%s field(s))" % [
		name, String(data.size())
	])
	__lobby_commit("a new company called " + name)


func lobby_create_back():
	lobby_lib.show_choose_page(__lobby_panel())
	lobby_lib.show_choices(__lobby_panel(), self, __lobby_entries)


# Receives the company id as a bound argument from the row's `pressed` signal.
func lobby_takeover_pressed(company_id):
	config.company_choice = String(company_id)
	__lobby_commit("company %s" % [config.company_choice])


func lobby_cancel_pressed():
	lobby_lib.hide(__lobby_panel())
	config.role = "off"
	__network_wanted = false
	if __link != null:
		__link.close()
		__link = null
	coop_log.info(config.log_name, "lobby: cancelled, back to single player")


func __lobby_commit(label):
	lobby_lib.show_starting(__lobby_panel(), label)
	coop_log.info(config.log_name, "lobby: chose %s" % [label])
	# The world is not here yet - the lobby was shown from a summary, deliberately, so the player never
	# entered a game they had not chosen. Asking for it now is what starts the transfer.
	if not __world_received:
		__link.send({"t": "lobby_pick", "player": __local_id(), "choice": config.company_choice})
		coop_log.info(config.log_name, "lobby: asked the host for the world")
		return
	# A rejoin where the world was already in: finish now.
	if __pick_company_pending and models.is_loaded():
		__finish_join()


# The lobby panel, if there is one.
#
# Attached to the scene root, not to the main menu. The world transfer pushes the game's loading scene,
# which replaces the menu - so a lobby parented to the menu would be freed at exactly the moment it
# became useful. The root outlives every scene change.
# The lobby panel, if there is one.
#
# Attached to the scene root, not to the main menu. The world transfer pushes the game's loading scene,
# which replaces the menu - so a lobby parented to the menu would be freed at exactly the moment it
# became useful. The root outlives every scene change.
func __lobby_panel():
	var root = get_tree().get_root()
	return root.find_node(lobby_lib.PANEL_NODE, true, false)


func __ensure_lobby():
	var panel = __lobby_panel()
	if panel != null:
		return panel
	panel = lobby_lib.build(self)
	panel.set_name(lobby_lib.PANEL_NODE)
	get_tree().get_root().add_child(panel)
	return panel





# Keeps the lobby above the game scene while it is on screen.
#
# The game adds its own scene to the root after the mod's, so a root-level panel that was visible and
# correctly sized was completely covered by the game - the run's screenshot showed the studio, not the
# lobby, while the lobby's own rect said (202, 40, 722, 460). Raising it once at show time is not enough
# because the scene it must stay above can be pushed afterwards.
func __keep_lobby_on_top():
	if not __lobby_pick_pending():
		return
	var panel = __lobby_panel()
	if panel != null and panel.is_visible():
		lobby_lib.__raise(panel)


# Runs the deferred takeover cleanup, once the game's own acquisition has finished making its offices.
func __tick_takeover_reseat():
	if __takeover_reseat_done or __takeover_reseat_at < 0.0:
		return
	if __elapsed < __takeover_reseat_at:
		return
	__takeover_reseat_done = true
	company.reseat_after_takeover()


# Whether this run skips the lobby.
#
# A player sees the lobby. A script cannot press it, so an automated run decides up front - either
# `--coop-company=<id>` (already decided) or `--coop-pilot` (a script is driving) or
# `--coop-lobby=off`.
func __lobby_bypassed():
	if config.role != "client":
		return false
	if config.pilot > 0.0:
		return true
	if config.company_choice != "":
		return true
	if not config.lobby:
		return true
	return false


func __lobby_pick_pending():
	return __pick_company_pending and config.role == "client"


func __hide_lobby():
	lobby_lib.hide(__lobby_panel())


# The address box takes "host" or "host:port". A wrong port is not fatal here: the connection simply
# never comes up and the log says so, which is easier to explain than a dialog.
func __use_address(text):
	var parts = String(text).split(":")
	var host = parts[0]
	if host == "":
		return
	config.host = host
	if parts.size() > 1 and parts[1] != "":
		config.port = int(parts[1])


# The single "Multiplayer" entry in the main menu: it only reveals host and join.
func menu_multiplayer_pressed():
	var menu = automation.find_by_scene(get_tree().get_root(), MENU_SCENE)
	if menu == null:
		return
	var visible = not menu_lib.options_visible(menu)
	menu_lib.set_options_visible(menu, visible)
	coop_log.info(config.log_name, "menu: multiplayer options %s" % [
		"shown" if visible else "hidden"
	])


# --- in-game multiplayer panel ------------------------------------------
#
# The button only exists while a game is loaded, so a single-player session never sees it, and the
# panel behind it is the only way to move money, technology or a game's IP between the players.

func __patch_game_ui():
	if __elapsed < __next_ui_at:
		return
	__next_ui_at = __elapsed + 1.0
	if not models.is_loaded():
		return
	var gui = automation.find_by_scene(get_tree().get_root(), GAME_GUI_SCENE)
	if gui == null:
		return
	var bar = null
	var game_menu = automation.find_by_scene(get_tree().get_root(), GAME_MENU_SCENE)
	if game_menu != null:
		var options_button = game_menu.find_node("options", true, false)
		if options_button != null:
			bar = options_button.get_parent()
	if ui_lib.patch_game(gui, bar, self, config.log_name, not __game_ui_warned):
		__game_panel = gui.find_node(ui_lib.PANEL_NODE, true, false)
		ui_lib.layout(__game_panel, __layout_rect(gui).size)
	else:
		__game_ui_warned = true


func ui_toggle_panel():
	if __game_panel == null:
		return
	coop_log.info(config.log_name, "ui: toggle asked, visible=%s at %s" % [
		String(__game_panel.is_visible()), String(OS.get_ticks_msec())
	])
	if __game_panel.is_visible():
		__game_panel.hide()
		coop_log.info(config.log_name, "ui: panel closed")
	else:
		ui_refresh()
		__game_panel.show()
		coop_log.info(config.log_name, "ui: panel opened")


func ui_close_panel():
	if __game_panel != null:
		__game_panel.hide()
		coop_log.info(config.log_name, "ui: panel closed")


func ui_refresh():
	if __game_panel == null:
		return
	ui_lib.layout(__game_panel, __screen_rect().size)
	ui_lib.refresh(__game_panel, self, config.log_name)
	ui_lib.set_status(__game_panel, __ui_status_text())


func __ui_status_text():
	var others = ui_other_players().size()
	if config.role == "off":
		return "single player: start or host a game to play with someone"
	if __link == null:
		return "%s, not connected yet" % [config.role]
	return "%s as %s, %s other player(s) here" % [config.role, __local_id(), String(others)]


func ui_other_players():
	var ids = []
	if not models.is_loaded() or not models.has_model("concurrent"):
		return ids
	var live = models.get_model("concurrent").get_concurrent()
	if live == null:
		return ids
	for rival_id in live:
		var rival = String(rival_id)
		if rival == __local_id():
			continue
		if company.is_player_company(rival):
			ids.push_back(rival)
	return ids


# The office a project is developed in: the player's selected studio, or their first one.
func company_id_for_office():
	if not models.is_loaded() or not models.has_model("studio"):
		return ""
	var studio_model = models.get_model("studio")
	if studio_model.has_method("get_selected_studio_id"):
		var selected = studio_model.get_selected_studio_id()
		if selected != null and String(selected) != "":
			return String(selected)
	return company.first_player_studio()


func ui_player_name(player_id):
	var record = company.load_from_world(player_id)
	if record != null and record.has("name") and String(record["name"]) != "":
		return String(record["name"])
	return String(player_id)


func ui_player_labels(ids):
	var labels = []
	for player_id in ids:
		labels.push_back(ui_player_name(player_id))
	return labels


# Technology for this game is an unlocked genre, so a gift is one of ours that the other player's
# company record does not list.
func ui_missing_genres(other_id):
	var out = []
	if not models.has_model("game-type"):
		return out
	var gametype = models.get_model("game-type")
	var mine = gametype.get_unlocked_game_types()
	var theirs = {}
	var record = company.load_from_world(String(other_id))
	if record != null and record.has("genres") and record["genres"] != null:
		for genre_id in record["genres"]:
			theirs[String(genre_id)] = true
	for genre_id in mine:
		if theirs.has(String(genre_id)):
			continue
		var label = String(genre_id)
		if gametype.type_static_data.has(String(genre_id)):
			label = String(gametype.type_static_data[String(genre_id)].label)
		out.push_back({id = String(genre_id), label = label})
	return out


func ui_published_games():
	var out = []
	if not models.has_model("game"):
		return out
	var catalog = models.get_model("game").get_data()["catalog"]
	if not catalog.has("published") or catalog["published"] == null:
		return out
	for game_id in catalog["published"]:
		var game = catalog["published"][game_id]
		var name = String(game_id)
		if game != null and game.has("name"):
			name = String(game["name"])
		out.push_back({id = String(game_id), name = name})
	return out


func ui_pending_offers():
	var me = __local_id()
	var out = []
	for offer in trade.pending_for(me):
		if dict_lib.text(offer, "to", "") == me:
			out.push_back(offer)
	return out


func ui_offer_money():
	var target = ui_lib.selected_player(__game_panel)
	if target == "":
		ui_lib.set_status(__game_panel, "no other player to give to yet")
		return
	var typed = ui_lib.amount_text(__game_panel)
	var amount = ui_lib.parse_amount(typed)
	coop_log.info(config.log_name, "ui: offer money asked with [%s] at %s" % [
		typed, String(OS.get_ticks_msec())
	])
	if amount <= 0:
		ui_lib.set_status(__game_panel, "enter an amount like 2500, 2k or 5m")
		coop_log.info(config.log_name, "ui: refused the amount [%s]" % [typed])
		return
	offer_money(target, amount)
	ui_lib.set_status(__game_panel, "offered %s to %s" % [String(amount), ui_player_name(target)])
	ui_refresh()


func ui_offer_technology():
	var target = ui_lib.selected_player(__game_panel)
	if target == "":
		ui_lib.set_status(__game_panel, "no other player to give to yet")
		return
	var genre = ui_lib.selected_genre(__game_panel)
	if genre == "":
		ui_lib.set_status(__game_panel, "they already know everything we do")
		return
	offer_technology(target, genre)
	ui_lib.set_status(__game_panel, "offered a technology to %s" % [ui_player_name(target)])
	ui_refresh()


func ui_offer_ip():
	var target = ui_lib.selected_player(__game_panel)
	if target == "":
		ui_lib.set_status(__game_panel, "no other player to give to yet")
		return
	var game_id = ui_lib.selected_game(__game_panel)
	if game_id == "":
		ui_lib.set_status(__game_panel, "no published game to give")
		return
	offer_ip(target, game_id)
	ui_lib.set_status(__game_panel, "offered the IP of %s" % [game_id])
	ui_refresh()


func ui_accept_offer(offer_id):
	var offer = __find_offer(String(offer_id))
	if offer == null:
		ui_lib.set_status(__game_panel, "that offer is gone")
		return
	coop_log.info(config.log_name, "ui: taking %s" % [trade.describe(offer)])
	__accept_offer(offer)
	ui_refresh()


func ui_refuse_offer(offer_id):
	var offer = __find_offer(String(offer_id))
	if offer == null:
		ui_lib.set_status(__game_panel, "that offer is gone")
		return
	coop_log.info(config.log_name, "ui: refusing %s" % [trade.describe(offer)])
	__reject_offer(offer)
	ui_refresh()


# Drives the panel the way a player would: opens it from the button, then presses the buttons. What it
# asserts is what the panel shows and what the world did as a result.
func __run_ui_test():
	if __ui_tested or config.ui_test <= 0.0 or __elapsed < config.ui_test:
		return
	if not models.is_loaded() or __game_panel == null:
		return
	__ui_tested = true
	__ui_layout = __layout_rect(automation.find_by_scene(get_tree().get_root(), GAME_GUI_SCENE))
	var fails = 0
	var button = null
	var game_menu = automation.find_by_scene(get_tree().get_root(), GAME_MENU_SCENE)
	if game_menu != null:
		button = game_menu.find_node(ui_lib.BUTTON_NODE, true, false)
	fails += __ui_check("the Multiplayer button is in the game menu bar", button != null, "")

	if button != null:
		button.emit_signal("pressed")
	fails += __ui_check("the panel opens from the button", __game_panel.is_visible(),
		String(__game_panel.get_global_rect()))

	var window = __game_panel.find_node("window", true, false)
	var on_screen = false
	if window != null and window.has_method("get_global_rect"):
		var screen = __screen_rect()
		on_screen = screen.intersects(window.get_global_rect())
	fails += __ui_check("the panel is inside the window", on_screen,
		String(window.get_global_rect()) if window != null else "no window")

	var players = __game_panel.find_node("players", true, false)
	fails += __ui_check("the panel lists the other player", players != null and players.get_item_count() > 0,
		String(players.get_item_count()) + " player(s)" if players != null else "no list")

	# The amount box has to read what players actually type, and must never accept a negative.
	fails += __ui_check("2k reads as 2000", ui_lib.parse_amount("2k") == 2000,
		String(ui_lib.parse_amount("2k")))
	fails += __ui_check("5m reads as 5000000", ui_lib.parse_amount("5M") == 5000000,
		String(ui_lib.parse_amount("5M")))
	fails += __ui_check("2500 reads as 2500", ui_lib.parse_amount(" 2500 ") == 2500,
		String(ui_lib.parse_amount(" 2500 ")))
	fails += __ui_check("a negative amount is refused", ui_lib.parse_amount("-500") < 0,
		String(ui_lib.parse_amount("-500")))
	fails += __ui_check("a negative with a unit is refused", ui_lib.parse_amount("-2k") < 0,
		String(ui_lib.parse_amount("-2k")))
	fails += __ui_check("nonsense is refused", ui_lib.parse_amount("abc") < 0,
		String(ui_lib.parse_amount("abc")))

	# Money: the button must produce a real offer, not just a status line.
	var before = __ui_offer_count()
	ui_offer_money()
	var after = __ui_offer_count()
	fails += __ui_check("pressing Offer money makes an offer", after > before,
		"%s -> %s offer(s)" % [String(before), String(after)])

	# A technology row and an IP row must exist and be populated from the models.
	fails += __ui_check("the panel offers a technology row",
		__game_panel.find_node("genres", true, false) != null, "")
	fails += __ui_check("the panel offers an IP row",
		__game_panel.find_node("games", true, false) != null, "")

	# An offer waiting for us must be listed, and its Take button must actually settle it.
	var waiting = ui_pending_offers()
	if waiting.size() == 0:
		coop_log.info(config.log_name, "ui-check SKIP nothing was waiting for us to take")
	else:
		var offer_id = dict_lib.text(waiting[0], "id", "")
		var take = __game_panel.find_node("take_1", true, false)
		fails += __ui_check("a waiting offer is listed with a Take button", take != null,
			dict_lib.text(waiting[0], "kind", "?"))
		if take != null:
			take.emit_signal("pressed")
		fails += __ui_check("pressing Take settles the offer",
			trade.is_settled(offer_id), offer_id)

	# And the Close button puts it away again.
	var close = __game_panel.find_node("close", true, false)
	fails += __ui_check("the panel has a Close button", close != null, "")
	if close != null:
		close.emit_signal("pressed")
	fails += __ui_check("Close hides the panel", not __game_panel.is_visible(), "")

	coop_log.info(config.log_name, "ui-check: %s (%s failure(s))" % [
		"ALL OK" if fails == 0 else "FAILURES", String(fails)
	])


func __ui_offer_count():
	if not models.has_model("coop-state"):
		return 0
	var entry = models.get_model("coop-state").get_player(__local_id())
	if entry == null or not entry.has("offers") or entry["offers"] == null:
		return 0
	return entry["offers"].size()


func __ui_check(what, ok, detail):
	coop_log.info(config.log_name, "ui-check %s %s%s" % [
		"PASS" if ok else "FAIL", what,
		(" (" + String(detail) + ")") if String(detail) != "" else ""
	])
	return 0 if ok else 1


func __patch_menu():
	if __menu_patched:
		return
	var menu = automation.find_by_scene(get_tree().get_root(), MENU_SCENE)
	if menu == null:
		return
	if menu_lib.patch(menu, self, config.log_name, not __menu_warned):
		__menu_patched = true
	else:
		__menu_warned = true


# Ground truth for where the buttons can go: logs the live menu's node tree, which is the only
# reliable way to learn the paths this game uses (the retail scenes are binary in the pack).
# Reproduces the reported case without needing a hand-made save: before the company is placed, the
# player's office is forced into the state that was wrong, and then the normal join path has to come out
# with one usable office.
#
#   --coop-officetest=unfit      an office on a building that is not a home, with no furniture
#   --coop-officetest=empty      an office on a home building with an empty room (no desk, no computer)
#   --coop-officetest=rival      an office on a tile another company already owns
func __run_office_test():
	if config.office_test == "":
		return
	__plant_office_for_test()


# Reproduces the reported case: the player arrives already holding an office that is not fit to work in.
#
#   --coop-officetest=unfit   an office on a building that is not a home, with no furniture
#   --coop-officetest=empty   an office on a home building with an empty room (no desk, no computer)
#   --coop-officetest=rival   an office on a tile another company already owns
#
# Called from __finish_join just before the company is placed, because the world merge empties the
# studio model and would erase anything planted earlier.
func __plant_office_for_test():
	if __office_tested or config.office_test == "" or not models.is_loaded():
		return
	var studio_model = models.get_model("studio")
	var map = models.get_model("map")
	var concurrent = models.get_model("concurrent")
	if studio_model == null or map == null or concurrent == null:
		return
	__office_tested = true

	var wanted = String(config.office_test)
	var tile = null
	if wanted == "unfit":
		# Buildings the game never allows a first office in.
		for type in ["theater", "convention", "university"]:
			var found = map.get_tile_type(type)
			if found.size() > 0:
				tile = found[0]
				break
	elif wanted == "full":
		# Nothing left to move into: every home building is claimed and no office is held yet, which is
		# the state in which the only way to start is to build on an empty lot.
		var marked = 0
		for type in company.HOME_BUILDING_TYPES:
			for candidate in map.get_tile_type(type):
				if candidate.metadata == null:
					candidate.metadata = {}
				candidate.metadata["owned"] = true
				marked += 1
		var data2 = studio_model.get_data()
		if data2.has("list") and data2["list"] != null:
			for studio_id in data2["list"].keys():
				if not concurrent.is_studio_owned(studio_id):
					studio_model.close_studio(studio_id)
		coop_log.info(config.log_name, "officetest: claimed %s home building(s) and cleared our offices" % [
			String(marked)
		])
		company.log_studios("officetest full")
		__office_tested = true
		return
	elif wanted == "rival":
		for candidate in map.get_tile_type("apartment"):
			if concurrent.is_studio_owned(String(candidate.id)):
				tile = candidate
				break
	else:
		var apartments = map.get_tile_type("apartment")
		if apartments.size() > 0:
			tile = apartments[0]

	if tile == null:
		coop_log.warning(config.log_name, "officetest: no suitable tile for %s" % [wanted])
		return

	var tile_id = String(tile.id)
	var date = models.get_model("date").get_date()
	# Area far larger than a default home, which is the shape of the reported case.
	var studio = studio_model.create_studio("Handmade", 400, tile_id, "buy", date)
	studio_model.open_studio(studio, false)
	if wanted == "rival":
		var live = concurrent.get_concurrent()
		if live != null and live.size() > 0:
			concurrent.buy_studio(String(live.keys()[0]), tile_id)
	coop_log.info(config.log_name, "officetest: planted a %s office on tile %s (%s, %s areas)" % [
		wanted, tile_id.substr(0, 8), String(tile.tile), String(studio["area"])
	])
	company.log_studios("officetest planted")


# Which of the game's own "technology" lists differ between two players. Used to decide what a
# technology gift should actually move, instead of assuming.
# Test hook: buy one technology the way the game's research does, so a technology transfer has
# something to move. "next" picks the first genre this company has not unlocked yet.
#
#   --coop-research=next
func __run_research():
	if __research_done or config.research == "":
		return
	if not models.is_loaded() or __elapsed < 14.0:
		return
	__research_done = true
	var gametype = models.get_model("game-type")
	var target = String(config.research)
	if target == "next":
		target = ""
		for type_id in gametype.type_static_data:
			if not gametype.is_game_type_unlocked(type_id):
				target = String(type_id)
				break
	if target == "":
		coop_log.warning(config.log_name, "research: every genre is already known here")
		return
	gametype.unlock_game_type(target, true)
	gametype.is_game_type_unlocked(target)
	coop_log.info(config.log_name, "research: unlocked the %s technology" % [target])


# Which of the game's own "technology" lists differ between two players. Used to decide what a
# technology gift should actually move, instead of assuming.
func __run_tech_probe():
	if __tech_probed or not config.tech_probe or not models.is_loaded() or __elapsed < 20.0:
		return
	__tech_probed = true
	if not models.has_model("game-type") or not models.has_model("game-engine"):
		coop_log.warning(config.log_name, "techprobe: models not ready")
		return
	var gametype = models.get_model("game-type")
	var static_types = gametype.type_static_data
	var unlocked = gametype.get_unlocked_game_types()
	var free = 0
	var paid = 0
	for type_id in static_types:
		if int(gametype.get_type_cost(type_id)) > 0:
			paid += 1
		else:
			free += 1
	coop_log.info(config.log_name, "techprobe: genres static=%s free=%s paid=%s unlocked_here=%s" % [
		String(static_types.size()), String(free), String(paid), String(unlocked.size())
	])
	if unlocked.size() > 0:
		coop_log.info(config.log_name, "techprobe: first unlocked genre %s, last %s" % [
			String(unlocked[0]), String(unlocked[unlocked.size() - 1])
		])
	var engine = models.get_model("game-engine")
	var features = engine.get_available_features_ids()
	coop_log.info(config.log_name, "techprobe: engine features available here=%s of %s in the list" % [
		String(features.size()) if features != null else "0",
		String(engine.get_feature_list().size())
	])


# Everything the two reported problems could possibly be about, written out in full: this player's
# offices with what is in each one, the other players' offices as they appear here, the servers and
# consoles the player's own company holds, and the platform/console model split between the two.
func __run_dump():
	if config.dump <= 0.0 or __dumped or not models.is_loaded() or __elapsed < config.dump:
		return
	__dumped = true
	coop_log.info(config.log_name, "dump: ---- as %s (%s) ----" % [__local_id(), config.role])

	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var map = models.get_model("map")
	var item_model = models.get_model("item")
	var data = studio_model.get_data()

	coop_log.info(config.log_name, "dump: ---- my offices ----")
	if data.has("list") and data["list"] != null:
		for studio_id in data["list"]:
			var studio = data["list"][studio_id]
			var tile = map.get_tile_by_id(studio_id)
			var desks = 0
			var computers = 0
			var items = 0
			var seated = 0
			if studio != null and studio.has("items") and studio["items"] != null:
				for item_id in studio["items"]:
					var item = studio["items"][item_id]
					if item == null:
						continue
					items += 1
					var type = String(item_model.get_type(item))
					if type == "desk":
						desks += 1
						if item_model.get_computer(item) != null:
							computers += 1
						if item.has("employee_id") and item["employee_id"] != null:
							seated += 1
			coop_log.info(config.log_name, "dump:   %s name=[%s] tile=%s area=%s rival_owned=%s "
				% [String(studio_id).substr(0, 8), String(studio["name"]) if studio != null else "?",
					String(tile.tile) if tile != null else "missing",
					String(studio["area"]) if studio != null else "?",
					String(concurrent.is_studio_owned(studio_id))]
				+ "items=%s desks=%s computers=%s seated=%s type=%s" % [String(items), String(desks),
					String(computers), String(seated), String(studio["type"]) if studio != null else "?"])

	coop_log.info(config.log_name, "dump: ---- other players' offices as I see them ----")
	var live = concurrent.get_concurrent()
	if live != null:
		for rival_id in live:
			var rival = String(rival_id)
			if not company.is_player_company(rival):
				continue
			var entry = live[rival]
			var tiles = entry["studio"] if entry.has("studio") and entry["studio"] != null else []
			var parts = []
			for tile_id in tiles:
				var tile = map.get_tile_by_id(tile_id)
				var studio = studio_model.get_studio_by_id(tile_id)
				parts.push_back("%s(%s%s)" % [String(tile_id).substr(0, 8),
					String(tile.tile) if tile != null else "missing",
					", has my studio" if studio != null else ""])
			coop_log.info(config.log_name, "dump:   %s [%s] offices=%s %s" % [
				rival, company.catalogue_name(rival), String(tiles.size()), company.join(parts, " ")
			])

	coop_log.info(config.log_name, "dump: ---- staff ----")
	if models.has_model("staff"):
		var staff_data = models.get_model("staff").get_data()
		for specialty in staff_data.keys():
			var group = staff_data[specialty]
			if group == null or typeof(group) != TYPE_DICTIONARY:
				continue
			var parts = []
			for employee_id in group:
				var employee = group[employee_id]
				if employee == null or not typeof(employee) == TYPE_DICTIONARY:
					continue
				parts.push_back("%s(studio=%s item=%s)" % [
					String(employee_id).substr(0, 8),
					String(employee["studio_id"]).substr(0, 8) if employee.has("studio_id") and employee["studio_id"] != null else "none",
					String(employee["item_id"]).substr(0, 8) if employee.has("item_id") and employee["item_id"] != null else "none"
				])
			coop_log.info(config.log_name, "dump:   %s: %s %s" % [
				String(specialty), String(group.size()), company.join(parts, " ")
			])

	coop_log.info(config.log_name, "dump: ---- servers and consoles ----")
	if models.has_model("server"):
		var server = models.get_model("server")
		coop_log.info(config.log_name, "dump:   server capacity=%s usage=%s online_players=%s rent=%s" % [
			String(server.get_capacity()), String(server.get_usage()),
			String(server.get_online_players()), String(server.is_server_rent_enabled())
		])
	if models.has_model("custom-platform"):
		var mine = models.get_model("custom-platform")
		var released = mine.list_platform_released() if mine.has_method("list_platform_released") else []
		var announced = mine.list_platform_announced() if mine.has_method("list_platform_announced") else []
		coop_log.info(config.log_name, "dump:   my platforms released=%s announced=%s" % [
			String(released.size()), String(announced.size())
		])
		for entry in released:
			coop_log.info(config.log_name, "dump:     mine [%s] id=%s" % [
				String(entry.name) if entry.has("name") else "?", String(entry.id) if entry.has("id") else "?"
			])
	if models.has_model("concurrent-platform"):
		var theirs = models.get_model("concurrent-platform")
		var all = theirs.list_platform_released()
		coop_log.info(config.log_name, "dump:   platforms owned by rivals=%s" % [String(all.size())])
		for entry in all:
			coop_log.info(config.log_name, "dump:     rival [%s] owner=%s id=%s" % [
				String(entry.name) if entry.has("name") else "?",
				String(entry.concurrent_id) if entry.has("concurrent_id") else "?",
				String(entry.id) if entry.has("id") else "?"
			])


func __run_menu_dump():
	if __menu_dumped or config.menu_dump <= 0.0 or __elapsed < config.menu_dump:
		return
	var menu = automation.find_by_scene(get_tree().get_root(), MENU_SCENE)
	if menu == null:
		return
	__menu_dumped = true
	coop_log.info(config.log_name, "tree: menu root is %s" % [menu.get_name()])
	__dump_node(menu, 1)


func __dump_node(node, depth):
	var pad = ""
	for i in range(depth):
		pad += ".."
	var extra = ""
	if node.has_method("get_text"):
		extra = " text=[%s]" % [String(node.get_text())]
	var kind = "Node"
	if node.has_method("get_class"):
		kind = String(node.get_class())
	coop_log.info(config.log_name, "tree: %s%s <%s>%s" % [pad, String(node.get_name()), kind, extra])
	for child in node.get_children():
		__dump_node(child, depth + 1)


# Checks the buttons really are on screen where a player can click them, then clicks one. Layout is
# read back from the live controls, so this is evidence rather than a guess from a screenshot.
func __run_menu_test():
	if __menu_checked or config.menu_test <= 0.0 or __elapsed < config.menu_test:
		return
	var menu = automation.find_by_scene(get_tree().get_root(), MENU_SCENE)
	if menu == null:
		return
	if not __menu_patched:
		coop_log.error(config.log_name, "menu-check: FAIL buttons were never added")
		__menu_checked = true
		return
	__menu_checked = true

	var entry = menu_lib.entry(menu)
	var button = menu_lib.press_target(menu)
	if entry == null or button == null:
		coop_log.error(config.log_name, "menu-check: FAIL there is no multiplayer entry")
		return
	__ui_layout = __layout_rect(entry)

	var fails = 0
	fails += __check_button("multiplayer entry", entry)
	fails += __check_button("multiplayer button", button)

	var label = entry.find_node("value", true, false)
	var label_text = ""
	if label != null and label.has_method("get_text"):
		label_text = String(label.get_text())
	coop_log.info(config.log_name, "menu-check: %s the entry says [%s]" % [
		"OK" if label_text == menu_lib.LABEL_TEXT else "FAIL", label_text
	])
	if label_text != menu_lib.LABEL_TEXT:
		fails += 1

	# Styled like the game's own entry and sitting to its left, as asked.
	var continue_entry = menu.find_node("continue", true, false)
	if continue_entry == null:
		coop_log.info(config.log_name, "menu-check: FAIL the game's own continue entry is missing")
		fails += 1
	else:
		var theirs = __rect_of(continue_entry)
		var ours = __rect_of(entry)
		var left_of = ours.pos.x < theirs.pos.x
		coop_log.info(config.log_name, "menu-check: %s multiplayer (%s) sits left of continue (%s)" % [
			"OK" if left_of else "FAIL", String(ours), String(theirs)
		])
		if not left_of:
			fails += 1
		var same_size = ours.size == theirs.size
		coop_log.info(config.log_name, "menu-check: %s same size as continue (%s vs %s)" % [
			"OK" if same_size else "FAIL", String(ours.size), String(theirs.size)
		])
		if not same_size:
			fails += 1
		var icon = entry.find_node("icon", true, false)
		var has_texture = icon != null and icon.has_method("get_texture") and icon.get_texture() != null
		coop_log.info(config.log_name, "menu-check: %s the entry has an icon" % [
			"OK" if has_texture else "FAIL"
		])
		if not has_texture:
			fails += 1

	var screen = __screen_rect()

	# Host and join are behind the entry: hidden until it is pressed, as asked.
	var hidden_before = not menu_lib.options_visible(menu)
	coop_log.info(config.log_name, "menu-check: %s host/join are hidden until the button is pressed" % [
		"OK" if hidden_before else "FAIL"
	])
	if not hidden_before:
		fails += 1

	button.emit_signal("pressed")
	yield(get_tree(), "idle_frame")
	var shown = menu_lib.options_visible(menu)
	coop_log.info(config.log_name, "menu-check: %s pressing multiplayer revealed host and join" % [
		"OK" if shown else "FAIL"
	])
	if not shown:
		fails += 1

	# And pressing it again puts them away again.
	button.emit_signal("pressed")
	coop_log.info(config.log_name, "menu-check: %s a second press hides them again" % [
		"OK" if not menu_lib.options_visible(menu) else "FAIL"
	])
	if menu_lib.options_visible(menu):
		fails += 1
	button.emit_signal("pressed")

	var host = menu.find_node("host", true, false)
	var join = menu.find_node("join", true, false)
	if host == null or join == null:
		coop_log.info(config.log_name, "menu-check: FAIL host/join options are missing")
		fails += 1
	else:
		fails += __check_button("host option", host)
		fails += __check_button("join option", join)
		var host_rect = __rect_of(host)
		var join_rect = __rect_of(join)
		var apart = host_rect.pos.y != join_rect.pos.y
		coop_log.info(config.log_name, "menu-check: %s host and join are stacked, not on top of each other" % [
			"OK" if apart else "FAIL"
		])
		if not apart:
			fails += 1
		coop_log.info(config.log_name, "menu-check: %s the options are on screen (%s, %s)" % [
			"OK" if screen.intersects(host_rect) and screen.intersects(join_rect) else "FAIL",
			String(host_rect), String(join_rect)
		])
		if not (screen.intersects(host_rect) and screen.intersects(join_rect)):
			fails += 1

	# The click path itself: emitting the signal is exactly what the UI does.
	host.emit_signal("pressed")
	coop_log.info(config.log_name, "menu-check: %s host press set role=%s wanted=%s" % [
		"OK" if config.role == "host" else "FAIL", config.role, String(__network_wanted)
	])
	if config.role != "host":
		fails += 1

	coop_log.info(config.log_name, "menu-check: %s (%d failure(s))" % [
		"ALL OK" if fails == 0 else "FAILURES", fails
	])

func __rect_of(control):
	if not control.has_method("get_global_rect"):
		return Rect2(0, 0, 0, 0)
	return control.get_global_rect()



# The coordinates the UI is laid out in. The game draws at a fixed size (1600x900) and lets the engine
# stretch it, so the window size is *not* the space these rects are in - comparing against it reported
# every control as off screen. Walking up from a control finds the stretched container.
func __layout_rect(node):
	var best = Rect2(Vector2(0, 0), Vector2(0, 0))
	var cursor = node
	while cursor != null:
		if cursor.has_method("get_global_rect"):
			var rect = cursor.get_global_rect()
			if rect.size.x > best.size.x and rect.size.y > best.size.y:
				best = rect
		cursor = cursor.get_parent()
	return best


func __screen_rect():
	if __ui_layout.size.x > 0.0 and __ui_layout.size.y > 0.0:
		return __ui_layout
	return Rect2(Vector2(0, 0), OS.get_window_size())

func __check_button(label, button):
	var fails = 0
	var visible = true
	if button.has_method("is_visible"):
		visible = button.is_visible()
	var rect = __rect_of(button)
	var screen = __screen_rect()
	var on_screen = screen.intersects(rect)
	var ok = visible and rect.size.x > 0.0 and rect.size.y > 0.0 and on_screen
	coop_log.info(config.log_name, "menu-check: %s %s button visible=%s rect=%s on_screen=%s" % [
		"OK" if ok else "FAIL", label, String(visible), String(rect), String(on_screen)
	])
	if not ok:
		fails += 1
	return fails


# Sends one transfer to the other player, so the whole offer/accept path can be observed in a log:
#
#   --coop-gift=money:100000        give this much money
#   --coop-gift=tech:<genre>        give an unlocked game genre
#   --coop-gift=ip:<game id>        give the IP of one of our published games
#
# The recipient runs --coop-offer-auto and takes it; both sides then log what they applied.
func __run_gift():
	if config.gift == "" or __gift_sent:
		return
	if not __gift_armed:
		__gift_armed = true
		coop_log.info(config.log_name, "gift: armed with [%s]" % [config.gift])
	if not models.is_loaded() or __elapsed < 25.0:
		return
	var others = []
	var live = models.get_model("concurrent").get_concurrent()
	if live == null:
		coop_log.info(config.log_name, "gift: waiting, no competitors yet")
		return
	for rival_id in live:
		var rival = String(rival_id)
		if company.is_player_company(rival) and rival != __local_id():
			others.push_back(rival)
	if others.size() == 0:
		if not __gift_warned:
			__gift_warned = true
			coop_log.info(config.log_name, "gift: waiting, no other player among %s rivals (me=%s)" % [
				String(live.size()), __local_id()
			])
		return

	__gift_sent = true
	var target = others[0]
	var parts = config.gift.split(":")
	var kind = parts[0]
	var value = parts[1] if parts.size() > 1 else ""

	if kind == "money":
		offer_money(target, int(value))
	elif kind == "tech":
		var genre = __pick_technology(value, target)
		if genre == "":
			__gift_skipped = true
			return
		offer_technology(target, genre)
	elif kind == "ip":
		offer_ip(target, __pick_ip(value))
	else:
		coop_log.warning(config.log_name, "gift: unknown kind %s" % [kind])


# "last" takes the most recently unlocked game genre this company knows. "missing" takes one the other
# player's company record shows they do not have: with both companies at the same date that is only
# possible when the giver bought a genre ahead of the date, and there is nothing to give otherwise.
func __pick_technology(value, other_id = ""):
	if value != "last" and value != "missing":
		return value
	var gametype = models.get_model("game-type")
	var mine = gametype.get_unlocked_game_types()
	if mine == null or mine.size() == 0:
		return ""
	if value == "missing" and other_id != "":
		var theirs = {}
		var record = company.load_from_world(other_id)
		if record != null and record.has("genres") and record["genres"] != null:
			for genre_id in record["genres"]:
				theirs[String(genre_id)] = true
		for genre_id in mine:
			if not theirs.has(String(genre_id)):
				return String(genre_id)
		coop_log.info(config.log_name, "trade: %s already knows every genre we do (%s)" % [
			other_id, String(mine.size())
		])
		return ""
	return String(mine[mine.size() - 1])


# "first" takes whatever title we publish, so a test does not have to know a game id in advance.
func __pick_ip(value):
	if value != "first":
		return value
	var published = models.get_model("game").get_data()["catalog"]["published"]
	if published == null:
		return ""
	for game_id in published:
		return String(game_id)
	return ""


func __step(what):
	if config.trace:
		coop_log.info(config.log_name, "step: " + what)


func __apply_clock(message):
	# A client may receive clocks before its own world has finished loading, and the game's model
	# layer is not usable until then: touching it half-built kills the process.
	if not models.is_loaded():
		return

	__step("clock: get date model")
	var date_model = models.get_model("date")
	__step("clock: read speed")
	var speed = dict_lib.number(message, "speed", 0)
	__step("clock: speed is %s, model says %s" % [String(speed), String(date_model.get_speed_index())])
	if speed > 0 and speed != date_model.get_speed_index():
		__step("clock: setting speed")
		date_model.set_speed(speed)
		coop_log.info(config.log_name, "clock: speed set to %s" % [String(speed)])

	# Keep the two machines on the same week. The host is authoritative, so a client that has
	# drifted is corrected here rather than being allowed to run its own calendar.
	if config.role == "client":
		__step("clock: reading raw_date")
		var host_raw = dict_lib.number(message, "raw_date", date_model.get_raw_date())
		var local_raw = int(date_model.get_raw_date())
		__step("clock: host_raw=%s local=%s" % [String(host_raw), String(local_raw)])
		if host_raw != local_raw:
			__step("clock: setting raw date")
			__set_date(date_model, host_raw)
			# A clock message arrives every second, so this is the *usual* way a client is corrected -
			# more common than the per-frame pull-back in __enforce_host_clock(). Correcting the date
			# here without this discard was a second, independent path to the 0xae5633 crash: the client
			# kept the boundary signals it had earned at a week it no longer held, plus a nearly-full
			# `_tick`, and re-crossed the same month or year boundary a frame later to replay the cycle.
			if host_raw < local_raw:
				__discard_overshoot(date_model)

	__step("clock: pausing or resuming")
	__pause(dict_lib.flag(message, "paused", false))
	# The world's time, remembered so __enforce_host_clock() can hold this machine to it every frame.
	__host_raw = dict_lib.number(message, "raw_date", __host_raw)
	__host_speed = speed
	__host_paused = dict_lib.flag(message, "paused", false)
	__step("clock: done")


# Time is shared, and this machine never gets to run ahead of it.
#
# A client's date model is its own object: it keeps ticking between clock messages and its UI keeps
# offering pause and speed. This runs every frame, so a date that gets ahead of the world is pulled back
# immediately and a local press becomes a request rather than a local change.
func __enforce_host_clock():
	if config.role == "host" and models.is_loaded():
		# The game pauses itself when a project is released and no studio director is hired
		# (models/game.gd release_game). In a shared world that would freeze the other player's game
		# because one player's project finished, so the setting is kept off for the session.
		if globals_manager.get("auto_pause"):
			globals_manager.set("auto_pause", false)
			coop_log.info(config.log_name, "clock: auto_pause turned off, a finished project must not "
				+ "freeze the other player's game")
		# The host's company is never placed by open_first_studio, so the "one home office" clean-up runs
		# here too. It waits for the game to have opened its own first studio, which happens after the
		# models load, and re-checks for a while: collapsing once at the wrong moment leaves the pile.
		if not __host_office_cleaned and __elapsed > 25.0:
			var closed = company.ensure_single_home("")
			var homes = company.home_office_count()
			coop_log.info(config.log_name, "office: host clean-up closed %s, %s home office(s) left" % [
				String(closed), String(homes)
			])
			if homes <= 1:
				__host_office_cleaned = true
		# A game started from the New Game dialogue has no company name until the player types one, so a
		# fresh host registered with the other player as "" - a nameless rival in their rival list. The
		# name the session was started with is the one thing the player's identity already carries, and it
		# is what a client uses for itself, so the host takes the same one.
		# The host's own name.
		#
		# A game started from the New Game dialogue takes whatever name the *game's shared settings* last
		# remembered, and those settings are per-machine, not per-instance: a host started after a client
		# session came up carrying the client's company name, and published itself under it. So the
		# session name wins whenever it was given explicitly, which it is on every launch.
		if not __host_named and models.has_model("player"):
			var current = String(models.get_model("player").get_data().company_name)
			if current == "" or config.name != "":
				coop_log.info(config.log_name, "net: " + company.name_self(config.name) +
					" (was [%s])" % [current])
				__host_named = true
		__watch_pause()
		return
	if config.role != "client" or __host_raw < 0 or not models.is_loaded():
		return
	__watch_pause()
	__hold_own_server()
	var date_model = models.get_model("date")

	var local_speed = date_model.get_speed_index()
	var local_paused = bool(date_model.paused)

	# The first moment this machine's clock matches the world is the moment a press becomes meaningful.
	if __clock_settled_at > 1e11:
		if local_speed == __host_speed and local_paused == __host_paused:
			__clock_settled_at = __elapsed + CLOCK_SETTLE_SECONDS
			coop_log.info(config.log_name, "clock: settled, a press counts from %s" % [
				String(CLOCK_SETTLE_SECONDS)
			])

	# The player pressed something. That is a request to the world, not a local change: it is sent on,
	# and the world's current value is held until the answer comes back.
	#
	# Only a real press counts. The date model starts life paused and frozen (`var paused = true` in
	# models/date.gd), and it freezes again whenever the game leaves its plain view state, so treating
	# every difference as a press made the two machines trade pause requests forever - each one adopting
	# the other's value a frame later, then reading the difference as the next press. A press is only
	# what happens while the game is in view mode and the world has already been joined.
	var pressed = false
	if local_speed != __host_speed or local_paused != __host_paused:
		pressed = __client_could_have_pressed()
		coop_log.info(config.log_name, "clock: mismatch local(paused=%s speed=%s) world(paused=%s speed=%s) "
			% [String(local_paused), String(local_speed), String(__host_paused), String(__host_speed)]
			+ "freeze=%s pressed=%s" % [String(__date_frozen(date_model)), String(pressed)])
		if pressed:
			__request_time(local_speed, local_paused)
		# Either way this machine adopts the world's value: it never keeps its own.
		if local_speed != __host_speed and __host_speed > 0:
			date_model.set_speed(__host_speed)
		if local_paused != __host_paused:
			__pause(__host_paused)

	var local_date = date_model.get_raw_date()
	if local_date > __host_raw:
		__pull_date_back(date_model, local_date, __host_raw)


# Puts this machine's date model back to the world's week, and tells the game's own UI.
#
# `date_model.set_raw_date()` assigns the date and emits nothing (models/date.gd: `_raw_date = raw_date;
# compute_date()`), while the calendar only repaints on the `month` signal
# (scripts/game/gui/calendar.gd: `date_model.connect("month", self, "update_label")`). So a plain
# set_raw_date() left the model correct and the clock in the corner showing an older month - seen in a
# live session as a client whose model said 1978/01 while its calendar still read AUG 1977. Getting the
# two in step again needs the same signal the game's own tick would have emitted, which is what the
# calendar's handler is connected to.
func __pull_date_back(date_model, from_date, to_date):
	__set_date(date_model, to_date)
	__discard_overshoot(date_model)
	if __clock_corrections < 20:
		__clock_corrections += 1
		coop_log.info(config.log_name, "clock: date pulled back from %s to the world's %s" % [
			String(from_date), String(to_date)
		])


# Undoes everything the client's own tick did on the way *past* the world's week.
#
# Two pieces of state have to go with the corrected date, and leaving either behind is what produced the
# 0xae5633 crashes:
#
#   `_tick` - the partial week. A client that overshot had `_tick` close to `current_tick_interval`, so
#   setting the date back one week left the next increment almost due and it crossed the same boundary
#   again a second later. Run TRC shows exactly this shape: pulled from 48 back to 47 at 01:11:37, back
#   into 1977/0 at 01:11:39, dead at 01:11:42. Resetting the tick gives the corrected week its full
#   duration instead of a frame.
#
#   `__signal_to_emit` - the week/month/year signals already earned at the week that no longer applies.
#   `models/date.gd` queues them as the date crosses and emits **one per frame** in `_process`, and
#   `set_raw_date()` does not touch the queue. Left in place, the year the client had already entered
#   played its `end_of_year`/`month`/`year` cycle anyway - on a client that had deliberately muted part
#   of the rival simulation - and then played it a second time on the re-cross. Those listeners reach the
#   award, sales, payroll and convention models; one of them calls a Variant member this engine build
#   does not have, and that is a native access violation rather than an error.
#
# Dropping the queue loses nothing real: any boundary this machine genuinely reaches is queued again by
# the game's own tick as it arrives, and the calendar label is repainted directly by __set_date.
func __discard_overshoot(date_model):
	date_model.set("_tick", 0.0)
	date_model.set("__signal_to_emit", [])
	# Read back through the same member access the rest of this file already uses on the date model
	# (`date_model.paused`), and say so in the log. A `set()` that quietly does nothing would leave the
	# oscillation this function exists to stop looking fixed while behaving exactly as before, and this
	# project has already lost runs to a change that was applied and inert.
	if int(date_model._tick) != 0 or date_model.__signal_to_emit.size() != 0:
		if not __overshoot_warned:
			__overshoot_warned = true
			coop_log.warning(config.log_name, "clock: could not clear the overshoot (tick=%s, %s queued "
				% [String(date_model._tick), String(date_model.__signal_to_emit.size())]
				+ "signal(s)); this client may re-cross a boundary it was corrected out of")
	elif not __overshoot_noted:
		__overshoot_noted = true
		coop_log.info(config.log_name, "clock: cleared the overshoot so the corrected week gets its full "
			+ "duration instead of a frame")


# Moves this machine's date to a given week and keeps the game's own clock display truthful.
#
# `date_model.set_raw_date()` assigns the date and emits nothing (models/date.gd), while the calendar's
# label repaints only on the `month` signal (scripts/game/gui/calendar.gd `update_label`). A plain
# set_raw_date() therefore left the model correct and the clock in the corner showing an older month -
# seen in a live session as a client whose model said 1978/01 while its calendar still read AUG 1977.
#
# The obvious fix - `date_model.emit_signal("month")` - is wrong, and it crashed: 23 game models connect
# to `month` (game-sales, game-of-the-year, concurrent-game, digital-store, convention, ...), so emitting
# it out of band ran a whole month's business cycle in the middle of a correction and one of those paths
# called a Variant member this build does not have. The repaint is what is wanted, not the month.
#
# So the calendar's own label is repainted directly, through the method its handler calls.
func __set_date(date_model, raw_date):
	var before = date_model.get_date()
	date_model.set_raw_date(raw_date)
	var after = date_model.get_date()
	if int(before.month) != int(after.month) or int(before.year) != int(after.year):
		__repaint_calendar()
		coop_log.info(config.log_name, "clock: month changed to %s/%s, calendar repainted" % [
			String(after.year), String(after.month)
		])


# Repaints the game's own calendar label without running the month's business cycle.
#
# `update_label()` is the exact method the calendar connects to `month`; calling it does what the signal
# would do for the label and nothing else. Every other listener is left alone - they will run on the
# next real month boundary, as they should.
func __repaint_calendar():
	# Two fixes were tried for the label drifting behind the model (set_raw_date emits nothing):
	#
	#   1. `date_model.emit_signal("month")` - wrong, and it crashed. 38 game models connect to `month`
	#      (sales, awards, trades, conventions, digital stores, payroll, rent...), so emitting it out of
	#      band ran a whole month's business cycle inside a clock correction.
	#   2. call the calendar's own `update_label()`, which is what it connects to `month`.
	#
	# This is (2): one label, no business cycle.
	var calendar = automation.find_by_scene(get_tree().get_root(), CALENDAR_SCENE)
	if calendar == null:
		if not __calendar_missing_reported:
			__calendar_missing_reported = true
			coop_log.info(config.log_name, "clock: no calendar scene on screen, nothing to repaint")
		return
	if calendar.has_method("update_label"):
		calendar.call("update_label")


# Keeps this company's server usage honest on a client.
#
# Emptying the store once at join is not enough. `_update_platforms` runs on **every** `end_of_week`
# (controllers/digital-store-platform.gd), recomputes each supported platform's userbase from that
# platform's sales, and pushes the total into the server via `server_model.update_usage(...)`. A client
# that inherited the host's store therefore had its usage refilled one week later - seen in a live run as
# `verify FAIL the server holds nobody else's users (58783)` about three minutes after a join that had
# logged "digital store and server usage reset for this company".
#
# A company that owns no console has no customers of its own to serve, so its usage must be zero however
# often the game recomputes it. Once the company does own a console the game's own numbers are correct,
# and this stops touching them.
func __hold_own_server():
	if not models.has_model("server") or company.my_consoles().size() > 0:
		return
	var server = models.get_model("server")
	if int(server.call("get_usage_raw")) == 0 and int(server.call("get_online_players")) == 0:
		return
	var before = int(server.call("get_usage"))
	server.call("update_usage", 0)
	if server.has_method("set_online_players"):
		server.call("set_online_players", 0)
	if not __server_zeroed_noted:
		__server_zeroed_noted = true
		coop_log.info(config.log_name, "net: this company owns no console, so its server usage was held "
			+ "at zero (the game had recomputed %s from the world's store)" % [String(before)])


# The host owns the world's rivals. On a client they must not simulate at all, or two different
# AI histories would run in the same session and the market would disagree between machines.
#
# Everything the competitors do is driven by the date model's signals (see the connects in
# scripts/models/concurrent.gd and scripts/controllers/concurrent-*.gd), so the client
# disconnects precisely those signals for its concurrent* nodes and stops their per-frame work.
func __disable_competitor_simulation():
	var date_model = models.get_model("date")
	var removed = 0
	var kept = 0
	var muted = {}

	# Exactly the signals scripts/models/date.gd declares. Enumerating them with get_signal_list()
	# instead walks a table this build does not hand back safely, so the list is spelled out and is
	# checked against the source when the game updates.
	for signal_name in DATE_SIGNALS:
		for connection in date_model.get_signal_connection_list(signal_name):
			var method = String(connection.method)
			if config.trace:
				coop_log.info(config.log_name, "mute: %s -> %s" % [signal_name, method])
			if not COMPETITOR_HANDLERS.has(method):
				kept += 1
				continue
			date_model.disconnect(signal_name, connection.target, connection.method)
			removed += 1
			muted[method] = int(dict_lib.field(muted, method, 0)) + 1

	# The concurrent* scene nodes are panels and list items; stopping them keeps the client's rival
	# UI from doing per-frame work of its own.
	var nodes = 0
	for container in [models, controllers]:
		if not container.has_node("main"):
			continue
		for child in container.get_node("main").get_children():
			if String(child.get_name()).begins_with("concurrent"):
				child.set_process(false)
				child.set_fixed_process(false)
				nodes += 1

	if removed > 0:
		__competitors_muted = true
		coop_log.info(config.log_name, "net: competitor simulation disabled on this client "
			+ "(%s date-signal connections removed, %s kept, %s nodes stopped)" % [
				String(removed), String(kept), String(nodes)
			])
		for method in muted:
			coop_log.info(config.log_name, "net: muted %s x%s" % [
				String(method), String(muted[method])
			])
	elif not __mute_warned:
		__mute_warned = true
		coop_log.info(config.log_name, "net: no competitor handlers connected yet "
			+ "(%s date-signal connections are other things); will retry" % [String(kept)])


func __script_path(target):
	# typeof() first: calling an Object member on a Variant that is not an Object is the same
	# missing-member crash this build gives for Dictionary.get(). A connection entry can carry
	# something other than a live Object, so the type is checked before anything is called on it.
	if typeof(target) != TYPE_OBJECT or target == null:
		return "?"
	var script = target.get_script()
	if script == null:
		return "?"
	return String(script.resource_path)


# The objects that simulate rivals are not the concurrent* scene nodes: scripts/models/concurrent.gd,
# concurrent-game.gd, concurrent-staff.gd, concurrent-trading.gd and concurrent-platform.gd each
# connect their own handlers to the date model. Matching on the script path catches all of them
# without hard-coding signal names that a game update could rename.
func __is_competitor(target):
	if target == null:
		return false
	return __script_path(target).find("concurrent") >= 0


# The host decides whether time moves; a client never unpauses itself.
#
# The flag is set directly rather than through date_model.set_pause(): that path plays a UI sound,
# and on a machine with no working audio device the sound call kills the process outright. Pausing
# is state, not audio.
func __pause(paused):
	var date_model = models.get_model("date")
	if bool(date_model.paused) == paused:
		return
	date_model.set("paused", paused)
	coop_log.info(config.log_name, "clock: %s" % ["paused" if paused else "running"])


func __apply_company_table(table):
	# Same reason as __apply_clock: no model access until the world is loaded.
	if not models.is_loaded():
		return

	# Never inject ourselves as our own rival: the player's company is not a competitor, and a
	# competitor record for it would have no studios and no catalogue entry of its own.
	var own_id = ""
	if models.is_loaded():
		own_id = __local_id()

	var others_table = []
	for record in table:
		if String(record.id) != own_id:
			others_table.push_back(record)

	var ids = company.apply(others_table, config.log_name, __company_logos, __rival_game_ids)
	__company_table_seen = true
	__step("company table: applied")

	# Console ownership: another player's console must be a platform their company owns, not one of ours.
	if config.role == "client":
		for record in others_table:
			var consoles = dict_lib.field(record, "consoles", null)
			var added = company.apply_consoles(dict_lib.text(record, "id", "?"), consoles)
			if added > 0:
				coop_log.info(config.log_name, "net: %s console(s) from %s registered as their platforms" % [
					String(added), dict_lib.text(record, "id", "?")
				])

	# Every player's published games are offered to the others in the game's own publish-offer screen.
	for record in others_table:
		var rid = dict_lib.text(record, "id", "?")
		__step("company table: publish offers for %s" % [rid])
		var offers = company.publish_offers(rid, dict_lib.field(record, "games", null))
		var seen = 0
		if __offer_counts.has(rid):
			seen = int(__offer_counts[rid])
		if offers != seen:
			__offer_counts[rid] = offers
			coop_log.info(config.log_name, "offers: %s title(s) from %s are on the publish-offer list" % [
				String(offers), dict_lib.text(record, "name", "?")
			])

	# The table comes from the host, so it is authoritative for who else is present.
	var others = []
	for id in ids:
		others.push_back(id)

	var removed = company.prune(__known_ids, ids, config.log_name)
	__known_ids = ids

	if others.size() != __last_other_count or removed.size() > 0:
		__last_other_count = others.size()
		coop_log.info(config.log_name, "net: other players in the world: %s" % [desc(others)])


# The host's world, one model per message. A single 8 MB message kills this engine build, so the
# transfer is split; the client assembles it and only then boots.
func __send_world():
	coop_log.info(config.log_name, "net: world encoding start")
	var encoded = state_sync.encode_models(models.get_data())
	coop_log.info(config.log_name, "net: world encoding done (%s models)" % [String(encoded.size())])
	__link.send({"t": "world_begin", "count": encoded.size()})

	var sent = 0
	var parts_sent = 0
	for name in encoded:
		var json = encoded[name]
		var parts = int(ceil(float(json.length()) / float(WORLD_PART_SIZE)))
		if parts < 1:
			parts = 1
		var index = 0
		while index < parts:
			var from = index * WORLD_PART_SIZE
			var to = from + WORLD_PART_SIZE
			if to > json.length():
				to = json.length()
			__link.send({
				t = "world_part",
				name = String(name),
				i = index,
				of = parts,
				data = json.substr(from, to - from)
			})
			index += 1
			parts_sent += 1
		sent += 1
		# Let the frame breathe: the map alone is 3.2 MB and a tight loop of writes stalls the game.
		if parts_sent % 16 == 0:
			coop_log.info(config.log_name, "net: world sending %s/%s models" % [
				String(sent), String(encoded.size())
			])

	__link.send({"t": "world_end"})
	coop_log.info(config.log_name, "net: world sent (%s models, %s parts, %s bytes)" % [
		String(sent), String(parts_sent), String(__link.stats_sent)
	])


func __assemble(parts):
	var text = ""
	var index = 0
	while parts.has(index):
		text += parts[index]
		index += 1
	return text


# This player's identity, written into the state before it is loaded so the game boots straight into
# the right company rather than being edited under a running UI.
func __set_own_identity(state):
	if not state.has("player"):
		return
	var player = state["player"]
	var label = config.name
	if label == "":
		label = "Player"
	player["company_name"] = label + " Studio"
	player["player_name"] = label
	player["note"] = 0.0
	player["id"] = __local_id()
	player["company_logo"] = null
	player["character_textures"] = null
	coop_log.info(config.log_name, "net: own identity [%s] id=%s" % [
		String(player["company_name"]), String(player["id"])
	])


# Client: the host's world arrived. Boot into it, then pick a company.
func __on_world(encoded):
	if __world_received:
		return
	__world_received = true

	var state = state_sync.decode_models(encoded)
	if state == null or state.size() == 0:
		coop_log.error(config.log_name, "net: the host's world did not parse")
		return

	coop_log.info(config.log_name, "net: world received (%s models), booting" % [String(state.size())])

	# The digital store and the server are *the world's*, and they must not become the client's.
	#
	# `server.usage` and the store's per-platform userbase are the two numbers that make another
	# company's customers look like this company's. The store model holds, per platform, whether this
	# company publishes on it and how many customers it has there; taken from the host, a client that
	# owns no console starts with the host's console supported and its userbase already set, and the
	# next weekly pass pushes that into the client's server usage. The captured fresh company has no
	# digital-store section at all, so replacing the company does not fix it - the store has to be
	# emptied here, once, before it is used.
	state_sync.isolate_store(state)
	# Conventions go the same way but only half-way: the catalogue of events is the world's, everything a
	# player does with them is their own.
	state_sync.isolate_conventions(state)
	coop_log.info(config.log_name, "net: digital store, server usage and this company's conventions reset")

	# The world is the host's, but the company must not be: taking the host's company models would
	# make this client a second copy of the host with different money.
	#
	# A client that created its company in the game's own New Game dialogue brings that company; a
	# headless run (automated tests) has no dialogue and uses the company captured from a fresh game
	# at build time. Either way the studio model itself is replaced later, because a studio id is a map
	# tile id and this world's tiles are the host's.
	var backup = __local_company
	var source = "this session's New Game dialogue"
	var takeover = config.company_choice != "" and config.company_choice != "new"

	if takeover:
		# Taking over a company that already exists in this world: its identity, money and fanbase come
		# from its competitor record, and none of the host's company may come with it. Without this the
		# player inherited the host's 690 staff and 13 published games.
		if backup == null:
			backup = state_sync.load_company_backup()
		if backup != null:
			state_sync.merge_company_for_takeover(state, backup)
			__own_company_ready = true
		coop_log.info(config.log_name, "net: taking over %s, host company models dropped" % [
			config.company_choice
		])

	elif backup != null:
		__dialog_studio = state_sync.first_studio(backup)
		var taken = state_sync.merge_company(state, backup)
		__own_company_ready = true
		coop_log.info(config.log_name, "net: own company from %s (%s models replaced)" % [
			source, String(taken.size())
		])
	else:
		# A returning player: the world already holds their company in its own save section, so it is
		# handed back rather than a new one being made.
		var saved = state_sync.saved_company(state, __local_id())
		if saved != null:
			backup = state_sync.load_company_backup()
			if backup != null:
				state_sync.merge_company_for_takeover(state, backup)
			__restore = saved
			__own_company_ready = true
			# `studios` may be a count or a list depending on where the record came from. Reported as a
			# count here so a shape change can never take the client down in a log line.
			var saved_offices = 0
			if saved.has("studios") and typeof(saved["studios"]) == TYPE_ARRAY:
				saved_offices = saved["studios"].size()
			elif saved.has("offices") and saved["offices"] != null:
				saved_offices = saved["offices"].size()
			coop_log.info(config.log_name, "net: restoring %s from the world (%s offices saved)" % [
				__local_id(), String(saved_offices)
			])
		else:
			backup = state_sync.load_company_backup()
			source = "the fresh game captured at build time"
			if backup == null:
				coop_log.error(config.log_name, "net: no company to start with, "
					+ "this client would become a copy of the host")
			else:
				__dialog_studio = state_sync.first_studio(backup)
				var taken = state_sync.merge_company(state, backup)
				__own_company_ready = true
				coop_log.info(config.log_name, "net: own company from %s (%s models replaced)" % [
					source, String(taken.size())
				])

	__set_own_identity(state)

	var loading_scene = resource_manager.load_resource("res://scenes/loader/loading-screen.tscn")
	if loading_scene == null:
		coop_log.error(config.log_name, "net: loading screen missing")
		return

	var instance = loading_scene.instance()
	instance.initialize(state)
	scene_manager.clean_history(false)
	scene_manager.push_scene(instance, scene_manager.VISIBILITY_STATE.FORCE_HIDE, true, true, true)
	__pick_company_pending = true
	__join_ready_at = __elapsed + 15.0
	__lobby_pick_deadline = __elapsed + LOBBY_PICK_SECONDS


# Client: once the world is loaded, become the chosen company and stop running our own clock.
func __finish_join():
	if not __pick_company_pending or not models.is_loaded():
		return

	# The client's first office must not be opened before the host's company has been transplanted
	# onto its map, or the client could rent a tile the host's company already owns.
	if config.company_choice == "" or config.company_choice == "new":
		if not __company_table_seen and __elapsed < __join_ready_at:
			return

	__hide_lobby()
	__pick_company_pending = false
	__step("join: choosing company")
	var result = "kept the fresh company from the mod"
	var wanted = config.company_choice
	if wanted != "" and wanted != "new":
		result = company.choose(wanted, config.name)
	elif __restore != null:
		result = company.restore_from_world(__restore)
		__restore = null
	elif not __own_company_ready:
		# No captured company was available, so fall back to the in-place reset.
		result = company.choose("new", config.name)
	else:
		# A test hook: an office the player should *not* have kept, planted here because the world
		# merge empties the studio model and would erase it if it were planted earlier.
		__plant_office_for_test()
		# The company models already came from the captain at New Game time (or from the build-time
		# capture), so only the identity and the office are missing. A studio id is a map tile id, so
		# the office is opened in this world and the furniture moves with it.
		result = company.name_self(config.name) + ", " + company.open_first_studio(config.name, __dialog_studio)
	# A name typed in the lobby's company form wins over the session name: it is the one the player
	# chose, and it is what their rival will see.
	if config.company_name != "":
		result = company.name_self(config.company_name) + " (" + result + ")"
		company.apply_logo(__lobby_new_company)
	coop_log.info(config.log_name, "net: company choice %s -> %s" % [
		wanted, result
	])
	# A takeover can leave employees pointing at studios the acquisition replaced.
	#
	# Deferred rather than done inline: the game's own buyout creates the taken-over offices as part of
	# the call, and immediately afterwards the studio model has not caught up - a check at that instant
	# reported "no office of ours to seat anyone in" and every employee stayed an orphan.
	if wanted != "" and wanted != "new":
		__takeover_reseat_at = __elapsed + 2.0

	# The client runs its own company, so its clock must run too - but at the host's speed and
	# following the host's date, which __apply_clock keeps aligned.
	# The game pauses by itself when a project finishes and no studio director is hired
	# (models/game.gd release_game -> date_model.set_pause(true)). With auto_pause off that does not
	# happen, which is what a shared world needs: one player's project finishing must not freeze the
	# other player's game. Turned off for the session, and restored never - it is a setting, and the
	# mod only changes it while it is hosting.
	globals_manager.set("auto_pause", false)

	__step("join: muting competitor simulation")
	__disable_competitor_simulation()
	__step("join: done")
	__log_company()

	# Tell the world this player is in, so time may move again.
	__link.send({"t": "joined", "player": __local_id()})


# Spawns a fake competitor into a normally loaded save, one step at a time, with no session:
#
#   --coop-spawntest=1  catalogue entry only
#   --coop-spawntest=2  + create_concurrent
#   --coop-spawntest=3  + buy_studio for two tiles
#   --coop-spawntest=4  + _emit_signal_concurrent_created
#
# Whichever stage the process dies on is the call this engine build cannot do, and the log names it.
func __run_spawn_test():
	if __spawn_done or not models.is_loaded():
		return
	if __elapsed < __spawn_at:
		return
	__spawn_done = true

	var stage = config.spawn_test
	var id = "coop-spawntest"
	var concurrent = models.get_model("concurrent")
	var catalogue = company.catalogue()

	coop_log.info(config.log_name, "spawn %s: concurrent list has %s ids" % [
		String(stage), String(concurrent.get_concurrent_list_ids().size())
	])

	if stage >= 1:
		coop_log.info(config.log_name, "spawn %s: catalogue entry" % [String(stage)])
		catalogue[id] = {
			name = "Spawn Test",
			logo = ImageTexture.new(),
			engine = {royalties = [25, 35], interval = 108}
		}
		coop_log.info(config.log_name, "spawn %s: catalogue entry written, name reads [%s]" % [
			String(stage), String(concurrent.get_concurrent_name(id))
		])

	if stage >= 2:
		coop_log.info(config.log_name, "spawn %s: create_concurrent" % [String(stage)])
		concurrent._initialize_list()
		concurrent.create_concurrent(id, 1000, 50.0, 100000)
		coop_log.info(config.log_name, "spawn %s: created, in live list=%s" % [
			String(stage), String(concurrent.get_concurrent() != null and concurrent.get_concurrent().has(id))
		])

	if stage >= 3:
		coop_log.info(config.log_name, "spawn %s: buy_studio" % [String(stage)])
		var available = controllers.get_controller("map").list_studio_available()
		coop_log.info(config.log_name, "spawn %s: %s free tiles" % [
			String(stage), String(available.size())
		])
		if available.size() > 0:
			concurrent.buy_studio(id, available[0].id)
		coop_log.info(config.log_name, "spawn %s: studios owned=%s" % [
			String(stage), String(__rival_tiles(id))
		])

	if stage >= 4:
		coop_log.info(config.log_name, "spawn %s: emitting concurrent_created" % [String(stage)])
		concurrent._emit_signal_concurrent_created(id)
		coop_log.info(config.log_name, "spawn %s: emitted" % [String(stage)])

	coop_log.info(config.log_name, "spawn %s: survived" % [String(stage)])
	set_process(false)
	get_tree().quit()
# measurement rather than a claim. A fresh company is 1 studio, 1 employee, 0 published games.
func __log_company():
	var studio_model = models.get_model("studio")
	var concurrent = models.get_model("concurrent")
	var studios = company.count_player_studios()

	coop_log.info(config.log_name, "company: [%s] studios=%s staff=%s published=%s currency=%s fanbase=%s rivals=%s consoles=%s week=%s" % [
		String(models.get_model("player").get_data().company_name),
		String(studios),
		String(models.get_model("staff").get_staff_size()),
		String(models.get_model("game").get_amount_of_published_game()),
		String(models.get_model("currency").get_currency()),
		String(models.get_model("fanbase").get_fanbase()),
		String(concurrent.get_concurrent_list_ids().size()),
		String(company.my_consoles().size()),
		String(models.get_model("date").get_raw_date())
	])

	__next_company_at = 0.0


# The host agrees the world may carry on without a player. Their company stays in the world as a
# normal rival, run by the game's own AI, and the flag is recorded in the save section so a later
# session does not have to ask again.
func __confirm_continue(player_id):
	if player_id == "":
		return
	__mark_present(player_id, false)
	if models.has_model("coop-state"):
		var coop = models.get_model("coop-state")
		coop.set_host_confirmed(player_id, true)
	coop_log.info(config.log_name, "net: carrying on without %s, their company is now an AI rival" % [
		player_id
	])
	if config.role == "host":
		__link.send({"t": "continue_without", "player": player_id})
		__pause(false)


# This player's own company has been bought out. The world belongs to the host, so the buyout stands:
# time stops on this machine, the company is no longer theirs, and they are told to pick again rather
# than continuing to play a company that now belongs to somebody else.
func __on_own_company_acquired(buyer):
	coop_log.warning(config.log_name, "net: your company was bought out by %s" % [buyer])
	__pause(true)
	set_process(false)
	get_tree().quit()


func __mark_present(player_id, present):
	if player_id == "" or not models.has_model("coop-state"):
		return
	var coop = models.get_model("coop-state")
	if coop.has_player(player_id):
		coop.mark_present(player_id, present)


func desc(values):
	var parts = []
	for value in values:
		parts.push_back(String(value))
	return company.join(parts, ", ")



# ---------------------------------------------------------------------------
# Read-path probe: each socket call is logged before and after, so a native crash names the one
# that killed the process. Points at a relay with no host running, which answers a join request
# with a small error message - the smallest possible inbound payload.
# ---------------------------------------------------------------------------
var __read_probe = null
var __read_phase = 0
var __read_at = 0.0

func __read_send(message):
	var body = message.to_json()
	var size = body.to_utf8().size()
	var header = String(size)
	while header.length() < 8:
		header = "0" + header
	coop_log.info(config.log_name, "readtest: writing %s (%s bytes)" % [message["t"], header])
	var error = __read_probe.put_data((header + body).to_utf8())
	coop_log.info(config.log_name, "readtest: put_data returned %s" % [String(error)])


func __run_read_probe():
	if __read_probe == null:
		__read_probe = StreamPeerTCP.new()
		coop_log.info(config.log_name, "readtest: connecting")
		var error = __read_probe.connect(config.host, config.port)
		coop_log.info(config.log_name, "readtest: connect returned %s" % [String(error)])
		__read_at = __elapsed + 1.0
		return

	if __elapsed < __read_at:
		return
	__read_at = __elapsed + 1.0

	coop_log.info(config.log_name, "readtest: phase %s" % [String(__read_phase)])

	if __read_phase == 0:
		var status = __read_probe.get_status()
		coop_log.info(config.log_name, "readtest: get_status=%s" % [String(status)])
		if status == StreamPeerTCP.STATUS_CONNECTED:
			__read_send({"t": "role", "role": "client", "player": "probe", "name": "probe"})
			__read_send({"t": "join_request", "player": "probe"})
			__read_phase = 1
		return

	if __read_phase == 1:
		coop_log.info(config.log_name, "readtest: calling get_available_bytes")
		var available = __read_probe.get_available_bytes()
		coop_log.info(config.log_name, "readtest: available=%s" % [String(available)])
		if available <= 0:
			return

		coop_log.info(config.log_name, "readtest: calling get_data(%s)" % [String(available)])
		var chunk = __read_probe.get_data(available)
		coop_log.info(config.log_name, "readtest: get_data returned error=%s size=%s" % [
			String(chunk[0]), String(chunk[1].size())
		])

		coop_log.info(config.log_name, "readtest: calling get_string_from_ascii")
		var text = chunk[1].get_string_from_ascii()
		coop_log.info(config.log_name, "readtest: ascii text=[%s]" % [text])
		coop_log.info(config.log_name, "readtest: calling get_string_from_utf8")
		var text2 = chunk[1].get_string_from_utf8()
		coop_log.info(config.log_name, "readtest: utf8 text=[%s]" % [text2])
		__read_phase = 3
		return

	if __read_phase == 3:
		# Exactly what link.poll() does: read the length with StreamPeer.get_utf8_string, then the
		# body the same way. The readtest above used get_data(), which is proven; this is the
		# suspect path.
		coop_log.info(config.log_name, "readtest: asking for another reply")
		__read_send({"t": "join_request", "player": "probe"})
		__read_phase = 4
		__read_at = __elapsed + 1.0
		return

	if __read_phase == 4:
		var available = __read_probe.get_available_bytes()
		coop_log.info(config.log_name, "readtest: phase4 available=%s" % [String(available)])
		if available < 8:
			return
		coop_log.info(config.log_name, "readtest: calling get_utf8_string(8)")
		var prefix = __read_probe.get_utf8_string(8)
		coop_log.info(config.log_name, "readtest: prefix=[%s]" % [prefix])
		var length = int(prefix)
		coop_log.info(config.log_name, "readtest: calling get_utf8_string(%s)" % [String(length)])
		var body = __read_probe.get_utf8_string(length)
		coop_log.info(config.log_name, "readtest: body=[%s]" % [body])
		__read_phase = 5
		return

var __dict = null
var __dict_at = 0.0
var __dict_phase = 0

var __mute_at = 0.0
var __mute_done = false
var __next_mute_at = 0.0
var __mute_warned = false
var __mute_tries = 0
var __spawn_at = 0.0
var __spawn_done = false


func __rival_tiles(id):
	var live = models.get_model("concurrent").get_concurrent()
	if live == null or not live.has(id):
		return -1
	var entry = live[id]
	if not entry.has("studio") or entry["studio"] == null:
		return 0
	return entry["studio"].size()


# Runs the client's competitor mute on a normally loaded save, with no session, so the mute can be
# verified on its own: run with --coop-mutetest --coop-selftest --coop-load=<save> and the log must
# report the connections it dropped.
func __run_mute_test():
	if not models.is_loaded() or __mute_done:
		return
	if __elapsed < __mute_at or __elapsed < __next_mute_at:
		return
	__next_mute_at = __elapsed + 3.0
	__mute_tries += 1
	config.trace = true
	coop_log.info(config.log_name, "mutetest: pass %s" % [String(__mute_tries)])
	__disable_competitor_simulation()
	if __competitors_muted or __mute_tries >= 12:
		__mute_done = true
		coop_log.info(config.log_name, "mutetest: done, muted=%s" % [String(__competitors_muted)])
		set_process(false)
		get_tree().quit()


func __run_dict_probe():
	if __dict == null:
		__dict = dict_probe.new()
	if __elapsed < __dict_at:
		return
	__dict_at = __elapsed + 1.0
	__dict_phase = __dict.step(config.log_name, __dict_phase)
	if __dict_phase < 0:
		coop_log.info(config.log_name, "dicttest: all steps done")
		set_process(false)
		get_tree().quit()


# A client that wants a brand-new company creates it in the game's own New Game dialogue first, so the
# company name, logo, studio, layout and staff all come from the game instead of from the mod. That
# dialogue only applies to a new company: a client taking over a company that already exists in the
# host's world joins straight away and picks it there.
func __can_join():
	if config.role != "client":
		return models.is_loaded()

	# A lobby client connects from the main menu, before any game exists. That is the whole point of
	# the lobby: it is where the player chooses, so waiting for a loaded game would be waiting for the
	# decision the lobby is meant to ask for.
	if not __lobby_bypassed():
		return true

	if config.company_choice != "" and config.company_choice != "new":
		return true

	if models.is_loaded():
		if __local_company == null:
			__local_company = state_sync.capture_models(COMPANY_MODELS)
			coop_log.info(config.log_name, "net: using the company created in this session (%s models)" % [
				String(__local_company.size()) if __local_company != null else "0"
			])
		return true

	# An automated run has no dialogue to wait for, so it falls back to the company captured at build
	# time from a brand-new game.
	if config.autojoin:
		return true
	return false


# Watches the buyout of a player's company happen, through the game's own acquisition path, so the
# edge case can be seen in a log rather than argued about.
func __run_buy_test():
	if not models.is_loaded():
		return
	# Wait until the player's company actually exists on this machine.
	if not __rival_exists(config.buy_test):
		if __elapsed > __buy_test_wait:
			if not __buy_test_warned:
				__buy_test_warned = true
				coop_log.info(config.log_name, "buytest: %s is not in this world yet" % [
					config.buy_test
				])
		return

	__buy_test_done = true
	coop_log.info(config.log_name, "buytest: trying to buy every share of %s, which is a player" % [
		config.buy_test
	])
	var trading = models.get_model("concurrent-trading")
	trading.buy_concurrent_stocks(config.buy_test, 1000000)
	coop_log.info(config.log_name, "buytest: rival still in the world=%s, player studios=%s" % [
		String(__rival_exists(config.buy_test)), String(company.count_player_studios())
	])


# Events that have not happened yet, as the host sees them.
func __upcoming_events():
	var model = models.get_model("event")
	var now = __date_key(models.get_model("date").get_date())
	var upcoming = []
	for entry in model.get_events():
		if entry == null or not entry.has("date"):
			continue
		if __date_key_text(String(entry["date"])) >= now:
			upcoming.push_back(entry)
	return upcoming


func __date_key(date):
	return int(date.year) * 10000 + int(date.month) * 100 + int(date.week)


# "year-month-week", the format the event model stores.
func __date_key_text(text):
	var parts = text.split("-")
	if parts.size() < 3:
		return 0
	return int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2])


# A client adopts the host's upcoming events, so both machines announce and resolve them in the same
# week. Present ones are left alone; only missing ones are added.
func __apply_events(incoming):
	if incoming == null:
		return
	var model = models.get_model("event")
	var present = []
	for entry in model.get_events():
		if entry != null and entry.has("id"):
			present.push_back(String(entry["id"]))
	var added = 0
	for entry in incoming:
		if entry == null or not entry.has("id"):
			continue
		if present.has(String(entry["id"])):
			continue
		model.add_scheduled_type_event(
			String(entry["name"]) if entry.has("name") else "",
			String(entry["description"]) if entry.has("description") else "",
			entry["event_color"] if entry.has("event_color") else 0,
			__date_from_key(String(entry["date"])),
			String(entry["type"]) if entry.has("type") else "uniq",
			false,
			entry["actions"] if entry.has("actions") else {}
		)
		added += 1
	if added > 0:
		coop_log.info(config.log_name, "events: took %s upcoming event(s) from the host, %s total" % [
			String(added), String(model.get_events().size())
		])


func __date_from_key(text):
	var parts = String(text).split("-")
	var result = {year = 2000, month = 1, week = 1}
	if parts.size() >= 3:
		result["year"] = int(parts[0])
		result["month"] = int(parts[1])
		result["week"] = int(parts[2])
	return result


# Tries to edit a console this machine does not own, and reports whether the world put it back, plus
# whether the console is a platform to the game with the right name and stats.
func __run_console_test():
	if not models.is_loaded() or not models.has_model("custom-platform"):
		return
	var list = company.my_consoles()
	if list.size() == 0:
		return
	if __console_phase == 0 and __elapsed > __console_at:
		__console_phase = 1
		var first = list[0]
		__console_id = String(first["id"]) if first != null and first.has("id") else ""
		if __console_id == "":
			return
		coop_log.info(config.log_name, "consoletest: console %s is now a platform owned by someone else, "
			% [__console_id] + "checking it cannot be edited here")
		__console_before = platform_price(__console_id)
		coop_log.info(config.log_name, "consoletest: its price reads %s on this machine" % [
			String(__console_before)
		])
		return


func platform_price(platform_id):
	var platform = models.get_model("platform")
	var data = platform.get_platform_by_id(platform_id)
	if data == null or not data.has("price"):
		return -1
	return float(data["price"])


# Tries to move time forward the way a client abusing the pause/speed controls would, and reports how
# far the world let it get. The answer must be: not at all.
func __run_spam_test():
	if not models.is_loaded():
		return
	# Nothing may be measured until the world's clock has arrived: a probe that fires before it is only
	# measuring its own sabotage.
	if __host_raw < 0:
		if not __spam_waiting:
			__spam_waiting = true
			coop_log.info(config.log_name, "spamtest: waiting for the world's clock before pushing time")
		return
	if __spam_waiting:
		__spam_waiting = false
		__spam_at = __elapsed + 2.0
		coop_log.info(config.log_name, "spamtest: world clock is week %s, starting in 2 s" % [
			String(__host_raw)
		])
		return

	var date_model = models.get_model("date")
	if __elapsed < __spam_at + 1.0:
		return
	__spam_at = __elapsed + 1.0
	__spam_tries += 1
	date_model.set_raw_date(date_model.get_raw_date() + 10)
	date_model.set_speed(5)
	if bool(date_model.paused) == false:
		__pause(true)
	var deviation = date_model.get_raw_date() - __host_raw
	if deviation > __spam_max:
		__spam_max = deviation
	if __spam_tries <= 3 or __spam_tries % 5 == 0:
		coop_log.info(config.log_name, "spamtest %s: pushed date to %s, host is %s, deviation %s" % [
			String(__spam_tries), String(date_model.get_raw_date()), String(__host_raw),
			String(deviation)
		])
	if __spam_tries >= 20 and not __spam_done:
		__spam_done = true
		coop_log.info(config.log_name, "spamtest: worst deviation from the host was %s week(s)" % [
			String(__spam_max)
		])


func _process(delta):
	__elapsed += delta

	# Once the player is back at the main menu this mod has nothing left to do in the world, and every
	# later stage below expects models that the menu transition is tearing down.
	if __left_to_menu:
		__linger_on_disconnect()
		return

	if __network_wanted and __link == null:
		if __can_join():
			__start_network()
	__trace("net-start")
	__hold_test_speed()
	__tick_tutorial()
	__tick_world_save_id()
	__tick_takeover_reseat()
	__install_buyout_guard()
	__trace("buyout")
	__enforce_host_clock()
	__trace("clock")

	if config.buy_test != "" and not __buy_test_done:
		__run_buy_test()
		__trace("buytest")

	if config.console_test:
		__run_console_test()
		__trace("console")

	if config.spam_test:
		__run_spam_test()
		__trace("spam")

	__patch_menu()
	__trace("menu")
	__run_menu_dump()
	__run_menu_test()
	__trace("menutest")
	__patch_game_ui()
	__trace("ui")
	__run_ui_test()
	__trace("uitest")
	__run_dump()
	__trace("dump")
	__run_tech_probe()
	__run_research()
	if config.play > 0.0:
		play_lib.tick(self)
		__trace("play")
	if config.pilot > 0.0:
		pilot_lib.tick(self)
		__trace("pilot")
	__run_gift()
	__trace("gift")
	__run_verify()
	__trace("verify")
	if config.remote:
		remote_lib.tick(self)
		__trace("remote")
	__watch_peers()

	if config.dict_test:
		__run_dict_probe()
	elif config.mute_test:
		__run_mute_test()
	elif config.spawn_test > 0:
		__run_spawn_test()
	elif config.read_test:
		__run_read_probe()
	else:
		__poll_network()
		__trace("poll")
		__finish_join()
		__trace("join")
		# Rival simulation is driven by connections that appear as the client's world comes up, and
		# more appear whenever a new competitor game is released, so the mute keeps being applied
		# rather than being a single pass at join time.
		if config.role == "client" and models.is_loaded() and __world_received:
			if __elapsed >= __next_mute_at:
				__next_mute_at = __elapsed + MUTE_INTERVAL
				__disable_competitor_simulation()
		__trace("mute")

	if config.selftest:
		__run_selftest(delta)
		__trace("selftest")

	if config.difftest > 0.0:
		__run_difftest()

	if config.streamtest > 0.0:
		__run_streamtest()

	if config.quit_after > 0.0 and __elapsed >= config.quit_after:
		coop_log.info(config.log_name, "quit after %s s (test mode)" % [String(config.quit_after)])
		set_process(false)
		get_tree().quit()


# With --coop-trace-steps, each stage of _process says it survived. A native crash leaves no GDScript
# error, so the last marker before the process dies names the call that killed it.
func __trace(stage):
	if not config.trace_steps:
		return
	var clock = ""
	if models.is_loaded() and models.has_model("date"):
		var date_model = models.get_model("date")
		clock = " raw=%s paused=%s frozen=%s" % [
			String(date_model.get_raw_date()), String(bool(date_model.paused)),
			String(__date_frozen(date_model))
		]
	coop_log.info(config.log_name, "trace: %s ok at %s s (step %s)%s" % [
		stage, String(int(__elapsed)), String(__step), clock
	])


# Test-facing setup that goes through the game's own persistence layer, so the UI picks the
# values up exactly as if they had been chosen in the menus:
#   autosave off  - a modded build must never write over the player's real saves while testing
#   map size      - static_data.get_data("game_map"): 0 tiny(25), 1 small(35), 2 medium(40),
#                   3 large(60), 4 huge(120 tiles, 12 competitors)
# Closes the popups that stop game time while a test is holding the clock.
#
# The game freezes its own clock whenever any popup is on top (controllers/date.gd `compute_state`). In a
# two-year run that is most of the time: the tutorial at the start, the monthly inbox and annual report,
# money warnings, and every notification. A run that was watched for an hour advanced 44 weeks because of
# one notification the player would have clicked in a second.
#
# Only when `--coop-speed` was asked for, i.e. the run is a test. A real session never has its popups
# closed for it.
const AUTO_CLOSE_POPUPS = ["tutoriel", "notification", "report", "inbox", "annual"]

func __tick_tutorial():
	if config.game_speed_request <= 0 or not models.is_loaded():
		return
	if __elapsed < __next_tutorial_at:
		return
	__next_tutorial_at = __elapsed + 1.5
	var popups = get_tree().get_nodes_in_group("popup-node")
	for popup in popups:
		if popup == null or not popup.is_visible():
			continue
		var scene = String(popup.get_filename())
		var wanted = false
		for tag in AUTO_CLOSE_POPUPS:
			if scene.find(tag) >= 0:
				wanted = true
				break
		if not wanted:
			continue
		var close = popup.find_node("close", true, false)
		if close == null:
			# Notification panels close through their confirm action rather than a close button.
			if popup.has_method("close"):
				popup.call("close")
				coop_log.info(config.log_name, "clock: closed %s so time can move" % [scene])
			continue
		close.emit_signal("pressed")
		coop_log.info(config.log_name, "clock: closed %s so time can move" % [scene])
		return


# Holds the clock at the speed a test asked for.
#
# `--coop-speed=N` is a test setting, and the game undoes it on its own: the currency controller forces
# speed 1 whenever a monthly report crosses a money warning (controllers/currency.gd), which happens
# routinely in a two-year run, and the player can pause it by opening anything. A long run that silently
# dropped to 1x would take hours instead of minutes, so the speed is re-asserted.
#
# Only the host does this, and only when the flag was given: it is a test instrument, not a cheat, and a
# real session must keep whatever the player chose.
func __hold_test_speed():
	if config.game_speed_request <= 0 or config.role != "host" or not models.is_loaded():
		return
	if not models.has_model("date"):
		return
	if __elapsed < __next_speed_at:
		return
	__next_speed_at = __elapsed + 2.0
	var date_model = models.get_model("date")
	# A paused clock is the other half of "the run is not advancing", and it has several causes: a popup,
	# a monthly money warning (controllers/currency.gd forces a pause and speed 1), the game pausing itself
	# when a project finishes with no studio director, or the host pausing because a player left. In a test
	# run all of them are noise, so the clock is put back the way the run asked for.
	if bool(date_model.paused):
		__pause(false)
		coop_log.info(config.log_name, "clock: unpaused the world so the run can advance")
	var have = int(date_model.get_speed_index())
	if have != int(config.game_speed_request):
		date_model.set_speed(int(config.game_speed_request))
		__broadcast_clock()
		coop_log.info(config.log_name, "speed: back to %sx (was %sx)" % [
			String(config.game_speed_request), String(have)
		])


func __apply_test_settings():
	if config.noautosave:
		globals_manager.set("autosave_delay", -1)
		coop_log.info(config.log_name, "autosave disabled for this session")

	if config.map_size >= 0:
		var sizes = static_data.get_data("game_map")
		var key = String(config.map_size)
		if sizes.has(key):
			globals_manager.set("map_size", int(sizes[key].size))
			globals_manager.set("amount_concurrent", int(sizes[key].concurrent_amount))
			coop_log.info(config.log_name, "map size set to %s tiles (%s competitors)" % [
				String(sizes[key].size), String(sizes[key].concurrent_amount)
			])
		else:
			coop_log.warning(config.log_name, "map size %s does not exist (0-4)" % [key])

	if config.game_speed >= 0:
		globals_manager.set("game_speed", config.game_speed)

	if config.difficulty >= 0:
		globals_manager.set("difficulty", config.difficulty)

	if config.competitors >= 0:
		globals_manager.set("amount_concurrent", config.competitors)

# ---------------------------------------------------------------------------
# Self test: menu -> new game, or load a save -> in game. No human input.
# Steps are explicit so a hang points at the exact stage that broke.
# ---------------------------------------------------------------------------
func __run_selftest(delta):
	if __step == 0:
		if config.load_save != "":
			coop_log.info(config.log_name, "selftest: loading save " + config.load_save)
			var error = save_manager.resume_save(config.load_save)
			if error != null:
				coop_log.error(config.log_name, "selftest: resume_save failed: " + String(error))
				__step = 99
			else:
				__step = 3
			return

		var menu = automation.find_by_scene(get_tree().get_root(), MENU_SCENE)
		if menu == null:
			return
		coop_log.info(config.log_name, "selftest: menu scene is up")
		if automation.press_new_game(menu):
			coop_log.info(config.log_name, "selftest: pressed new game")
			__step = 1
		else:
			coop_log.error(config.log_name, "selftest: new game button not found in the menu")
			__step = 99
		return

	if __step == 1:
		__poll += delta
		if __poll < MENU_POLL_SECONDS:
			return
		__poll = 0.0

		var popup = automation.find_by_scene(get_tree().get_root(), NEW_GAME_SCENE)
		if popup == null:
			coop_log.info(config.log_name, "selftest: waiting for the new game screen")
			return

		coop_log.info(config.log_name, "selftest: new game screen is up")
		__step = 2
		return

	if __step == 2:
		__form_wait += delta
		if __form_wait < NEW_GAME_FORM_WAIT:
			return

		__step = 3
		var popup = automation.find_by_scene(get_tree().get_root(), NEW_GAME_SCENE)
		if popup == null:
			coop_log.error(config.log_name, "selftest: new game screen disappeared before start")
			return

		coop_log.info(config.log_name, "selftest: starting a game with the form defaults")
		popup.start_pressed()
		return

	if __step == 3:
		if not models.is_loaded():
			return

		__step = 4
		coop_log.info(config.log_name, "selftest: game state is loaded")
		__settle_at = __elapsed + config.settle
		if config.settle > 0.0:
			coop_log.info(config.log_name, "selftest: settling for %s s first" % [String(config.settle)])
		return

	if __step == 4:
		if __elapsed < __settle_at:
			return

		__step = 5
		coop_log.info(config.log_name, "selftest: ready")

		if config.report:
			__report_state()
		if config.capture_fresh:
			__capture_fresh_company()
		# The host's company never goes through open_first_studio, so the clean-up that keeps one home
		# office per player has to run here as well - otherwise the host keeps whatever pile of "Home"
		# offices earlier sessions left behind, next to its real studios.
		if config.role == "host":
			coop_log.info(config.log_name, "selftest: collapsing the host's home offices")
			company.ensure_single_home("")
			coop_log.info(config.log_name, "selftest: home offices collapsed")
		# A save loaded by a script stays outside the game's plain view state, which freezes its clock.
		# Put it back, so an automated run advances the world the way a player's does.
		coop_log.info(config.log_name, "selftest: entering view mode")
		__enter_view_mode()
		coop_log.info(config.log_name, "selftest: in view mode")
		if config.unpause:
			__start_clock()
		return


# Ends the paused state a freshly loaded save starts in, so the simulation advances.
# Puts the game back into its normal playing state, which is what un-freezes the clock.
#
# Loading a save through save_manager (the automated path, --coop-load) leaves the game outside its
# plain view state, and the game freezes its own date model whenever that is true
# (controllers/date.gd compute_state). Nothing advances the world until something calls set_view_mode -
# normally the UI does it when the player closes a panel. A real player never hits this; a scripted run
# does, and it made "the date did not advance" look like a desync when both machines agreed exactly.
func __enter_view_mode():
	if not models.has_model("state"):
		return false
	var state_model = models.get_model("state")
	if not state_model.has_method("set_view_mode"):
		return false
	state_model.call("set_view_mode")
	return true


# Ends the paused state a freshly loaded save starts in, so the simulation advances.
func __start_clock():
	var date_model = models.get_model("date")
	if not date_model.is_started():
		date_model.start()
	date_model.set_pause(false)
	date_model.set_freeze(false)
	coop_log.info(config.log_name, "clock: started, paused=%s raw_date=%s interval=%s" % [
		String(date_model.is_paused()), String(date_model.get_raw_date()),
		String(date_model.get_week_duration())
	])


# ---------------------------------------------------------------------------
# Report: what the loaded game is, and what its state costs.
# ---------------------------------------------------------------------------
func __report_state():
	var started = OS.get_ticks_msec()
	var state = models.get_data()
	var json = state.to_json()

	coop_log.write_text(config.log_name + "-state.json", json)
	coop_log.info(config.log_name, "report: state is %s models, %s bytes (%s ms to serialise)" % [
		String(state.size()), String(json.length()), String(OS.get_ticks_msec() - started)
	])

	__report_game_summary()
	__report_company()

	if config.probe:
		__probe_reflection(models.get_model("date"))


# What belongs to the player's company, and what belongs to the rivals.
#
# The client boots the host's save, so unless the player's own company is separated from the host's,
# the client is simply the host's company with different pocket money. This report is the inventory
# that separation has to work from: which models hold player progression, which hold rival data, and
# where the boundary sits (rival studios live in the same studio model, flagged by concurrent.studio).
func __report_company():
	var concurrent = models.get_model("concurrent")
	var player = models.get_model("player").get_data()

	coop_log.info(config.log_name, "company: name=[%s] note=%s currency=%s fanbase=%s" % [
		String(player.company_name), String(player.note),
		String(models.get_model("currency").get_currency()),
		String(models.get_model("fanbase").get_fanbase())
	])

	var ids = concurrent.get_concurrent_list_ids()
	coop_log.info(config.log_name, "company: %s rival companies" % [String(ids.size())])

	var studio_data = models.get_model("studio").get_data()
	var studios = {}
	if studio_data.has("list") and studio_data["list"] != null:
		studios = studio_data["list"]

	var player_studios = 0
	var rival_studios = 0
	var sample_player = null
	var sample_rival = null
	for studio_id in studios:
		if concurrent.is_studio_owned(studio_id):
			rival_studios += 1
			if sample_rival == null:
				sample_rival = studios[studio_id]
		else:
			player_studios += 1
			if sample_player == null:
				sample_player = studios[studio_id]

	coop_log.info(config.log_name, "company: studios total=%s player=%s rival=%s" % [
		String(studios.size()), String(player_studios), String(rival_studios)
	])
	if sample_player != null:
		coop_log.info(config.log_name, "company: player studio keys=%s" % [
			String(sample_player.keys())
		])
		coop_log.info(config.log_name, "company: player studio name=[%s] area=[%s]" % [
			String(sample_player.name), String(sample_player.area)
		])
	if sample_rival != null:
		coop_log.info(config.log_name, "company: rival studio keys=%s" % [
			String(sample_rival.keys())
		])

	coop_log.info(config.log_name, "company: staff total=%s" % [
		String(models.get_model("staff").get_staff_size())
	])

	var game_model = models.get_model("game")
	var game_data = game_model.get_data()
	coop_log.info(config.log_name, "company: game model keys=%s published=%s" % [
		String(game_data.keys()), String(game_model.get_amount_of_published_game())
	])

	var rival_staff = models.get_model("concurrent-staff").get_data()
	var rival_games = models.get_model("concurrent-game").get_data()
	coop_log.info(config.log_name, "company: rival staff keys=%s rival game keys=%s" % [
		String(rival_staff.keys()), String(rival_games.keys())
	])

	# Every model and how much it holds, so a fresh game and a mid-game save can be compared and the
	# progression models identified without guessing.
	var all = models.get_data()
	var names = all.keys()
	for name in names:
		var data = all[name]
		var size = 0
		if data != null and (typeof(data) == TYPE_DICTIONARY or typeof(data) == TYPE_ARRAY):
			size = data.size()
		coop_log.info(config.log_name, "company: model %s entries=%s json=%s" % [
			name, String(size), String(data.to_json().length()) if data != null else "0"
		])


func __report_game_summary():
	var date_model = models.get_model("date")
	var date = date_model.get_date()
	coop_log.info(config.log_name, "game: date=%s-%s-%s raw_date=%s interval=%s speed=%s" % [
		String(date.year), String(date.month), String(date.week),
		String(date_model.get_raw_date()), String(date_model.get_week_duration()),
		String(date_model.get_speed_index())
	])
	coop_log.info(config.log_name, "game: currency=%s" % [
		String(models.get_model("currency").get_currency())
	])

	for name in ["player", "map", "staff", "studio", "game-engine", "platform"]:
		var data = models.get_model(name).get_data()
		coop_log.info(config.log_name, "game: %s keys=%s json=%s bytes" % [
			name, String(data.size()), String(data.to_json().length())
		])


# {model name: data} for the models that make up a player's own company, captured from a brand-new
# game. A client joining the host's world keeps the host's map, date, market and rivals, but cannot
# keep the host's company: that would make the client a second copy of the host (same studios, same
# games in development, same sales) with different pocket money. Replacing exactly these models gives
# the client its own company instead.
func __capture_fresh_company():
	var all = models.get_data()
	var picked = {}
	for name in COMPANY_MODELS:
		if all.has(name):
			picked[name] = all[name]

	if picked.has("player"):
		# Images are 88 KB of the player model and the client sets its own identity anyway.
		picked["player"]["company_logo"] = null
		picked["player"]["character_textures"] = null

	var payload = {version = 1, models = picked}
	var json = payload.to_json()
	var wrote = coop_log.write_text("fresh-company.json", json)
	coop_log.info(config.log_name, "capture: %s models, %s bytes, written=%s" % [
		String(picked.size()), String(json.length()), String(wrote)
	])


# ---------------------------------------------------------------------------
# Difference test: the real sync path, measured in the real game.
#
#   1. capture the state (deep copy), start the clock
#   2. after `difftest` seconds capture it again and diff the two trees
#   3. measure the patch, raw and gzipped
#   4. apply the patch to a copy of the first capture and prove it equals the second
#   5. rebuild the touched live models from the patched copy and re-read them
# ---------------------------------------------------------------------------
func __run_difftest():
	if __step < 5:
		return

	if __diff_phase == 0:
		__diff_phase = 1
		var started = OS.get_ticks_msec()
		__diff_reference = state_sync.capture()
		__diff_capture_ms = OS.get_ticks_msec() - started

		if __diff_reference == null:
			coop_log.error(config.log_name, "diff: could not capture the reference state")
			__diff_phase = 99
			return

		coop_log.info(config.log_name, "diff: reference captured in %s ms" % [
			String(__diff_capture_ms)
		])
		__diff_second_at = __elapsed + config.difftest
		coop_log.info(config.log_name, "diff: second capture in %s s" % [String(config.difftest)])
		return

	if __diff_phase == 1:
		if __elapsed < __diff_second_at:
			return

		__diff_phase = 2
		__evaluate_difftest()
		return


func __evaluate_difftest():
	var started = OS.get_ticks_msec()
	var current = state_sync.capture()
	var capture_ms = OS.get_ticks_msec() - started
	if current == null:
		coop_log.error(config.log_name, "diff: could not capture the second state")
		return

	coop_log.info(config.log_name, "diff: second capture in %s ms" % [String(capture_ms)])

	started = OS.get_ticks_msec()
	var patch = state_sync.diff_state(__diff_reference, current)
	var diff_ms = OS.get_ticks_msec() - started

	var patch_json = patch.to_json()
	var compressed = patch_json.to_utf8().compress(File.COMPRESSION_GZIP)

	var full_json = current.to_json()
	coop_log.info(config.log_name, "diff: %s of %s models changed" % [
		String(patch.size()), String(current.size())
	])
	coop_log.info(config.log_name, "diff: patch %s bytes raw, %s gzipped, built in %s ms" % [
		String(patch_json.length()), String(compressed.size()), String(diff_ms)
	])
	coop_log.info(config.log_name, "diff: whole state would be %s bytes raw" % [
		String(full_json.length())
	])
	coop_log.write_text(config.log_name + "-patch.json", patch_json)

	# Per model, so a dominant model is obvious.
	for name in patch:
		var node_json = patch[name].to_json()
		coop_log.info(config.log_name, "diff: %s patch=%s bytes" % [
			name, String(node_json.length())
		])

	# Apply the patch to a copy of the reference and require it to equal the real second state.
	started = OS.get_ticks_msec()
	var rebuilt = {}
	rebuilt.parse_json(__diff_reference.to_json())
	var touched = state_sync.patch_state(rebuilt, patch)
	var patch_ms = OS.get_ticks_msec() - started

	if state_sync.deep_equal(rebuilt, current):
		coop_log.info(config.log_name, "diff: patch reproduces the state exactly (%s models, %s ms)" % [
			String(touched.size()), String(patch_ms)
		])
	else:
		coop_log.error(config.log_name, "diff: patch does NOT reproduce the state, first difference: %s" % [
			state_sync.first_difference(current, rebuilt)
		])

	# Now rebuild the live models from the patched tree, as a client would.
	started = OS.get_ticks_msec()
	var applied = state_sync.apply_many(rebuilt, touched)
	var apply_ms = OS.get_ticks_msec() - started
	coop_log.info(config.log_name, "diff: rebuilt %s of %s models in %s ms" % [
		String(applied), String(touched.size()), String(apply_ms)
	])

	var mismatched = []
	for name in touched:
		if not state_sync.deep_equal(models.get_model(name).get_data(), current[name]):
			mismatched.push_back(name)
	if mismatched.size() == 0:
		coop_log.info(config.log_name, "diff: every rebuilt model matches the authoritative state")
	else:
		coop_log.warning(config.log_name, "diff: rebuilt models that differ: " + describe(mismatched))


# ---------------------------------------------------------------------------
# Stream test: the host half of the protocol, run against the real game.
#
# Primes a snapshot, then calls updater.update() every frame exactly as the host will, feeds
# every patch into a shadow copy the way a client would, and at the end proves the shadow
# equals the live state. Reports what the stream costs: bytes, gzipped bytes, and how long an
# update takes.
# ---------------------------------------------------------------------------
func __cost_descending(a, b):
	return a.ms > b.ms


func __run_streamtest():
	if __step < 5:
		return

	if __stream_phase == 0:
		__stream_phase = 1

		var started = OS.get_ticks_msec()
		var full = __updater.prime()
		var prime_ms = OS.get_ticks_msec() - started

		__stream_shadow = state_sync.decode_models(full)
		if __stream_shadow == null:
			coop_log.error(config.log_name, "stream: could not build the shadow from the snapshot")
			__stream_phase = 99
			return

		var full_json = __stream_shadow.to_json()
		coop_log.info(config.log_name, "stream: primed %s models in %s ms, snapshot %s bytes" % [
			String(full.size()), String(prime_ms), String(full_json.length())
		])

		var costs = []
		for name in __updater.last_cost:
			costs.push_back({name = name, ms = __updater.last_cost[name], bytes = full[name].length()})

		# No Array.sort(): sorting crashes this engine build. Pick the slowest N by selection.
		var picks = 8
		while picks > 0 and costs.size() > 0:
			var best = 0
			var index = 1
			while index < costs.size():
				if costs[index].ms > costs[best].ms:
					best = index
				index += 1
			var entry = costs[best]
			coop_log.info(config.log_name, "stream: cost %s = %s ms for %s bytes" % [
				entry.name, String(entry.ms), String(entry.bytes)
			])
			costs.remove(best)
			picks -= 1

		__stream_end_at = __elapsed + config.streamtest
		coop_log.info(config.log_name, "stream: running for %s s" % [String(config.streamtest)])
		return

	if __stream_phase == 1:
		if __elapsed - __stream_last_update < config.stream_interval:
			return
		__stream_last_update = __elapsed

		var started = OS.get_ticks_msec()
		var patch = __updater.update()
		var update_ms = OS.get_ticks_msec() - started

		__stream_updates += 1
		__stream_update_ms += update_ms
		if update_ms > __stream_update_max_ms:
			__stream_update_max_ms = update_ms

		if patch.size() > 0:
			var patch_json = patch.to_json()
			var gzipped = patch_json.to_utf8().compress(File.COMPRESSION_GZIP)
			__stream_patches += 1
			__stream_bytes += patch_json.length()
			__stream_gzip_bytes += gzipped.size()
			__stream_models += patch.size()

			var touched = state_sync.patch_state(__stream_shadow, patch)
			for name in touched:
				__stream_touched[name] = true

		if __elapsed >= __stream_end_at:
			__stream_phase = 2
			__finish_streamtest()
		return


func __finish_streamtest():
	coop_log.info(config.log_name, "stream: finished, comparing the shadow with the live state")

	# Freeze the clock first: otherwise the models keep advancing between the two reads and every
	# time-driven model looks like it failed to apply.
	var date_model = models.get_model("date")
	date_model.set_pause(true)

	var live = models.get_data()
	var live_copy = {}
	live_copy.parse_json(live.to_json())
	coop_log.info(config.log_name, "stream: live state captured")

	if state_sync.deep_equal(__stream_shadow, live_copy):
		coop_log.info(config.log_name, "stream: shadow matches the live state exactly")
	else:
		coop_log.error(config.log_name, "stream: shadow differs, first difference: %s" % [
			state_sync.first_difference(live_copy, __stream_shadow)
		])

	var average = 0.0
	if __stream_updates > 0:
		average = float(__stream_update_ms) / float(__stream_updates)

	coop_log.info(config.log_name, "stream: %s updates, %s with changes, avg %s ms, max %s ms" % [
		String(__stream_updates), String(__stream_patches),
		String(int(average)), String(__stream_update_max_ms)
	])
	coop_log.info(config.log_name, "stream: %s patches, %s bytes raw, %s bytes gzipped" % [
		String(__stream_patches), String(__stream_bytes), String(__stream_gzip_bytes)
	])
	coop_log.info(config.log_name, "stream: models touched: %s" % [
		String(__stream_touched.size())
	])

	# Rebuild the live models from the shadow, as a client does after every patch batch.
	var started = OS.get_ticks_msec()
	var applied = state_sync.apply_many(__stream_shadow, __stream_touched.keys())
	coop_log.info(config.log_name, "stream: rebuilt %s models in %s ms" % [
		String(applied), String(OS.get_ticks_msec() - started)
	])

	var mismatched = []
	for name in __stream_touched:
		if not state_sync.deep_equal(models.get_model(name).get_data(), live[name]):
			mismatched.push_back(name + ": " + state_sync.first_difference(live[name], models.get_model(name).get_data()))
	if mismatched.size() == 0:
		coop_log.info(config.log_name, "stream: every rebuilt model matches the authoritative state")
	else:
		coop_log.warning(config.log_name, "stream: rebuilt models that differ: " + describe(mismatched))


# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
func __probe_reflection(model):
	coop_log.info(config.log_name, "probe: property list of %s" % [String(model.get_name())])
	for prop in model.get_property_list():
		coop_log.info(config.log_name, "probe: prop name=%s type=%s usage=%s" % [
			String(prop.name), String(prop.type), String(prop.usage)
		])


func describe(value):
	# Array.to_json() is avoided on purpose: it kills this engine build. Dictionaries are fine.
	if typeof(value) == TYPE_DICTIONARY:
		return value.to_json()

	if typeof(value) == TYPE_ARRAY:
		var parts = []
		for item in value:
			parts.push_back(String(item))
		return "[" + join(parts, ", ") + "]"

	return String(value)


func join(parts, separator):
	var text = ""
	var index = 0
	while index < parts.size():
		if index > 0:
			text += separator
		text += parts[index]
		index += 1
	return text
