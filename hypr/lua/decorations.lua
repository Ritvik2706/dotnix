--------------------------------------------------------------------------------
-- Hyprland — decorations.lua (was conf/decorations/default.conf)
-- Rounding, blur, shadows (colors/opacity live in colors.lua)
--------------------------------------------------------------------------------

hl.config({
	decoration = {
		rounding = 14, -- soft curvature to match the rounded waybar pills
		-- screen_shader = "/home/ritvik/.config/hypr/conf/shaders/rounded_corners.frag",

		-- Blur — dark glass behind windows for the cyberpunk depth
		blur = {
			enabled = true,
			xray = true,
			special = false,
			new_optimizations = true,
			size = 8, -- blur_size for glow effect
			passes = 4, -- blur_passes for stronger glow
			brightness = 0.92, -- slightly darker glass, lets neon edges pop
			noise = 0.012, -- subtle grain for a screen/CRT feel
			contrast = 1.15,
			popups = true,
			popups_ignorealpha = 0.6,
			input_methods = true,
			input_methods_ignorealpha = 0.8,
		},

		-- Glow disabled
		shadow = {
			enabled = false,
		},
	},
})
