--------------------------------------------------------------------------------
-- Hyprland — layout.lua (was conf/system/layout.conf)
-- Gaps, borders, tiling layout
--------------------------------------------------------------------------------

hl.config({
	general = {
		gaps_in = 3,
		gaps_out = 6,
		gaps_workspaces = 50,

		border_size = 2, -- thick borders for neon effect
		resize_on_border = true,
		no_focus_fallback = true,
		allow_tearing = false,

		layout = "dwindle",

		col = {
			-- bright gradient: light blue to pink (overridden by colors.lua theme)
			active_border = { colors = { "rgba(62AEEFFF)", "rgba(B542FFFF)" }, angle = 45 },
			inactive_border = "rgba(505050CC)", -- muted gray
		},

		-- snap = { enabled = true },
	},

	-- Group window configuration with neon colors
	group = {
		col = {
			border_active = { colors = { "rgba(62AEEFFF)", "rgba(B542FFFF)" }, angle = 45 },
			border_inactive = "rgba(505050CC)",
			border_locked_active = { colors = { "rgba(62AEEFFF)", "rgba(B542FFFF)" }, angle = 45 },
			border_locked_inactive = "rgba(505050CC)",
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
