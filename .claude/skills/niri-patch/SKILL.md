---
name: niri-patch
description: The full workflow for changing the patched niri (~/github/projects/niri, branch dotnix-patches) — edit, test nested, commit, export patches to dotnix, install with niri-patched.sh build. Use for ANY change to niri's source (shaders, glass, layout, input).
---

# Change the patched niri

Ritvik built `niri-patched.sh` + `niri-launch.sh` so experiments and Arch
updates never break the session. Follow every step; the dotnix guard hook
blocks hand-installs and direct `.patch` edits anyway.

Repo: `~/github/projects/niri`, branch `dotnix-patches`: one commit per
feature on top of a release tag (`git describe --tags --abbrev=0
dotnix-patches`, currently v26.04).

## 1. Make the change

- Work on `dotnix-patches`. A fix to an existing feature → fold it into that
  feature's commit: `git commit --fixup <sha>`, then
  `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <tag>` (the env var
  makes the rebase non-interactive; plain `-i` can't run here). A new feature
  → a new commit with an `area: what it does` subject like the others.
- Build: `cargo build --release` (add `--locked` to match the installer).

## 2. Test nested, never on the live session

- Run the new build nested (winit) inside the session, with the user's REAL
  blur block from `niri/config.kdl` (passes 2, offset 3, noise 0.015,
  saturation 1.25); defaults hide bugs.
- Only ONE nested niri at a time; read its display (`wayland-N`) from its
  log, don't assume `wayland-2`. A nested niri that's covered throttles frame
  callbacks, so animations jump: judge stills.
- Wallpaper in the nested one: `awww-daemon -n <name>` + `awww img -n <name>`.
- Kill test processes by PID (`pgrep -x` + cmdline check). Never `pkill -f`
  a pattern that matches your own command, never `pkill lumen` or `pkill
  niri` (that's the live session).
- Visual check with grim on the nested output; for perf work the look must be
  pixel-identical (`verify-look` diff, max ≤ 1/255).
- Tests: targeted tests + the normal suite. Slow/stress runs only for big
  layout-logic changes, and offered as optional.

## 3. Commit and export

```sh
cd ~/github/projects/niri
git status          # nothing uncommitted may remain
base=$(git describe --tags --abbrev=0 dotnix-patches)
rm ~/github/config/dotnix/niri/patches/*.patch
git format-patch -q --no-signature -o ~/github/config/dotnix/niri/patches "$base"..dotnix-patches
```

Check the count matches `git log --oneline "$base"..dotnix-patches | wc -l`.

## 4. Install

`~/github/config/dotnix/niri/scripts/niri-patched.sh build`: builds the
committed branch (--locked), runs `check` (ldd, --version, validates the
config), keeps the old binary as `~/.local/bin/niri.prev`, installs, clears
the crash marker. Then `niri-patched.sh check` should print `ok`.

## 5. Tell the user

It takes effect on the next niri restart (their notification offers "Restart
niri now"). Don't restart niri yourself. Mention that `niri-launch.sh` falls
back patched → niri.prev → stock if the new build fails to start.
