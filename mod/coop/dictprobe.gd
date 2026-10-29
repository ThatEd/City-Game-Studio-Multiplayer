extends Reference

# Certifies the Variant members the co-op mod is allowed to use on the receive path.
#
# Why this exists: this engine build ships a stripped Variant method table. Calling a member that
# is not in it does not raise an error, it dereferences the missing table entry and the process
# dies with an access violation inside _VariantCall::FuncData::call (core\variant_call.cpp,
# "Condition 'p_argcount > 5' is true." sits right next to the faulting instruction). That is what
# killed every host the moment the first message from the relay arrived, and the crash report
# named no script line because it is a native fault, not a GDScript error.
#
# Found missing so far: Dictionary.get(key) and Dictionary.get(key, default). Everything below has
# to keep working, so it is checked after every engine-facing change: run
#     --coop-dicttest --coop-log=dicttest
# and the log must end with "all steps done".
#
# One call per tick, with a line logged before it, so a crash names the member that caused it.

const coop_log = preload("res://coop/log.gd")
const JSON_TEXT = "{\"t\":\"pong\",\"e\":\"1\",\"n\":7,\"b\":true}"
const NESTED_TEXT = "{\"a\":{\"b\":[1,2]},\"c\":\"x\"}"

var literal = null
var parsed = null
var list = null


func __try(log_name, phase, what):
	coop_log.info(log_name, "dicttest %s: %s" % [String(phase), what])


func step(log_name, phase):
	if phase == 0:
		literal = {"t": "pong", "e": "1"}
		__try(log_name, phase, "literal size=[%s]" % [String(literal.size())])
		return 1

	if phase == 1:
		__try(log_name, phase, "literal has=[%s] missing=[%s]" % [
			String(literal.has("t")), String(literal.has("nope"))
		])
		return 2

	if phase == 2:
		__try(log_name, phase, "literal index=[%s]" % [String(literal["t"])])
		return 3

	if phase == 3:
		__try(log_name, phase, "literal keys=[%s]" % [String(literal.keys())])
		return 4

	if phase == 4:
		parsed = {}
		__try(log_name, phase, "parse_json=[%s] size=[%s]" % [
			String(parsed.parse_json(JSON_TEXT)), String(parsed.size())
		])
		return 5

	if phase == 5:
		__try(log_name, phase, "parsed t=[%s] n=[%s] b=[%s]" % [
			String(parsed["t"]), String(int(parsed["n"])), String(bool(parsed["b"]))
		])
		return 6

	if phase == 6:
		var out = parsed.to_json()
		__try(log_name, phase, "to_json=[%s]" % [out])
		return 7

	if phase == 7:
		literal.erase("e")
		__try(log_name, phase, "erase leaves size=[%s]" % [String(literal.size())])
		return 8

	if phase == 8:
		var nested = {}
		nested.parse_json(NESTED_TEXT)
		__try(log_name, phase, "nested b1=[%s] c=[%s]" % [
			String(nested["a"]["b"][1]), String(nested["c"])
		])
		return 9

	if phase == 9:
		list = []
		var total = 0
		for i in range(2000):
			list.push_back(i)
			total += 1
		__try(log_name, phase, "pushed %s, size=[%s]" % [String(total), String(list.size())])
		return 10

	if phase == 10:
		__try(log_name, phase, "array has=[%s] missing=[%s]" % [
			String(list.has(1999)), String(list.has(99999))
		])
		return 11

	if phase == 11:
		list.erase(0)
		__try(log_name, phase, "erase leaves size=[%s]" % [String(list.size())])
		return 12

	if phase == 12:
		var text = "00000023"
		__try(log_name, phase, "string length=[%s] is_valid_integer=[%s]" % [
			String(text.length()), String(text.is_valid_integer())
		])
		return 13

	if phase == 13:
		var text = "abcdefgh"
		__try(log_name, phase, "substr=[%s] find=[%s] begins_with=[%s]" % [
			text.substr(2, 3), String(text.find("c")), String(text.begins_with("ab"))
		])
		return 14

	if phase == 14:
		var body = "{\"t\":\"pong\"}"
		var bytes = (body + "").to_utf8()
		__try(log_name, phase, "to_utf8 size=[%s] back=[%s]" % [
			String(bytes.size()), bytes.get_string_from_utf8()
		])
		return 15

	if phase == 15:
		var typed = typeof(parsed)
		__try(log_name, phase, "typeof(dictionary)=[%s] TYPE_DICTIONARY=[%s]" % [
			String(typed), String(TYPE_DICTIONARY)
		])
		return 16

	return -1
