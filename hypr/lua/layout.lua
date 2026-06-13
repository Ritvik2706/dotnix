--------------------------------------------------------------------------------
-- Hyprland — layout.lua (was conf/system/layout.conf)
-- Gaps, borders, tiling layout
--------------------------------------------------------------------------------

hl.config({
	general = {
		gaps_in = 2,
		gaps_out = 4,
		gaps_workspaces = 50,

		border_size = 2, -- bright neon edge
		resize_on_border = true,
		no_focus_fallback = true,
		allow_tearing = false,

		layout = "dwindle",

		col = {
			-- Solid neon cyan (mirrors colors.lua theme)
			active_border = { colors = { "rgba(00F0FFFF)" }, angle = 5 },
			inactive_border = "rgba(2A3450CC)", -- muted gunmetal
		},

		-- snap = { enabled = true },
	},

	-- Grouped windows get a cyan -> magenta edge to read distinct from focus
	group = {
		col = {
			border_active = { colors = { "rgba(00F0FFFF)", "rgba(FF2A6DFF)" }, angle = 45 },
			border_inactive = "rgba(2A3450CC)",
			border_locked_active = { colors = { "rgba(FAFF00FF)", "rgba(FF2A6DFF)" }, angle = 45 },
			border_locked_inactive = "rgba(2A3450CC)",
		},
	},

	dwindle = {
		preserve_split = true,
		smart_split = false,
		smart_resizing = false,
		-- pseudotile option was removed; the pseudo dispatcher still works
		-- precise_mouse_move = true,
	},

	master = {
		new_status = "master",
	},
})
