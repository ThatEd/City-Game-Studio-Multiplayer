extends Node

# Replacement for res://scripts/errorhandler.gd (the build swaps it in and drops its remap).
#
# Why: the retail handler connects GodotErrorHandler's `error_threw` signal and, for any error
# it does not ignore, posts a report to https://bugreport.binogure-studio.com containing the
# error, the current scene, the executable path and OS.get_cmdline_args(). For a modded build
# that would leak the mod (script paths, its arguments) to the developer on someone else's
# machine, so the mod logs errors locally instead and never sends anything.
#
# The public surface is kept so nothing else breaks: `is_debug_build()`, `error_handler(dump)`
# and `send_report(user_content, dump)` (the in-game bug report dialog calls the last one).

const coop_log = preload("res://coop/log.gd")

const LOG_NAME = "coop-errors"


# Each instance writes its own error file, named after its run, and starts it empty.
#
# One shared file grew to 200 MB across runs and buried the current run's errors under old ones - the
# first real error of a session was tens of thousands of lines in. Per-run files are also the only way
# two instances in one folder can be told apart.
func _log_name():
	# Taken from the command line rather than from the coop autoload: this file may be ready before that
	# autoload exists, so reading its properties here would be a null dereference at boot. Object.get()
	# is also missing from this engine build, so there is no safe way to probe it.
	for arg in OS.get_cmdline_args():
		var text = String(arg)
		if text.begins_with("--coop-log="):
			var given = text.substr("--coop-log=".length(), text.length())
			if given != "":
				return LOG_NAME + "-" + given
	return LOG_NAME


var __truncated = {}


func _ready():
	GodotErrorHandler.connect("error_threw", self, "error_handler", [], CONNECT_DEFERRED)
	coop_log.info(_file_for(), "error handler replaced: local logging only, nothing is sent")


func is_debug_build():
	return OS.is_debug_build()


# Each instance gets its own file, started empty on the first write.
#
# One shared file grew to 200 MB across runs and buried the current run's errors under old ones - the
# first real error of a session was tens of thousands of lines in. It is emptied on first use rather
# than in _ready so the name and the truncation cannot disagree.
func _file_for():
	var name = _log_name()
	if not __truncated.has(name):
		__truncated[name] = true
		coop_log.truncate(name)
	return name


func error_handler(dump = null):
	coop_log.error(_file_for(), "script error: " + describe(dump))


func send_report(user_content = null, dump = null):
	coop_log.warning(_file_for(), "bug report suppressed (not sent): " + describe(user_content))


func describe(dump):
	if dump == null:
		return "<null>"

	if typeof(dump) == TYPE_DICTIONARY:
		var parts = []
		for key in dump:
			parts.push_back(String(key) + "=" + String(dump[key]))
		return "{" + join(parts, ", ") + "}"

	return String(dump)


func join(parts, separator):
	var text = ""
	var index = 0
	while index < parts.size():
		if index > 0:
			text += separator
		text += parts[index]
		index += 1
	return text
