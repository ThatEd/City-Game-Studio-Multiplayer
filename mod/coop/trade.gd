extends Reference

# Transfers between players: money, technology, and the IP of a published game.
#
# Shape of an offer (stored in the world's company section, see scripts/models/coop-state.gd):
#
#   { id, from, to, kind, payload, created, status }
#
#   kind "money"  payload = {amount}
#   kind "tech"   payload = {type}          a game genre, the game's own technology unit
#   kind "ip"     payload = {game_id, name, game}
#
# Nothing moves until the recipient accepts, and both machines apply the same rule from the same offer,
# so the two sides cannot disagree about what was transferred. The offer is kept after acceptance with
# status "accepted", which is what stops it being applied twice.

const MONEY = "money"
const TECH = "tech"
const IP = "ip"

const coop_log = preload("res://coop/log.gd")
const dict_lib = preload("res://coop/dict.gd")


static func make(from_id, to_id, kind, payload):
	return {
		id = new_id("offer", from_id),
		from = String(from_id),
		to = String(to_id),
		kind = String(kind),
		payload = payload,
		created = int(OS.get_ticks_msec()),
		status = "pending"
	}


# Ids are made here rather than with str2var(), which this build does not provide, and they carry the
# player id so two machines cannot accidentally pick the same one.
static func new_id(prefix, owner):
	randomize()
	return "%s-%s-%s-%s" % [prefix, String(owner), String(OS.get_ticks_msec()), String(randi())]


static func describe(offer):
	if offer == null:
		return "?"
	var kind = String(offer["kind"]) if offer.has("kind") else "?"
	if kind == MONEY:
		return "%s offered %s money" % [String(offer["from"]), String(offer["payload"]["amount"])]
	if kind == TECH:
		return "%s offered the %s technology" % [String(offer["from"]),
			dict_lib.text(offer["payload"], "label", "unnamed")]
	if kind == IP:
		return "%s offered the IP of %s" % [String(offer["from"]), String(offer["payload"]["name"])]
	return "%s offered %s" % [String(offer["from"]), kind]


# Gives this machine its side of an accepted offer. `accepting` is true on the side that took the offer
# and false on the side that made it, which is the only difference between the two.
static func apply(offer, accepting, log_name):
	if offer == null or not offer.has("kind"):
		return "nothing to apply"
	var kind = String(offer["kind"])
	var payload = offer["payload"]

	if kind == MONEY:
		var amount = int(payload["amount"])
		var currency = models.get_model("currency")
		# A payment the payer cannot afford is refused here as well as at the offer. The giver applies its
		# own side from the same offer record, and an offer made minutes ago can outlive the money it was
		# made against - so "did they have it when they offered?" is not the question that matters at the
		# moment money moves.
		if not accepting and amount > int(currency.get_currency()):
			coop_log.warning(log_name, "trade: refusing to hand over %s, this company holds %s" % [
				String(amount), String(currency.get_currency())
			])
			return "money %s refused, the payer cannot cover it" % [String(amount)]
		# currency.update_currency() *subtracts* its argument (models/currency.gd), so a gain is negative
		# and a payment is positive. Both sides read the same amount from the same offer.
		if accepting:
			currency.update_currency(-amount)
			currency.custom_report("INCOMES", "coop-transfer", amount)
		else:
			currency.update_currency(amount)
			currency.custom_report("COGS", "coop-transfer", amount)
		coop_log.info(log_name, "trade: money %s %s, balance is now %s" % [
			String(amount), "received" if accepting else "paid", String(currency.get_currency())
		])
		return "money %s" % [String(amount)]

	if kind == TECH:
		# The game's unit of technology is an unlocked game genre (game-type): a company unlocks one by
		# research, by date, or by buying it ahead of the date. A gift, not a trade, so the giver keeps
		# what it knows.
		var type_id = String(payload["type"])
		var label = dict_lib.text(payload, "label", type_id)
		if not accepting:
			return "technology given away, nothing to do here"
		var gametype = models.get_model("game-type")
		if gametype.is_game_type_unlocked(type_id):
			return "%s was already known" % [label]
		gametype.unlock_game_type(type_id, true)
		coop_log.info(log_name, "trade: the %s technology is unlocked here" % [label])
		return "technology %s" % [label]

	if kind == IP:
		var game_id = String(payload["game_id"])
		var game = payload["game"]
		var game_model = models.get_model("game")
		var catalog = game_model.get_data()["catalog"]
		if accepting:
			# The receiver holds the IP and can work with it; it is not published as theirs, so it cannot
			# double-count sales of a game it did not sell.
			if catalog.has("hold") and catalog["hold"] != null:
				catalog["hold"][game_id] = game
			coop_log.info(log_name, "trade: acquired the IP of %s" % [String(payload["name"])])
			return "IP %s" % [String(payload["name"])]

		# The giver stops selling it: the game moves from published to discontinued, which is what the
		# game itself does with a title it no longer sells.
		if catalog.has("published") and catalog["published"] != null and catalog["published"].has(game_id):
			var moved = catalog["published"][game_id]
			catalog["published"].erase(game_id)
			if catalog.has("discontinued") and catalog["discontinued"] != null:
				catalog["discontinued"][game_id] = moved
		coop_log.info(log_name, "trade: the IP of %s is no longer ours to sell" % [String(payload["name"])])
		return "gave up IP %s" % [String(payload["name"])]

	return "unknown kind %s" % [kind]


