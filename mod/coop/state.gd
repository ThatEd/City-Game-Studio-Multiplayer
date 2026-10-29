extends Reference

# Game state capture, diffing and application.
#
# The whole simulation state of a running game is `models.get_data()`: a dict of model name ->
# plain data, which is exactly what the save file stores (scripts/save/save-manager.gd).
# Real sizes measured on a mid-game save (2012, huge map): 8.4 MB total, of which map 3.2 MB,
# staff 1.1 MB, studio 622 KB, player 93 KB.
#
# Two facts shape this file:
#
# 1. get_data() is only a shallow copy. Models hand back references to their own internal
#    dictionaries (currency.get_data() returns {mortgage = _mortgage} - the live dict), so a
#    captured tree keeps mutating unless it is deep copied. capture() therefore round-trips
#    through JSON, which is what a save does and is the only reliable snapshot.
# 2. Sending whole models is far too expensive: over two game weeks, 10 of 52 models change,
#    which costs 1.94 MB as whole models against 336 KB as path patches. So state travels as a
#    patch: a nested tree holding only the branches that differ.
#
# Patch node format (all keys optional, a node is a Dictionary):
#   {"=": value}                 replace this node with value (scalar, array, type change)
#   {"a": {key: value}}          keys added
#   {"m": {key: <node>}}         keys whose value changed further down
#   {"d": [key, ...]}            keys removed
# A null patch means "nothing changed".
#
# Applying a patch mutates a captured tree. Live models are then refreshed from that tree with
# apply(), because models only know how to be built from data, not patched.

# PROPERTY_USAGE_SCRIPT_VARIABLE, the only flag that marks a GDScript member variable.
const SCRIPT_VARIABLE = 8192


# A deep copy of the live state, safe to keep and mutate.
static func capture():
	var state = models.get_data()
	var copy = {}
	if copy.parse_json(state.to_json()) != OK:
		return null
	return copy


# {model name: full JSON} for a whole-state transfer (join).
static func encode_models(state):
	var encoded = {}
	for name in state:
		encoded[name] = state[name].to_json()
	return encoded


static func decode_models(encoded):
	var state = {}
	for name in encoded:
		var data = {}
		if data.parse_json(encoded[name]) == OK:
			state[name] = data
	return state


# A player's company as it was left in the world's save section, read out of the incoming world state.
static func saved_company(state, player_id):
	if state == null or not state.has("coop-state") or state["coop-state"] == null:
		return null
	var section = state["coop-state"]
	if not section.has("players") or section["players"] == null:
		return null
	var players = section["players"]
	if not players.has(player_id):
		return null
	return players[player_id]


# Empties the part of the world that decides "who are my customers" on this machine.
#
# The digital store model is the world's - every company's platform support and userbase lives in it -
# and the server model holds one company's usage. On a client both must start from nothing: a company
# that owns no console has no supported platform and no users, and its server usage is its own.
static func isolate_store(state):
	if state == null:
		return
	if state.has("digital-store") and state["digital-store"] != null:
		var store = state["digital-store"]
		# Who publishes on what, and how many customers they have there. This is the only part that has
		# to go: it is what made another company's console this company's, with its customers.
		store["platform"] = {}
		# The rest of the model keeps its shape. Emptying `reports` and `game_sales` outright broke the
		# store's own reporting ("Invalid get index 'development_total'"), because those sections are
		# read as dictionaries with expected keys rather than being optional.
		if store.has("game_sales") and store["game_sales"] != null:
			store["game_sales"]["list"] = {}
	if state.has("server") and state["server"] != null:
		var server = state["server"]
		# This company's own usage, which starts at nothing. The report is left alone for the same reason.
		server["usage"] = 0
		server["online_players"] = 0


# Conventions are two things at once, and they go opposite ways.
#
#   * The *catalogue* is the world's: which conventions happen, where, in which month, how big. Both
#     players must see the same list, or one of them would be booking a stand at an event the other
#     cannot see - and the month a convention falls in is how the game decides it is time to run it.
#   * A player's *participation* is their own: the conventions they planned and paid for, the ones
#     running for them, the ones already attended, the games they put on the stand, and whether they
#     auto-attend at all. Sharing that would hand one player the other's schedule and their stand.
#
# The incoming world therefore keeps `generated` and `announced` (the catalogue) and starts this company
# with nothing planned, running or archived, with auto-attend off.
static func isolate_conventions(state):
	if state == null or not state.has("convention") or state["convention"] == null:
		return
	var convention = state["convention"]
	convention["planned"] = []
	convention["running"] = []
	convention["archived"] = []
	convention["autoattend"] = {stand_size_index = 0, enabled = false}


