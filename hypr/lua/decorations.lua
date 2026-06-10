--------------------------------------------------------------------------------
-- Hyprland — decorations.lua (was conf/decorations/default.conf)
-- Rounding, blur, shadows (colors/opacity live in colors.lua)
--------------------------------------------------------------------------------

hl.config({
	decoration = {
		rounding = 12,
		-- screen_shader = "/home/ritvik/.config/hypr/conf/shaders/rounded_corners.frag",

		-- Blur settings for neon glow effect
		blur = {
			enabled = true,
			xray = true,
			special = false,
			new_optimizations = true,
			size = 8, -- blur_size for glow effect
			passes = 4, -- blur_passes for stronger glow
			brightness = 1,
			noise = 0.005,
			contrast = 1.1,
			popups = true,
			popups_ignorealpha = 0.6,
			input_methods = true,
			input_methods_ignorealpha = 0.8,
		},

		-- Neon glow shadow effect
		shadow = {
			enabled = true,
			range = 7, -- larger range for better glow
			render_power = 4,
			color = "rgba(62AEEFCC)", -- bright blue glow matching border
			color_inactive = "rgba(43359755)", -- subtle glow for inactive
			offset = { 0, 0 }, -- centered glow
		},
	},
})