# The offers waiting for this player, written by the host into the world's company section.
static func pending_for(player_id):
	if not models.has_model("coop-state"):
		return []
	var entry = models.get_model("coop-state").get_player(player_id)
	if entry == null or not entry.has("offers") or entry["offers"] == null:
		return []
	var waiting = []
	for offer_id in entry["offers"]:
		var offer = entry["offers"][offer_id]
		if offer != null and offer.has("status") and String(offer["status"]) == "pending":
			waiting.push_back(offer)
	return waiting


# Records an offer in the world's company section, under both players, so either side can find it.
static func store(offer, log_name = "coop"):
	if not models.has_model("coop-state"):
		return false
	# A copy of an offer can arrive again after it was settled (the host relays, clients re-ask); the
	# settled record must not be replaced by a fresh "pending" one.
	if is_settled(String(offer["id"])):
		return false
	var coop = models.get_model("coop-state")
	var stored = 0
	for player_id in [String(offer["from"]), String(offer["to"])]:
		var entry = coop.get_player(player_id)
		if entry == null:
			# The entry is created rather than skipped.
			#
			# `continue` here dropped offers on the floor. On a client, the host's coop-state entry does
			# not exist until the host's company record has arrived and been saved into the world - and an
			# offer can arrive first. The offer then vanished: the client logged "coop-highland offered the
			# LABEL_TYPE_SPACE technology", stored nothing, and the panel correctly reported "0 pending
			# offer(s)". Nothing failed, so nothing was noticed.
			entry = {name = String(player_id)}
			coop.set_player(player_id, entry)
			coop_log.info(log_name, "trade: created the coop-state entry for %s to hold an offer"
				% [String(player_id)])
		if not entry.has("offers") or entry["offers"] == null:
			entry["offers"] = {}
		entry["offers"][String(offer["id"])] = offer
		stored += 1
	if stored == 0:
		coop_log.warning(log_name, "trade: could not store %s in either player's section"
			% [String(offer["id"])])
	return stored > 0


static func set_status(offer_id, status):
	if not models.has_model("coop-state"):
		return
	var coop = models.get_model("coop-state")
	if String(status) == "accepted":
		coop.settle(offer_id)
	for player_id in coop.ids():
		var entry = coop.get_player(player_id)
		if entry == null or not entry.has("offers") or entry["offers"] == null:
			continue
		if entry["offers"].has(offer_id):
			entry["offers"][offer_id]["status"] = status


# An accepted offer must never be applied twice, and both players may hear about the same acceptance
# from different directions, so every apply site asks this first. The record lives in the save, so a
# transfer is not repeated after a reload either.
static func is_settled(offer_id):
	if String(offer_id) == "" or not models.has_model("coop-state"):
		return false
	return models.get_model("coop-state").is_settled(offer_id)
