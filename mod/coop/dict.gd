extends Reference

# Safe field access for decoded messages.
#
# Dictionary.get() does not work in this engine build. Both Dictionary.get(key) and
# Dictionary.get(key, default) kill the process with an access violation inside
# _VariantCall::FuncData::call (core\variant_call.cpp): the member name is missing from the build's
# per-type table of Variant methods, and the miss is dereferenced instead of being reported as
# CALL_ERROR_INVALID_METHOD. has() and [] are both fine, and size(), keys() and parse_json() are
# fine as well, so every read of a received message goes through these helpers.
#
# The same audit applies to any other Variant member added later: probe it with --coop-dicttest
# before trusting it on the receive path.


static func field(source, key, fallback):
	if source != null and source.has(key):
		return source[key]
	return fallback


static func text(source, key, fallback):
	var value = field(source, key, null)
	if value == null:
		return fallback
	return String(value)


static func number(source, key, fallback):
	var value = field(source, key, null)
	if value == null:
		return fallback
	return int(value)


static func flag(source, key, fallback):
	var value = field(source, key, null)
	if value == null:
		return fallback
	return bool(value)
