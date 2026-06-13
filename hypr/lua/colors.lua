--------------------------------------------------------------------------------
-- Hyprland — colors.lua (was conf/themes/colors.conf)
-- Palette + theming-only settings (borders, shadow, opacities, dim)
--------------------------------------------------------------------------------

local c = require("lua.vars").colors

-- === Opacity / dim (theme constants) ===
--local active_opacity = 0.94 -- subtle glass on focused windows (terminal opted out via rule)
local inactive_opacity = 0.60 -- a touch more transparency for inactive windows
local dim_strength_val = 0.0 -- no dimming
local dim_special_val = 0.0 -- no dimming for special windows

hl.config({
	general = {
		col = {
			-- Razer green sweeping into neon cyan — the cyberpunk hero gradient
			active_border = { colors = { c.cyan }, angle = 5 },
			inactive_border = c.off,
		},
	},

	decoration = {
		active_opacity = active_opacity,
		inactive_opacity = inactive_opacity,

		shadow = {
			color = "rgba(44D62C66)", -- faint Razer-green glow around the focused window
			color_inactive = "rgba(07080E44)", -- soft dark drop for inactive windows
		},

		dim_inactive = false, -- disabled dimming
		dim_strength = dim_strength_val,
		dim_special = dim_special_val,
	},
})