# The catalogue of conventions this machine knows, so it can be published to the other players.
#
# Only the shared half: the static list the game ships with plus anything generated for this session, and
# which of them have been announced. Everything a player does with them stays local.
static func convention_catalogue():
	if not models.has_model("convention"):
		return null
	var convention = models.get_model("convention")
	var data = convention.get_data()
	return {
		generated = data["generated"] if data.has("generated") else {},
		announced = data["announced"] if data.has("announced") else {}
	}


# Puts the other player's catalogue into this machine's convention model without disturbing what this
# player has done. Entries are matched by id, so an event already known here keeps its local identity.
static func apply_convention_catalogue(catalogue):
	if catalogue == null or not models.has_model("convention"):
		return 0
	var convention = models.get_model("convention")
	var data = convention.get_data()
	var added = 0
	if catalogue.has("generated") and catalogue["generated"] != null:
		var generated = catalogue["generated"]
		if not generated.empty():
			convention.call("generate_convention", generated)
			added += 1
	if catalogue.has("announced") and catalogue["announced"] != null:
		var announced = data["announced"] if data.has("announced") else {}
		for key in catalogue["announced"]:
			if not announced.has(key):
				announced[key] = catalogue["announced"][key]
				added += 1
	return added


# The company models captured from a brand-new game, or null when the mod was built without them.
static func load_company_backup():
	var file = File.new()
	if file.open("res://coop/fresh-company.json", File.READ) != OK:
		return null
	var text = file.get_as_text()
	file.close()

	var payload = {}
	if payload.parse_json(text) != OK:
		return null
	if not payload.has("models"):
		return null
	return payload["models"]


# {model name: data} for the models named, deep-copied through JSON so it can be held while the
# live game keeps running.
static func capture_models(names):
	var all = models.get_data()
	var picked = {}
	for name in names:
		if all.has(name):
			picked[name] = all[name]

	var copy = {}
	if copy.parse_json(picked.to_json()) != OK:
		return null
	return copy


# The first studio in a captured company, so a client that created its company in the game's own New
# Game dialogue can keep that office (its items, staff and layout) while it is moved onto a tile of
# the host's map.
static func first_studio(backup):
	if backup == null or not backup.has("studio"):
		return null
	var studio = backup["studio"]
	if studio == null or not studio.has("list") or studio["list"] == null:
		return null
	for studio_id in studio["list"]:
		var record = studio["list"][studio_id]
		if record != null:
			record["_source_id"] = String(studio_id)
			return record
	return null
#
# The studio model is special. Its entries are the host's company, so they must not survive the
# merge, but a studio id is also a map tile id: a studio carried over from another game points at a
# tile this world does not have, which put the map camera on nil. So the captured model is taken as a
# shape only, emptied, and the client's first office is opened on a free tile of this world afterwards
# by company.open_first_studio().
static func merge_company(state, backup):
	var taken = []
	for name in backup:
		state[name] = backup[name]
		taken.push_back(name)

	if not state.has("studio"):
		return taken
	state["studio"] = __empty_studio_model()
	taken.push_back("studio (emptied: the host's studios are the host's company)")
	return taken


# Empties the studio model only. Used when a player takes over a company that already exists in the
# host's world: its offices come from that company's record, not from the host's own studios.
static func empty_studios(state):
	if state.has("studio"):
		state["studio"] = __empty_studio_model()


# A company shape with nothing of the host in it, for a player taking over an existing company: the
# host's studios, staff and games are the host's company and must not become the player's. The
# player's identity, money and fanbase then come from the competitor record being taken over.
static func merge_company_for_takeover(state, backup):
	var taken = merge_company(state, backup)
	if state.has("staff"):
		var staff = state["staff"]
		for key in staff.keys():
			staff[key] = {}
	return taken


static func __empty_studio_model():
	return {
		list = {},
		selected = null,
		selected_group = [],
		forced_happiness = 0
	}


# Nested patch of `cur` relative to `prev`, or null when they are equal.
static func diff(prev, cur):
	if not deep_equal(prev, cur):
		if typeof(prev) != TYPE_DICTIONARY or typeof(cur) != TYPE_DICTIONARY:
			return {"=": cur}

	var changed = {}
	var added = {}
	var removed = []

	if typeof(cur) != TYPE_DICTIONARY:
		return null

	for key in cur:
		if not prev.has(key):
			added[key] = cur[key]
		else:
			var sub = diff(prev[key], cur[key])
			if sub != null:
				changed[key] = sub

	for key in prev:
		if not cur.has(key):
			removed.push_back(key)

	if changed.size() == 0 and added.size() == 0 and removed.size() == 0:
		return null

	var node = {}
	if changed.size() > 0:
		node["m"] = changed
	if added.size() > 0:
		node["a"] = added
	if removed.size() > 0:
		node["d"] = removed
	return node


