extends Node

# Per-player company data, stored in the save.
#
# How this works: scripts/models/main.gd builds its model list by scanning res://scripts/models, so
# every script in that folder becomes a model. A model's get_data() is part of the dictionary that
# save-manager writes (`models.get_data()` -> JSON -> gzip -> encrypted), and it is handed back to
# _init() on load. Putting this script in that folder therefore gives the co-op session its own
# section of the save - a header the game itself never reads or writes - without touching the game's
# own models or the save format.
#
# What it holds: for every player in this world, their company layout, their studios, the games they
# have released, and whether the host has agreed to carry on without them. That is what makes a
# player's company part of the world instead of something rebuilt from network messages on join.
#
# Shape:
#
#     {
#       version: 1,
#       players: {
#         "coop-alice": {
#           name, note, currency, fanbase,
#           offices: [ {t: tile id, n: display name} ],
#           games:   [ {id, name, note, units, platform, date, state} ],
#           studios: [ {t: tile id, area, items, buildMod, productivity, happiness} ],
#           present: true|false,          # connected right now
#           host_confirmed: true|false    # host allowed the AI to carry on without them
#         }
#       }
#     }

const VERSION = 1

var _players = {}
# Offers that have been settled, by id. Kept separately from the offer records themselves: a copy of an
# offer can arrive again after it was accepted, and a settled transfer must never be applied twice.
var _settled = {}


func _init(data):
	if data == null:
		return
	if data.has("players") and data["players"] != null:
		_players = data["players"]
	if data.has("settled") and data["settled"] != null:
		_settled = data["settled"]
	if not data.has("version"):
		data["version"] = VERSION


func get_data():
	return {
		version = VERSION,
		players = _players,
		settled = _settled
	}


func settle(offer_id):
	if String(offer_id) == "":
		return false
	_settled[String(offer_id)] = true
	return true


func is_settled(offer_id):
	return _settled.has(String(offer_id))


func get_players():
	return _players


func has_player(player_id):
	return _players.has(String(player_id))


func get_player(player_id):
	var key = String(player_id)
	if _players.has(key):
		return _players[key]
	return null


func set_player(player_id, payload):
	var key = String(player_id)
	if payload == null:
		_players.erase(key)
		return
	_players[key] = payload


func ids():
	return _players.keys()


func mark_present(player_id, present):
	var entry = get_player(player_id)
	if entry == null:
		return false
	entry["present"] = present
	if present:
		# A player who comes back is theirs again; permission for the AI to run their company is
		# withdrawn, so the AI stops and the company is handed back.
		entry["host_confirmed"] = false
	return true


func set_host_confirmed(player_id, confirmed):
	var entry = get_player(player_id)
	if entry == null:
		return false
	entry["host_confirmed"] = confirmed
	return true
