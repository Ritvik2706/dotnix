--------------------------------------------------------------------------------
-- Hyprland — colors.lua (was conf/themes/colors.conf)
-- Palette + theming-only settings (borders, shadow, opacities, dim)
--------------------------------------------------------------------------------

local c = require("lua.vars").colors

-- === Opacity / dim (theme constants) ===
local active_opacity = 1.0
local inactive_opacity = 0.85 -- slight transparency for inactive windows
local dim_strength_val = 0.0 -- no dimming
local dim_special_val = 0.0 -- no dimming for special windows

hl.config({
	general = {
		col = {
			active_border = { colors = { c.light_blue, c.pink }, angle = 45 },
			inactive_border = c.dark_violet,
		},
	},

	decoration = {
		active_opacity = active_opacity,
		inactive_opacity = inactive_opacity,

		shadow = {
			color = "rgba(8A47F7FF)", -- purple-blue blend that complements the gradient
			color_inactive = "rgba(433597AA)", -- muted glow for inactive windows
		},

		dim_inactive = false, -- disabled dimming
		dim_strength = dim_strength_val,
		dim_special = dim_special_val,
	},
})
