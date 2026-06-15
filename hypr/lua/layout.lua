--------------------------------------------------------------------------------
-- Hyprland — layout.lua (was conf/system/layout.conf)
-- Gaps, borders, tiling layout
--------------------------------------------------------------------------------

hl.config({
	general = {
		gaps_in = 2,
		gaps_out = 4,
		gaps_workspaces = 50,

		border_size = 2, -- thin glass rim
		resize_on_border = true,
		no_focus_fallback = true,
		allow_tearing = false,

		layout = "dwindle",

		col = {
			-- Liquid-glass rim (mirrors colors.lua) — soft lilac → white
			active_border = { colors = { "rgba(C9B6FFFF)", "rgba(FFFFFFCC)" }, angle = 120 },
			inactive_border = "rgba(FFFFFF1F)",
		},

		-- snap = { enabled = true },
	},

	-- Grouped windows: a brighter sky-tinted glass rim to read as focused.
	group = {
		col = {
			border_active = { colors = { "rgba(C9B6FFFF)", "rgba(FFFFFFCC)" }, angle = 120 },
			border_inactive = "rgba(FFFFFF1F)",
			border_locked_active = { colors = { "rgba(FFFFFFE6)", "rgba(C9B6FFCC)" }, angle = 120 },
			border_locked_inactive = "rgba(FFFFFF1F)",
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
