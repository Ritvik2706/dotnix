--------------------------------------------------------------------------------
-- Hyprland — execs.lua (was conf/system/execs.conf)
-- Autostart programs & services. hyprland.start fires once at startup,
-- so this is the equivalent of the old exec-once.
--------------------------------------------------------------------------------

hl.on("hyprland.start", function()
	-- ===== Core services =====
	hl.exec_cmd("awww-daemon") -- wallpaper daemon
	hl.exec_cmd("awww img /home/ritvik/github/dotnix/wallpapers/test.png") -- set wallpaper
	hl.exec_cmd("dunst") -- notifications
	hl.exec_cmd("hypridle") -- idle/suspend/lock management
	hl.exec_cmd("copyq") -- clipboard manager
	hl.exec_cmd("xfsettingsd") -- Xfce settings daemon (themes, fonts, etc.)
	-- hl.exec_cmd("systemctl --user start onedrive") -- Uncomment if OneDrive is configured

	-- ===== Desktop UI elements =====
	hl.exec_cmd("sh -c 'rm -f /tmp/waybar-hidden; waybar'") -- status bar (flag cleared so it starts visible & in sync)
	hl.exec_cmd("albert") -- launcher
	hl.exec_cmd("autotiling") -- auto-tiling helper (if installed)

	-- ===== Applications (workspace-pinned via window rules) =====
	hl.exec_cmd("brave") -- → workspace 1
	hl.exec_cmd("ghostty") -- → workspace 2
	-- ChatGPT app (Brave PWA) → workspace 11 lands via the title-based rule

	-- Auto-start wlsunset at login (sunset→sunrise)
	hl.exec_cmd("wlsunset -l 43.6 -L 3.9")

	-- ===== Optional / custom scripts =====
	-- hl.exec_cmd("/home/ritvik/.config/custom_scripts/launch_chatgpt_hypr.sh")
end)
