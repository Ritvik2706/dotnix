---
name: lumen-engine
description: Changing the lumen engine itself (~/github/projects/lumen, Rust) — renderer, language/compiler, glass, wayland platform. Covers building WITHOUT restarting the live island, testing, the pixel-identical perf rule, committing, and the fork's licence. Not for island .plm/.luau edits (that's island-page + lumen).
---

# Change the lumen engine

lumen is Ritvik's own project: a renamed fork of pleamar 0.4.12 (BSD-3). Treat
it as theirs, not pleamar's.

## The trap: release builds restart the live island

`~/.local/bin/lumen` → `~/github/projects/lumen/target/release/lumen`, and a
running lumen relaunches itself whenever its binary changes
(`src/scenes/from_file.rs`, `watch_binary`). So **`cargo build --release` in
the repo restarts the user's island immediately**, with whatever you built.

- Experiments: build into another folder and run that binary:
  `cargo build --release --offline --target-dir target/exp`, then
  `target/exp/release/lumen --scene … `.
- Only build the real `target/release` when the change is tested and the user
  wants it live. Say that it will restart the island.
- `LUMEN_NO_RELAUNCH=1` stops a process from relaunching itself (useful for a
  test lumen you keep running).

## Build and test

- `cargo build --release --offline` (deps are already in the cargo cache;
  offline keeps builds from touching the network).
- Targeted `cargo test --offline <name>` + the normal suite; stress runs only
  for big changes, offered as optional.
- Scene-level: `lumen --check FILE` (scene only), `--grammar` (vocabulary),
  `--scene FILE --screen NO-SUCH-SCREEN --seconds 3 --no-hud` (runs the
  logic, draws nothing). A language change must also update what `--grammar`
  reports and the docs (`docs/`, `--docs`), and the skill (`skill/SKILL.md`,
  installed by `lumen --install-skill`) if agents need to know.
- Visual test: a small scene in the scratchpad, run with the experimental
  binary; for glass, inside a nested niri with the user's real blur block (see
  `niri-patch`). Glass is drawn by niri via the lumen-glass-v1 protocol, so a
  glass change may need both sides.
- Test lumens: kill by PID only (`pgrep -x lumen` + cmdline). Never
  `pkill lumen` or `pkill -f` a pattern in your own command line.

## Rules

- **Performance work must be pixel-identical** to the current look (diff
  ≤ 1/255, `verify-look` diff), measured before/after. Keep
  `glass-performance` notes in memory current.
- **Licence**: keep `LICENSE`'s "Copyright (c) 2026, Abel" line (BSD-3
  requires it) next to Ritvik's; `NOTICE` explains the origin. Don't remove
  either.
- `upstream` remote = pleamar, for cherry-picking fixes; nothing is pushed
  anywhere (local only, the user's choice).
- Commit focused changes with a `area: what it does` subject (like
  `lens: …`); don't leave engine work uncommitted. Commit only when asked.
- After the real build goes live, check the island with `verify-look` on
  every monitor.
