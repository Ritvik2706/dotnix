--------------------------------------------------------------------------------
-- Hyprland — colors.lua (was conf/themes/colors.conf)
-- Palette + theming-only settings (borders, shadow, opacities, dim)
--------------------------------------------------------------------------------

local c = require("lua.vars").colors

-- === Opacity / dim (theme constants) ===
--local active_opacity = 0.94 -- subtle glass on focused windows (terminal opted out via rule)
local inactive_opacity = 0.90 -- clean glass; just a hint of translucency when unfocused
local dim_strength_val = 0.0 -- no dimming
local dim_special_val = 0.0 -- no dimming for special windows

hl.config({
	general = {
		col = {
			-- Liquid-glass rim: a soft lilac→white sheen that catches light.
			active_border = { colors = { c.glass_lilac, c.glass_edge }, angle = 120 },
			inactive_border = c.glass_edge_soft,
		},
	},

	decoration = {
		active_opacity = active_opacity,
		inactive_opacity = inactive_opacity,

		shadow = {
			color = c.glass_shadow, -- soft neutral ambient drop (floating glass)
			color_inactive = c.glass_shadow_in,
		},

		dim_inactive = false, -- disabled dimming
		dim_strength = dim_strength_val,
		dim_special = dim_special_val,
	},
})
