extends Reference

# Running state updater: turns the live game into a stream of patches.
#
# Whatever a client receives has to be cheap to produce, because it runs inside the game's main
# loop. Measured on a mid-game save (8.0 MB of state): serialising the whole state to JSON takes
# about 1.4 s and diffing two full trees in GDScript about 1.3 s, which is far too much to do
# every update.
#
# So change detection is per model and uses the string the serialiser already produced:
#   - name the models that changed by comparing each model's JSON with the previous one,
#   - parse and diff only those, which was ~250 KB of the 8 MB in practice.
# The unavoidable floor is one to_json() per model per update (the game exposes no revision
# counter on a model), and it is measured and logged rather than hidden.

const state_sync = preload("res://coop/state.gd")

var last_json = {}      # model name -> JSON string of its data at the last update
var last_data = {}      # model name -> deep copy of its data at the last update
var last_cost = {}      # model name -> milliseconds its serialisation took
var ready = false

# Timing of the last update, in milliseconds.
var last_serialise_ms = 0
var last_diff_ms = 0
var last_models_changed = 0


# Takes the first snapshot. Returns {model name: JSON} - the payload a joining client needs.
func prime():
	last_json = {}
	last_data = {}
	ready = false

	var started = OS.get_ticks_msec()
	var current = models.get_data()
	var encoded = {}

	for name in current:
		var model_started = OS.get_ticks_msec()
		var json = current[name].to_json()
		var model_ms = OS.get_ticks_msec() - model_started

		# Keep a deep copy through JSON rather than Dictionary.duplicate(true): the JSON is
		# already produced, it matches exactly what a client would hold, and it avoids relying
		# on duplicate() over data that contains engine container types.
		var copy = {}
		copy.parse_json(json)

		encoded[name] = json
		last_json[name] = json
		last_data[name] = copy
		last_cost[name] = model_ms

	last_serialise_ms = OS.get_ticks_msec() - started
	last_models_changed = current.size()
	ready = true
	return encoded

# Compares the live state with the last snapshot and returns the patch, or {} when nothing
# changed. `names` limits the poll to those models (a tier); without it every model is polled.
func update(names = null):
	if not ready:
		prime()
		return {"_full": true}

	var started = OS.get_ticks_msec()
	var current = models.get_data()
	var fresh_json = {}
	var changed = []

	for name in current:
		if names != null and not names.has(name):
			continue
		var json = current[name].to_json()
		fresh_json[name] = json
		if not last_json.has(name) or last_json[name] != json:
			changed.push_back(name)

	var removed = []
	if names == null:
		for name in last_json:
			if not current.has(name):
				removed.push_back(name)

	last_serialise_ms = OS.get_ticks_msec() - started

	if changed.size() == 0 and removed.size() == 0:
		last_models_changed = 0
		last_diff_ms = 0
		return {}

	started = OS.get_ticks_msec()
	var patch = {}

	for name in changed:
		var new_data = {}
		if new_data.parse_json(fresh_json[name]) != OK:
			patch[name] = {"=": null}
			last_json.erase(name)
			continue

		if last_data.has(name):
			var node = state_sync.diff(last_data[name], new_data)
			if node != null:
				patch[name] = node
		else:
			patch[name] = {"=": new_data}

		# Keep the deep copy of what the model reported: get_data() hands back references to the
		# model's own containers, so only a copy stays valid as the model keeps changing.
		last_data[name] = new_data
		last_json[name] = fresh_json[name]

	for name in removed:
		patch[name] = {"=": null}
		last_json.erase(name)
		last_data.erase(name)

	last_diff_ms = OS.get_ticks_msec() - started
	last_models_changed = patch.size()
	return patch
