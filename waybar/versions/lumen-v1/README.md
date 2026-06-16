# Lumen v1 — canonical snapshot

Speculative "Apple ~4 years past Liquid Glass" theme, tuned to the dusk
wallpaper (wallpapers/idk.jpg).

What defines it:
- Chromatic-dispersion edges (twilight violet left / sunset peach right)
- Ambient SPATIAL tint: cool-left workspaces → warm-right stats, mirroring
  the wallpaper's dusk sweep
- True stadium capsules; morphing + breathing focused workspace
- Centered "now-island" layout: workspaces+app left · clock/media center ·
  system+status right. The center island expands to show now-playing when a
  player is active and collapses to just the clock when idle (Dynamic Island
  lineage); it leads the flanks via size/brightness hierarchy.

## Restore this version
From the waybar/ directory:

    cp versions/lumen-v1/config.jsonc versions/lumen-v1/style.css .
    pkill -x waybar; waybar &
