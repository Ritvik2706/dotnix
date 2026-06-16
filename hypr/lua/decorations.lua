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
			size = 4, -- moderate frost: enough to read text over a busy wallpaper
			passes = 2,
			brightness = 0.98, -- luminous glass rather than dark
			vibrancy = 0.25, -- push color through so the glass refracts rather than smears
			vibrancy_darkness = 0.0,
			noise = 0.015, -- barely-there grain
			contrast = 1.12, -- crisper edges = more "lensed glass", less milky haze
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
