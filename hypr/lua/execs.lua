--------------------------------------------------------------------------------
-- Hyprland — execs.lua (was conf/system/execs.conf)
-- Autostart programs & services. hyprland.start fires once at startup,
-- so this is the equivalent of the old exec-once.
--------------------------------------------------------------------------------

hl.on("hyprland.start", function()
	-- ===== Core services =====
	hl.exec_cmd("awww-daemon") -- wallpaper daemon
	hl.exec_cmd("awww img /home/ritvik/github/dotnix/wallpapers/samurai.png") -- set wallpaper
	hl.exec_cmd("dunst") -- notifications
	hl.exec_cmd("hypridle") -- idle/suspend/lock management
	hl.exec_cmd("copyq") -- clipboard manager
	hl.exec_cmd("xfsettingsd") -- Xfce settings daemon (themes, fonts, etc.)
	-- LUMEN GTK theme: GTK on Wayland reads these dconf values in preference to
	-- gtk-3.0/settings.ini, so enforce the dark base + prefer-dark here. The
	-- glass restyle itself lives in ~/.config/gtk-{3,4}.0/gtk.css.
	hl.exec_cmd("gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'")
	hl.exec_cmd("gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'")
	-- hl.exec_cmd("systemctl --user start onedrive") -- Uncomment if OneDrive is configured

	-- ===== Desktop UI elements =====
	hl.exec_cmd("sh -c 'rm -f /tmp/waybar-hidden; waybar'") -- status bar (flag cleared so it starts visible & in sync)
	hl.exec_cmd("albert") -- launcher
	hl.exec_cmd("autotiling") -- auto-tiling helper (if installed)

	-- ===== Applications (workspace-pinned via window rules) =====
	hl.exec_cmd("ghostty") -- → workspace 2
	-- Claude app (Chromium PWA) → workspace 11; launched on demand via super+S (toggle_claude.sh)

	-- Auto-start wlsunset at login (sunset→sunrise)
	hl.exec_cmd("wlsunset -l 43.6 -L 3.9")

	-- Razer keyboard lighting (layered software effects via OpenRazer).
	-- Replaces Polychromatic autostart. Needs the 'input' group (live after
	-- relogin) to read keypresses for the reactive layer. Auto-pauses to ~0 CPU
	-- on lid-close/screen-off; hypridle signals it by PID (see hypridle.conf).
	hl.exec_cmd("/home/ritvik/github/config/dotnix/razer/razer-fx.py aurora reactive starlight:BFEFFF")

	-- ===== Optional / custom scripts =====
	-- hl.exec_cmd("/home/ritvik/.config/custom_scripts/launch_claude_hypr.sh")
end)
