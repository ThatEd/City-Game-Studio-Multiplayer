#!/usr/bin/env python3
"""Every test this project has that does not need the game running.

    python -I run_all_tests.py

Three suites, no install, no network, a few seconds:

  server/run_tests.py          the relay: framing, delivery, storage, disconnects
  tools/godotpck/run_tests.py  reading, extracting and patching Godot packs
  build (import-only)          the build pipeline's static checks over the mod source

The third one is not a separate file: `build_mod.py` refuses to ship a mod whose scripts the engine
would not compile, and those checks (`check_gdscript`, `check_missing_classes`,
`check_native_killers`) run on the source alone. This runner calls them directly so a compile error in
the mod is caught here rather than after a 400 MB build.

What this cannot tell you is whether two copies of the game actually sync. That needs a real host and a
real client; `python -I server/run_tests.py` is the part that can be proven without one, and
`tools/run-coop.ps1` is how the other part is exercised. See docs/QA.md.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
PYTHON = sys.executable or "python"


def say(text=""):
    print(text, flush=True)


def run(title, args, expect="ALL OK"):
    say("=" * 78)
    say(title)
    say("=" * 78)
    sys.stdout.flush()
    result = subprocess.run(args, cwd=str(ROOT))
    if result.returncode != 0:
        say("\nFAILED: %s (exit %d)" % (title, result.returncode))
        return False
    return True


def check_mod_compiles():
    """The build pipeline's static checks over the mod source, without building a pack."""
    say("=" * 78)
    say("mod source: the engine's own compile rules")
    say("=" * 78)
    sys.path.insert(0, str(ROOT / "build"))
    try:
        import build_mod
    except SystemExit as exc:                     # the pack tool is missing
        say("SKIP  %s" % exc)
        return True

    files = build_mod.collect_mod_files()
    problems = []
    problems.extend(build_mod.check_missing_classes(files))
    problems.extend(build_mod.check_native_killers(files))
    problems.extend(build_mod.check_gdscript(files))
    if problems:
        for problem in problems:
            say("FAIL  %s" % problem)
        say("\nFAILED: %d problem(s) in the mod source" % len(problems))
        return False
    say("ok    %d mod file(s), no compile error, no missing class, no known process killer"
        % len(files))
    return True


def main():
    ok = True
    ok &= run("relay", [PYTHON, "-I", "server/run_tests.py"])
    ok &= run("godot pack tool", [PYTHON, "-I", "tools/godotpck/run_tests.py"])
    ok &= check_mod_compiles()
    say()
    if ok:
        say("ALL OK")
        return 0
    say("FAILED")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
