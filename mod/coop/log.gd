extends Reference

# Local file log for the co-op mod.
#
# The retail build disables stdout (application/disable_stdout in engine.cfb), so print()
# goes nowhere and the game's own logger keeps messages in memory only. Everything the mod
# and its tests need to assert on is written here instead, next to the executable, where a
# test script can read it after the process exits.

const DIRECTORY_NAME = "coop"

# Sits beside the executable, so several instances started from one build folder each write
# their own file when `name` includes the role or port.
static func directory():
	var path = OS.get_executable_path().get_base_dir() + "/" + DIRECTORY_NAME
	var dir = Directory.new()
	if not dir.dir_exists(path):
		dir.make_dir_recursive(path)
	return path


static func path_for(name):
	return directory() + "/" + name + ".log"


static func write(name, level, message):
	var target = path_for(name)
	var file = File.new()
	var append = file.file_exists(target)
	var mode = File.WRITE
	if append:
		mode = File.READ_WRITE

	if file.open(target, mode) != OK:
		return false

	if append:
		file.seek_end()

	var now = OS.get_time()
	file.store_line("[%02d:%02d:%02d] %s %s" % [now.hour, now.minute, now.second, level, message])
	file.close()
	return true


static func info(name, message):
	return write(name, "INFO", message)


static func warning(name, message):
	return write(name, "WARN", message)


static func error(name, message):
	return write(name, "ERROR", message)


static func truncate(name):
	var file = File.new()
	if file.file_exists(path_for(name)):
		file.open(path_for(name), File.WRITE)
		file.close()
		return true
	return false


# Writes a whole text file (used for state snapshots and diffs, which are too big to log).
static func write_text(name, text):
	var file = File.new()
	if file.open(directory() + "/" + name, File.WRITE) != OK:
		return false
	file.store_string(text)
	file.close()
	return true


static func read_text(name):
	var file = File.new()
	if not file.file_exists(directory() + "/" + name):
		return null
	if file.open(directory() + "/" + name, File.READ) != OK:
		return null
	return file.get_as_text()
