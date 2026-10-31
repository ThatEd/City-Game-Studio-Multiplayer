#!/usr/bin/env python3
"""Do the build's compile guards still catch what they claim to?

    python -I build_run_tests.py

A guard that cannot fail is worse than no guard: it makes the build look safe while the thing it was
written for walks straight through. Every case below is a construct that genuinely broke this mod at
least once, or that this engine build genuinely cannot parse. Each must be CAUGHT.

The last case is the other direction. A guard that rejects ordinary Godot 2 code is noise, and noise
gets switched off, so clean code must pass.

Why the `is` operator is in here
--------------------------------
`if child is Button:` took out all of `lobby.gd` with "Parse Error: ':' expected at end of line". The
mod's boot-time compile probe is what made it visible at all; the build had said the pack was fine,
because a script that fails to compile is not a build failure. So the build now refuses it too.
"""
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import build_mod

# (name, source, why it matters)
MUST_CATCH = [
    (
        "is operator",
        b"static func f(node):\n\tif node is Button:\n\t\treturn true\n\treturn false\n",
        "parse error in this build; it silently disabled all of lobby.gd",
    ),
    (
        "get_node_or_null",
        b"func f():\n\tvar n = get_node_or_null(\"/root/x\")\n\treturn n\n",
        "absent; calling it is a runtime error",
    ),
    (
        "get_node_or_null with receiver",
        b"func f():\n\tvar n = self.get_node_or_null(\"/root/x\")\n\treturn n\n",
        "same, written the other way round",
    ),
    (
        "sort_custom",
        b"func f(items):\n\titems.sort_custom(null, \"compare\")\n\treturn items\n",
        "absent from this build's GDScript",
    ),
    (
        "can_instance",
        b"func f(script):\n\treturn script.can_instance()\n",
        "absent; probing for it crashed a boot",
    ),
    (
        "String.join",
        b"func f(parts):\n\treturn \",\".join(parts)\n",
        "absent; it is a Godot 3+ method",
    ),
    (
        "await",
        b"func f():\n\tawait g()\n",
        "Godot 2 has no coroutines by that name",
    ),
    (
        "class_name",
        b"class_name Foo\nextends Node\n",
        "Godot 2 declares nothing that way",
    ),
    (
        "typed variable",
        b"var count: int = 3\n",
        "Godot 2 has no type annotations",
    ),
    (
        "typed return",
        b"func f() -> int:\n\treturn 1\n",
        "Godot 2 has no return annotations",
    ),
    (
        "missing engine class",
        b"func f():\n\tvar server = TCPServer.new()\n\treturn server\n",
        "naming a class this build lacks is a compile error",
    ),
    (
        "function with no body",
        b"func __panel():\n\n\nfunc other():\n\treturn 1\n",
        "a bare signature stops the whole file loading; this cost two launches",
    ),
    (
        "match statement",
        b"func f(v):\n\tmatch typeof(v):\n\t\tTYPE_BOOL:\n\t\t\treturn v\n\treturn false\n",
        "Godot 2.1 has no match; the parse error silently kept dict.gd's previous version",
    ),
    (
        "emitting a game model signal",
        b'func f(date_model):\n\tdate_model.emit_signal("month")\n',
        "runs all 23 listeners of that model signal; it crashed a run inside a clock correction",
    ),
    (
        "function defined twice",
        b"func f():\n\treturn 1\n\nfunc f():\n\treturn 2\n",
        "a duplicate definition stops the whole file loading",
    ),
    (
        "a date rewind with no overshoot discard",
        b"func __pull_date_back(date_model, to_date):\n"
        b"\tdate_model.set_raw_date(to_date)\n",
        "the stale boundary signals and the overshot _tick replay a month cycle; this was the "
        "0xae5633 client crash",
    ),
]

# Must NOT be flagged. If this fails, the guard is rejecting ordinary Godot 2 and will be ignored.
MUST_PASS = [
    (
        "plain Godot 2",
        b'extends Reference\n\n'
        b'static func text_of(node):\n'
        b'\tif node != null and node.has_method("get_text"):\n'
        b'\t\treturn String(node.get_text())\n'
        b'\treturn ""\n',
    ),
    (
        "yield and signals",
        b'func f():\n\tyield(get_tree(), "idle_frame")\n\temit_signal("done")\n',
    ),
    (
        "a word that merely starts like a keyword",
        b'var classification = "is"\nvar awaitable = true\n',
    ),
    (
        "a date rewind that does discard",
        b"func __discard_overshoot(date_model):\n"
        b"\tdate_model.set(\"_tick\", 0.0)\n\n"
        b"func __pull_date_back(date_model, to_date):\n"
        b"\tdate_model.set_raw_date(to_date)\n"
        b"\t__discard_overshoot(date_model)\n",
    ),
]