# Patch of the whole state: {model name: node} for the models that changed, or {} if none.
static func diff_state(prev, cur):
	var patch = {}
	for name in cur:
		if not prev.has(name):
			patch[name] = {"=": cur[name]}
			continue
		var node = diff(prev[name], cur[name])
		if node != null:
			patch[name] = node
	for name in prev:
		if not cur.has(name):
			patch[name] = {"=": null}
	return patch


# Applies `patch` to `state` in place. Returns the list of model names it touched.
static func patch_state(state, patch):
	var touched = []
	for name in patch:
		var node = patch[name]
		if node.has("="):
			var value = node["="]
			if value == null:
				state.erase(name)
			else:
				state[name] = value
		else:
			if not state.has(name) or typeof(state[name]) != TYPE_DICTIONARY:
				state[name] = {}
			patch_node(state[name], node)
		touched.push_back(name)
	return touched


static func patch_node(target, node):
	if node.has("a"):
		var added = node["a"]
		for key in added:
			target[key] = added[key]

	if node.has("m"):
		var changed = node["m"]
		for key in changed:
			var sub = changed[key]
			if sub.has("="):
				target[key] = sub["="]
			else:
				if not target.has(key) or typeof(target[key]) != TYPE_DICTIONARY:
					target[key] = {}
				patch_node(target[key], sub)

	if node.has("d"):
		for key in node["d"]:
			target.erase(key)


# Writes `data` into the live model. Models have no set_data(), only _init(data), so a
# throwaway instance of the same script is built from the data and its member variables are
# copied across. A variable is skipped when the new instance holds null and the live model does
# not: those are `onready` values (resolved in the tree, null on an orphan) and lazily built
# caches, and overwriting a working one with null is the one way this could corrupt a session.
static func apply(name, data):
	if not models.has_model(name):
		return false

	var model = models.get_model(name)
	var script = model.get_script()
	if script == null:
		return false

	var fresh = script.new(data)
	for prop in model.get_property_list():
		if prop.usage != SCRIPT_VARIABLE:
			continue
		var incoming = fresh.get(prop.name)
		if incoming == null and model.get(prop.name) != null:
			continue
		model.set(prop.name, incoming)

	fresh.free()
	return true


static func apply_many(state, names):
	var applied = 0
	for name in names:
		if state.has(name) and apply(name, state[name]):
			applied += 1
	return applied


# Structural equality that tolerates the int/float split JSON brings: a value written as 1 and
# read back as 1.0 is the same number for this purpose.
static func deep_equal(a, b):
	var a_numeric = typeof(a) == TYPE_INT or typeof(a) == TYPE_REAL
	var b_numeric = typeof(b) == TYPE_INT or typeof(b) == TYPE_REAL
	if a_numeric and b_numeric:
		return abs(float(a) - float(b)) <= 1e-09

	if typeof(a) != typeof(b):
		return false

	if typeof(a) == TYPE_DICTIONARY:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key):
				return false
			if not deep_equal(a[key], b[key]):
				return false
		return true

	if typeof(a) == TYPE_ARRAY:
		if a.size() != b.size():
			return false
		var index = 0
		while index < a.size():
			if not deep_equal(a[index], b[index]):
				return false
			index += 1
		return true

	return a == b


# First difference between two trees, for diagnostics ("staff/producer/xyz/activity").
static func first_difference(a, b, path = ""):
	if typeof(a) != typeof(b):
		return path + " (type)"
	if typeof(a) == TYPE_DICTIONARY:
		for key in a:
			if not b.has(key):
				return path + "/" + String(key) + " (missing)"
			var found = first_difference(a[key], b[key], path + "/" + String(key))
			if found != "":
				return found
		for key in b:
			if not a.has(key):
				return path + "/" + String(key) + " (extra)"
		return ""
	if typeof(a) == TYPE_ARRAY:
		if a.size() != b.size():
			return path + " (size " + String(a.size()) + " vs " + String(b.size()) + ")"
		var index = 0
		while index < a.size():
			var found = first_difference(a[index], b[index], path + "[" + String(index) + "]")
			if found != "":
				return found
			index += 1
		return ""
	if deep_equal(a, b):
		return ""
	return path + " (" + String(a) + " vs " + String(b) + ")"
