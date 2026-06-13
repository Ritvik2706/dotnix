#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
APP_ID="chrome-claude.ai__-Default"        # Wayland app_id for a Chromium --app PWA
APP_URL="https://claude.ai/"
CHROMIUM_BIN="${CHROMIUM_BIN:-chromium}"    # ungoogled-chromium-bin installs /usr/bin/chromium

# How big you want the window
WIN_W=1100
WIN_H=650

# --- Requirements check ---
command -v hyprctl >/dev/null 2>&1 || { echo "hyprctl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found"; exit 1; }

# --- Runtime rules so the app behaves as desired when it appears ---
# float + center + size + move to special workspace
hyprctl keyword windowrulev2 "float, initialclass:^${APP_ID}$"                  >/dev/null
hyprctl keyword windowrulev2 "center, initialclass:^${APP_ID}$"                 >/dev/null
hyprctl keyword windowrulev2 "size ${WIN_W} ${WIN_H}, initialclass:^${APP_ID}$" >/dev/null
hyprctl keyword windowrulev2 "workspace special, initialclass:^${APP_ID}$"      >/dev/null

# Per-window opacity (active, inactive)
hyprctl keyword opacityrule "0.80 0.80, initialclass:^${APP_ID}$"               >/dev/null

# --- Launch the Chromium web app window ---
hyprctl dispatch exec \
  "$CHROMIUM_BIN --ozone-platform-hint=auto --enable-features=UseOzonePlatform --app=${APP_URL}" >/dev/null

# --- Helper: find the window address we care about ---
find_addr() {
  hyprctl -j clients | jq -r --arg APP "$APP_ID" '
    map(select((.initialClass == $APP)
        or ((.class|ascii_downcase|test("chromium|chrome"))
            and (.title|test("Claude"; "i"))))) |
    (.[0].address // empty)'
}

# --- Wait until the window shows up ---
ADDR=""
for _ in {1..20}; do
  ADDR="$(find_addr || true)"
  if [[ -n "$ADDR" ]]; then
    break
  fi
  sleep 0.5
done

# --- If we found it, bring it up; otherwise, bail gracefully ---
if [[ -z "$ADDR" ]]; then
  echo "Could not find the Claude Chromium window."
  exit 1
fi

# Focus it (by address) and show the special workspace
hyprctl dispatch focuswindow "address:${ADDR}"                              >/dev/null
hyprctl dispatch resizewindowpixel "exact ${WIN_W} ${WIN_H},address:${ADDR}" >/dev/null
hyprctl dispatch centerwindow "address:${ADDR}"                            >/dev/null

# Show the special workspace (Hyprland's scratchpad)
hyprctl dispatch togglespecialworkspace                                    >/dev/null
