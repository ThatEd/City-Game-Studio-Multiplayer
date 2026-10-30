extends Reference

# Command line parsing for the co-op mod.
#
# Godot 2 pushes every argument it does not recognise into main_args, which is what
# OS.get_cmdline_args() returns (main/main.cpp). But a *bare* word there is dangerous: if the
# first main_arg does not start with "-", Main::start treats it as the scene to run, so
# `--coop-port 7470` makes the engine try to open `res://7470` as the main scene and the game
# dies before a single autoload's _ready runs. Every value here therefore rides inside the
# flag itself:
#
#   --coop-host                 start as host
#   --coop-join=<host>          start as client, connecting to <host>
#   --coop-port=<n>             port for both roles (default 7470)
#   --coop-name=<name>          player name shown to the other player
#   --coop-log=<name>           log file base name (default coop-<role>)
#   --coop-autojoin             client: keep retrying until the host answers
#   --coop-selftest             host: log what the mod can see of the game state
#   --coop-quit=<seconds>       quit after N seconds (automated tests)

const DEFAULT_PORT = 7470
const PREFIX = "--coop"


static func parse(args):
	var result = {
		role = "off",
		host = "127.0.0.1",
		port = DEFAULT_PORT,
		name = "player",
		log_name = "",
		autojoin = false,
		selftest = false,
		report = false,
		probe = false,
		refresh = false,
		api_probe = false,
		read_test = false,
		no_publish = false,
		no_clock = false,
		ping = false,
		trace = false,
		mute_test = false,
		spawn_test = 0,
		continue_without = false,
		buy_test = "",
		console_test = false,
		spam_test = false,
		verify = 0.0,
		tech_probe = false,
	office_test = "",
	play = 0.0,
	play_paused = false,
	play_release = false,
		pilot = 0.0,
		remote = false,
		lobby = true,
	trace_steps = false,
	dump = 0.0,
		research = "",
		menu_dump = 0.0,
		menu_test = 0.0,
		ui_test = 0.0,
		offer_auto = false,
		gift = "",
		capture_fresh = false,
		dict_test = false,
		second_snapshot = -1.0,
		difftest = 0.0,
		streamtest = 0.0,
		stream_interval = 1.0,
		settle = 0.0,
		unpause = false,
		load_save = "",
		company_choice = "",
		company_name = "",
		noautosave = false,
		map_size = -1,
		game_speed = -1,
		game_speed_request = 0,
		difficulty = -1,
		competitors = -1,
		quit_after = -1.0,
		unknown = []
	}

	for arg in args:
		if not arg.begins_with(PREFIX):
			continue

		var flag = arg
		var value = ""
		var separator = arg.find("=")
		if separator >= 0:
			flag = arg.substr(0, separator)
			value = arg.substr(separator + 1, arg.length() - separator - 1)

		if flag == "--coop-host":
			result.role = "host"

		elif flag == "--coop-join":
			result.role = "client"
			if value != "":
				result.host = value

		elif flag == "--coop-company":
			result.company_choice = value

		elif flag == "--coop-company-name":
			result.company_name = value

		elif flag == "--coop-server":
			result.role = "client"
			if value != "":
				result.host = value

		elif flag == "--coop-port":
			result.port = int(value)

		elif flag == "--coop-name":
			result.name = value

		elif flag == "--coop-log":
			result.log_name = value

		elif flag == "--coop-autojoin":
			result.autojoin = true

		elif flag == "--coop-selftest":
			result.selftest = true

		elif flag == "--coop-report":
			result.report = true

		elif flag == "--coop-probe":
			result.probe = true

		elif flag == "--coop-refresh":
			result.refresh = true

		elif flag == "--coop-api":
			result.api_probe = true

		elif flag == "--coop-readtest":
			result.read_test = true

		elif flag == "--coop-no-publish":
			result.no_publish = true

		elif flag == "--coop-no-clock":
			result.no_clock = true

		elif flag == "--coop-ping":
			result.ping = true

		elif flag == "--coop-trace":
			result.trace = true

		elif flag == "--coop-mutetest":
			result.mute_test = true

		elif flag == "--coop-spawntest":
			result.spawn_test = int(value) if value != "" else 9

		elif flag == "--coop-continue-without":
			result.continue_without = true

		elif flag == "--coop-buytest":
			result.buy_test = value

		elif flag == "--coop-consoletest":
			result.console_test = true

		elif flag == "--coop-spamtest":
			result.spam_test = true

		elif flag == "--coop-verify":
			result.verify = float(value) if value != "" else 12.0

		elif flag == "--coop-techprobe":
			result.tech_probe = true

		elif flag == "--coop-officetest":
			result.office_test = value if value != "" else "unfit"

		elif flag == "--coop-play":
			result.play = float(value) if value != "" else 1800.0

		elif flag == "--coop-play-paused":
			result.play_paused = true

		elif flag == "--coop-play-release":
			result.play_release = true

		elif flag == "--coop-pilot":
			result.pilot = float(value) if value != "" else 40.0

		elif flag == "--coop-lobby":
			result.lobby = value != "off"

		elif flag == "--coop-trace-steps":
			result.trace_steps = true

		elif flag == "--coop-remote":
			result.remote = true

		elif flag == "--coop-dump":
			result.dump = float(value) if value != "" else 20.0

		elif flag == "--coop-research":
			result.research = value

		elif flag == "--coop-offer-auto":
			result.offer_auto = true

		elif flag == "--coop-gift":
			result.gift = value

		elif flag == "--coop-menudump":
			result.menu_dump = float(value) if value != "" else 6.0

		elif flag == "--coop-menutest":
			result.menu_test = float(value) if value != "" else 6.0

		elif flag == "--coop-uitest":
			result.ui_test = float(value) if value != "" else 30.0

		elif flag == "--coop-capture-fresh":
			result.capture_fresh = true

		elif flag == "--coop-dicttest":
			result.dict_test = true

		elif flag == "--coop-second-snapshot":
			result.second_snapshot = float(value)

		elif flag == "--coop-difftest":
			result.difftest = float(value)

		elif flag == "--coop-streamtest":
			result.streamtest = float(value)

		elif flag == "--coop-stream-interval":
			result.stream_interval = float(value)

		elif flag == "--coop-settle":
			result.settle = float(value)

		elif flag == "--coop-unpause":
			result.unpause = true

		elif flag == "--coop-load":
			result.load_save = value

		elif flag == "--coop-noautosave":
			result.noautosave = true

		elif flag == "--coop-map":
			result.map_size = int(value)

		elif flag == "--coop-speed":
			# The clock speed the test wants held (1/2/4/6). Not the same as the game's weeks-per-month
			# setting, which is what --coop-weeks does.
			result.game_speed_request = int(value)

		elif flag == "--coop-weeks":
			result.game_speed = int(value)

		elif flag == "--coop-difficulty":
			result.difficulty = int(value)

		elif flag == "--coop-competitors":
			result.competitors = int(value)

		elif flag == "--coop-quit":
			result.quit_after = float(value)

		else:
			result.unknown.push_back(arg)

	if result.log_name == "":
		result.log_name = "coop-" + result.role

	return result