# The dead-function guard is a different check with its own two directions, so it is proven separately
# rather than mixed into the compile-guard lists above: it must catch a function nothing calls, and it
# must leave alone a function called through a receiver (`__link.debug_line()`), through `call()`, and
# one that is genuinely never referenced but deliberately allowed.
# The native-killer guard has its own list because it is checked by check_native_killers(), not by the
# compile guards. Both directions matter: a cast this build cannot parse must be caught, and legitimate
# uses of the same words must not be.
NATIVE_MUST_CATCH = [
    (
        "an `as` cast, which does not parse here",
        b"func f(list):\n"
        b"\tvar size = (list as Array).size()\n"
        b"\treturn size\n",
        "a parse error leaves the previous version of the script running, so the mod looks healthy "
        "while the edit is ignored",
    ),
    (
        "dictionary get(), which kills this build",
        b"func f(data):\n"
        b"\treturn data.get(\"key\")\n",
        "Dictionary.get() dereferences null at 0xae5633",
    ),
]


NATIVE_MUST_PASS = [
    (
        "a string containing 'as'",
        b"func f(catalog):\n"
        b"\tvar names = []\n"
        b"\tnames.push_back(\"was as if\")\n"
        b"\treturn names\n",
    ),
    (
        "a comparison that spells 'as' inside a word",
        b"func f(value):\n"
        b"\tvar has_copy = value\n"
        b"\treturn has_copy\n",
    ),
]


DEAD_MUST_CATCH = [
    (
        "a function nothing calls",
        b"func __keep_lobby_on_top():\n"
        b"\treturn true\n\n"
        b"func __run(delta):\n"
        b"\treturn delta\n",
        "the documented lobby fix that was written and never wired into _process",
    ),
]

DEAD_MUST_PASS = [
    (
        "called through a receiver",
        b"var __link = null\n\n"
        b"func _process(delta):\n"
        b"\treturn __link.debug_line()\n",
    ),
    (
        "called through call() by name",
        b"func _process(delta):\n"
        b"\treturn self.call(\"menu_host_pressed\")\n\n"
        b"func menu_host_pressed():\n"
        b"\treturn true\n",
    ),
    (
        "an engine callback with no caller",
        b"func _ready():\n"
        b"\treturn true\n",
    ),
]


def main():
    passed = 0
    failed = []
    print("guards that must catch their mistake")
    for name, body, why in MUST_CATCH:
        problems = build_mod.check_missing_classes({"res://coop/probe.gd": body})
        if problems:
            passed += 1
            print("  ok    %-32s %s" % (name, problems[0].split(": ", 1)[1][:64]))
        else:
            failed.append(name)
            print("  FAIL  %-32s NOT CAUGHT - %s" % (name, why))

    print()
    print("code the guards must leave alone")
    for name, body in MUST_PASS:
        problems = build_mod.check_missing_classes({"res://coop/probe.gd": body})
        if problems:
            failed.append(name)
            print("  FAIL  %-32s false positive: %s" % (name, problems[0]))
        else:
            passed += 1
            print("  ok    %-32s passes" % name)

    total = len(MUST_CATCH) + len(MUST_PASS)
    print()
    print("the native-killer guard")
    for name, body, why in NATIVE_MUST_CATCH:
        problems = build_mod.check_native_killers({"res://coop/probe.gd": body})
        if problems:
            passed += 1
            print("  ok    %-32s %s" % (name, problems[0].split(": ", 1)[1][:64]))
        else:
            failed.append(name)
            print("  FAIL  %-32s NOT CAUGHT - %s" % (name, why))
    for name, body in NATIVE_MUST_PASS:
        problems = build_mod.check_native_killers({"res://coop/probe.gd": body})
        if problems:
            failed.append(name)
            print("  FAIL  %-32s false positive: %s" % (name, problems[0]))
        else:
            passed += 1
            print("  ok    %-32s passes" % name)
    total += len(NATIVE_MUST_CATCH) + len(NATIVE_MUST_PASS)
    print()
    print("the dead-function guard")
    for name, body, why in DEAD_MUST_CATCH:
        problems = build_mod.check_dead_functions({"res://coop/probe.gd": body})
        if problems:
            passed += 1
            print("  ok    %-32s %s" % (name, problems[0].split(": ", 1)[1][:64]))
        else:
            failed.append(name)
            print("  FAIL  %-32s NOT CAUGHT - %s" % (name, why))
    for name, body in DEAD_MUST_PASS:
        problems = build_mod.check_dead_functions({"res://coop/probe.gd": body})
        if problems:
            failed.append(name)
            print("  FAIL  %-32s false positive: %s" % (name, problems[0]))
        else:
            passed += 1
            print("  ok    %-32s passes" % name)
    total = (len(MUST_CATCH) + len(MUST_PASS) + len(DEAD_MUST_CATCH) + len(DEAD_MUST_PASS)
             + len(NATIVE_MUST_CATCH) + len(NATIVE_MUST_PASS))
    print()
    print("%d/%d passed" % (passed, total))
    if failed:
        print("failed: " + ", ".join(failed))
        return 1
    print("ALL OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
