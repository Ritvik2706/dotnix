--------------------------------------------------------------------------------
-- Hyprland — execs.lua (was conf/system/execs.conf)
-- Autostart programs & services. hyprland.start fires once at startup,
-- so this is the equivalent of the old exec-once.
--------------------------------------------------------------------------------

hl.on("hyprland.start", function()
	-- ===== LOCK FIRST =====
	-- The session autologins, so it is unauthenticated until hyprlock covers
	-- it. systemd already starts hyprlock.service via graphical-session.target;
	-- this is a SECOND, independent trigger on the compositor's own startup
	-- hook, because the cost of the two disagreeing is a bare desktop on a
	-- machine nobody logged into. `systemctl start` is idempotent — if the
	-- unit is already running this is a no-op — so the belt and the braces
	-- cannot fight each other.
	hl.exec_cmd("systemctl --user start hyprlock.service") -- cover the session

	-- The panel is ALREADY DARK at this point — hyprlock-blank.service took the
	-- backlight to zero back at graphical-session-pre.target, before Hyprland
	-- could draw a frame. That is what hides the autologin gap: Hyprland is
	-- compositing a real, unauthenticated desktop from its first frame until
	-- the line above finishes locking, roughly 400ms later, and without the
	-- blackout you watch it.
	--
	-- This brings the light back, and only once `hyprctl locked` says the
	-- session is genuinely covered. It is bounded and trap-guarded: if hyprlock
	-- never comes up the light returns anyway, because a visible unlocked
	-- desktop is a problem you can see and act on, while a black panel is
	-- indistinguishable from a dead machine.
	hl.exec_cmd("~/.config/hypr/scripts/boot-unblank.sh") -- ...then reveal it

	-- ===== Core services =====
	hl.exec_cmd("awww-daemon") -- wallpaper daemon
	hl.exec_cmd("awww img /home/ritvik/github/config/dotnix/wallpapers/idk.png") -- set wallpaper
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
