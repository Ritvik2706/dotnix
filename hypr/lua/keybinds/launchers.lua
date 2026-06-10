--------------------------------------------------------------------------------
-- Hyprland — keybinds/launchers.lua (application launchers and utilities)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- ===== App Launchers =====
hl.bind(main .. " + G", hl.dsp.exec_cmd("zen-browser"))
hl.bind(main .. " + Y", hl.dsp.exec_cmd("thunar"))
hl.bind(main .. " + C", hl.dsp.exec_cmd("copyq show"))

-- Handy pickers (safe fallbacks if missing)
hl.bind(
	main .. " + P",
	hl.dsp.exec_cmd(
		[[sh -lc 'command -v hyprpicker >/dev/null && hyprpicker -a || notify-send "Hyprpicker not installed"']]
	)
)
hl.bind(
	main .. " + E",
	hl.dsp.exec_cmd(
		[[sh -lc 'command -v wofi-emoji >/dev/null && wofi-emoji --action copy || notify-send "Emoji picker not installed"']]
	)
)

-- Optional TUI helpers (uncomment if you use them)
-- hl.bind(main .. " + N", hl.dsp.exec_cmd("kitty -e nmtui"))
-- hl.bind(main .. " + B", hl.dsp.exec_cmd([[sh -lc "command -v bluetuith >/dev/null && kitty -e bluetuith || notify-send 'bluetuith not installed'"]]))

-- ===== sesh / project picker submap =====
hl.bind(main .. " + D", hl.dsp.submap("proj"))

hl.define_submap("proj", function()
	local function pick(key, cmd)
		hl.bind(key, function()
			hl.dispatch(hl.dsp.submap("reset"))
			hl.exec_cmd(cmd)
		end)
	end

	-- Smart picker - tmux popup if client exists, otherwise new terminal
	pick("N", "~/.config/custom_scripts/sesh-picker.sh")

	-- Direct jumps - uses tmux run-shell to switch sessions directly
	pick("D", "tmux run-shell 'sesh connect dotfiles'")
	pick("W", "tmux run-shell 'sesh connect web'")
	pick("S", "tmux run-shell 'sesh connect systeme'")
	pick("O", "tmux run-shell 'sesh connect objet'")

	-- Switch to last sesh workspace
	pick("L", "tmux run-shell 'sesh last'")

	-- Manual immerse mode trigger (for testing)
	pick("I", "/home/ritvik/github/config/nixfiles/hypr/scripts/immerse_mode.sh")

	-- Cancel keys (leave submap with no action)
	hl.bind("ESCAPE", hl.dsp.submap("reset"))
	hl.bind("BACKSPACE", hl.dsp.submap("reset"))
end)
