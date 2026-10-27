--------------------------------------------------------------------------------
-- Hyprland — keybinds/launchers.lua (application launchers and utilities)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- ===== App Launchers =====
hl.bind(main .. " + G", hl.dsp.exec_cmd("zen-browser"))
hl.bind(main .. " + R", hl.dsp.exec_cmd("thunar")) -- (was Super+Y: that is the island's finder now)

-- Handy pickers (safe fallbacks if missing)
hl.bind(main .. " + P", hl.dsp.exec_cmd('~/.local/bin/lumen --say island "emit wall_open"')) -- the island's wallpaper picker (was: hyprpicker)
hl.bind(main .. " + Y", hl.dsp.exec_cmd('~/.local/bin/lumen --say island "emit find_open"')) -- the island's file finder (frecency, previews, vim keys)
hl.bind(main .. " + SHIFT + P", hl.dsp.exec_cmd('~/.local/bin/lumen --say island "emit pick_color"')) -- the island's colour picker: hyprpicker, its answer shown in the pill
hl.bind(main .. " + E", hl.dsp.exec_cmd('~/.local/bin/lumen --say island "emit emoji_open"')) -- the island's emoji picker (was: vicinae)
hl.bind(main .. " + U", hl.dsp.exec_cmd('~/.local/bin/lumen --say island "emit mail_big"')) -- the island's large mail view (was: centre the window, now Super+Ctrl+U)
hl.bind(main .. " + W", hl.dsp.exec_cmd('~/.local/bin/lumen --say island "emit wa_big"')) -- the island's WhatsApp (was: the special workspace, now Super+X)

-- Optional TUI helpers (uncomment if you use them)
-- hl.bind(main .. " + N", hl.dsp.exec_cmd("kitty -e nmtui"))
-- hl.bind(main .. " + B", hl.dsp.exec_cmd([[sh -lc "command -v bluetuith >/dev/null && kitty -e bluetuith || notify-send 'bluetuith not installed'"]]))

-- ===== App launcher (wofi) =====
hl.bind(main .. " + D", hl.dsp.exec_cmd(vars.menu))

-- ===== tmux session prefix (Super+A, then a key) =====
-- Jumps to the terminal workspace and switches the tmux client to a session
hl.bind(main .. " + A", hl.dsp.submap("tmuxsesh"))

hl.define_submap("tmuxsesh", function()
	local function jump(key, session)
		hl.bind(key, function()
			hl.dispatch(hl.dsp.submap("reset"))
			hl.dispatch(hl.dsp.focus({ workspace = 2 }))
			hl.exec_cmd("tmux run-shell 'sesh connect " .. session .. "'")
		end)
	end

	jump("D", "dotfiles")
	jump("P", "~/github/projects")
	jump("U", "~/github/uni")
	jump("V", "~/github/vault")

	hl.bind("ESCAPE", hl.dsp.submap("reset"))
	hl.bind("BACKSPACE", hl.dsp.submap("reset"))
end)

-- ===== Alt+Tab: the island's window switcher =====
-- Alt+Tab opens it on the window used before this one (Shift goes back);
-- while Alt stays down, each Tab steps; letting go of Alt goes there.
-- The submap only exists while switching, so Alt's release costs nothing
-- the rest of the time. Esc gives up.
local ISLAND = [[~/.local/bin/lumen --say island "emit %s" >/dev/null 2>&1]]
local function switch(step)
	return function()
		hl.exec_cmd(string.format(ISLAND, "win_open " .. step))
		hl.dispatch(hl.dsp.submap("switcher"))
	end
end
hl.bind("ALT + TAB", switch(1))
hl.bind("ALT + SHIFT + TAB", switch(-1))

hl.define_submap("switcher", function()
	hl.bind("ALT + TAB", hl.dsp.exec_cmd(string.format(ISLAND, "win_open 1")))
	hl.bind("ALT + SHIFT + TAB", hl.dsp.exec_cmd(string.format(ISLAND, "win_open -1")))
	hl.bind("Alt_L", function()
		hl.exec_cmd(string.format(ISLAND, "win_commit"))
		hl.dispatch(hl.dsp.submap("reset"))
	end, { ignore_mods = true, release = true })
	hl.bind("ESCAPE", function()
		hl.exec_cmd(string.format(ISLAND, "win_cancel"))
		hl.dispatch(hl.dsp.submap("reset"))
	end, { ignore_mods = true })
end)
