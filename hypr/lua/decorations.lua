--------------------------------------------------------------------------------
-- Hyprland — decorations.lua (was conf/decorations/default.conf)
-- Rounding, blur, shadows (colors/opacity live in colors.lua)
--------------------------------------------------------------------------------

hl.config({
	decoration = {
		rounding = 16, -- matches the waybar glass pill radius
		-- screen_shader = "/home/ritvik/.config/hypr/conf/shaders/rounded_corners.frag",

		-- Blur — iOS "liquid glass": deep frost + vibrancy (saturation
		-- boost behind the glass) + fine grain for that frosted texture.
		blur = {
			enabled = true,
			xray = true,
			special = false,
			new_optimizations = true,
			size = 4, -- light frost
			passes = 2,
			brightness = 0.98, -- luminous glass rather than dark
			vibrancy = 0.1696, -- Apple's vibrancy: colors glow through, not muddy
			vibrancy_darkness = 0.0,
			noise = 0.02, -- fine frosted grain
			contrast = 1.0,
			popups = true,
			popups_ignorealpha = 0.6,
			input_methods = true,
			input_methods_ignorealpha = 0.8,
		},

		-- Soft floating-glass shadow (colors set in colors.lua).
		shadow = {
			enabled = true,
			range = 24,
			render_power = 3,
			scale = 0.97,
		},
	},
})
