# Publishing checklist

For whoever pushes this to git. Every step is a command with an expected result, not an instruction
to eyeball something.

The rule this file exists to enforce: **`local/` and `build/out/` are never committed.** The first is a
decompressed copy of the game; the second is a 400 MB copy of the game with the mod injected. Neither
belongs in a repository, and the second would make every clone 400 MB.

---

## 1. Confirm the working tree is what you think it is

```bash
git status --porcelain            # expect: the files below, and NO path starting with local/ or build/out
git check-ignore -v local/x       # expect: a .gitignore rule matches
git check-ignore -v build/out/x   # expect: a .gitignore rule matches
```

If `local/` or `build/out/` appears in `git status`, **stop**. `.gitignore` covers both at the bundle
root and here, but a nested repository or a `-f` flag can override both.

## 2. Check for secrets and identity leaks

```bash
# A real user's name in a path is the one thing that must not ship. The pattern is assembled so this
# file does not match itself.
PAT="$(printf 'im%s' 'dea')"
grep -rIn --exclude-dir=__pycache__ --exclude=PUBLISHING.md \
     -e "$PAT" -e 'C:\\Users\\' -e 'B:\\Steam' . || echo "clean"
```

Expected: `clean`. The docs use `<game dir>` and `%APPDATA%` on purpose. If a real path appears, replace
it with the placeholder — the *fact* is usually worth keeping, the identity is not.

```bash
grep -rn --include=*.json --include=*.ini -e "password" -e "token" -e "api_key" . || echo "no secrets"
```

## 3. Confirm no game data is present

```bash
find . -iname "*.pck" -o -iname "*.gde" -o -iname "*.gdc" -o -iname "*.save" | head
```

Expected: nothing. References to `data.pck` inside markdown are fine; an actual pack is not.

```bash
du -sh .          # expect a few MB, NOT hundreds
```

If this says 400 MB, someone copied `build/out`. Remove it.

## 4. Run every test

```bash
python -I run_all_tests.py
```

Expected: three suites, then `ALL OK`. **This must be green on a machine with no game installed** —
that is the whole point of the game-free suites, and a fresh clone is the real test.

## 5. Check the documentation links

```bash
python - <<'PY'
import glob, os, re
bad = 0
for p in glob.glob('docs/*.md') + ['README.md']:
    for m in re.finditer(r'\]\(([^)]+)\)', open(p, encoding='utf-8').read()):
        t = m.group(1)
        if t.startswith(('http', '#', 'mailto')):
            continue
        if not os.path.exists(os.path.normpath(os.path.join(os.path.dirname(p), t.split('#')[0]))):
            print('%-40s -> %s' % (p, t)); bad += 1
print('broken links:', bad)
PY
```

Expected: `broken links: 0`.

## 6. What goes in the commit

```
City Game Studio Multiplayer/
  README.md                      where it stands, the layout, the traps
  LICENSE                        MIT
  .gitignore                     local/, build output, logs, stores
  run_all_tests.py               one command, three suites
  docs/                          the write-ups + NOTES.md
  build/build_mod.py             the build pipeline (three static checks)
  mod/coop/                      the mod
  mod/scripts/                   the two game scripts it replaces or adds
  server/                        the relay, its 12 tests, a fake client
  tools/run-coop.ps1             relay + host + client in one command
  tools/send.ps1                 one remote command
  tools/capture-window-print.ps1 screenshot without stealing focus
  tools/godotpck/                vendored pack tool (the build depends on it)
```

Deliberately **not** included: `local/`, `build/out/`, `__pycache__`, the hub's own `tools/test_all.py`
wiring, the extracted game scripts, the patched pack, the key.

## 7. After pushing

- The commit is under the owner's GitHub account. Show them the diff first.
- Add the repository to the hub's `data/directory.yaml` and run `python tools/build_directory.py`.
- If the mod is unfinished (it is), set `up_for_adoption` honestly and say in the README what works,
  what is broken and how to build it.

---

## Known honest gaps (say these in the description, do not paper over them)

| Gap | Status |
|---|---|
| Release from the UI is unconfirmed | the press fires and spends money; `published` becoming 1 has not been watched |
| Nobody has looked at the publish-offer list, console panel or map | model values are asserted; the panels are not |
| Per-player progression over a year is unmeasured | `game-engine`, `game-type`, `capacity`, `game-of-the-year`, `game-combos` are isolated, not observed |
| Three or more players | the protocol allows it; only two have run |
| No installer | two commands and a game copy are required |
| Split screen | not attempted |
| An intermittent join stall | ~1 run in 12, undiagnosed |
