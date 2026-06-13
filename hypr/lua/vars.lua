--------------------------------------------------------------------------------
-- Hyprland — vars.lua (shared variables, was conf/system/vars.conf)
--------------------------------------------------------------------------------

local M = {}

M.mainMod = "SUPER" -- Main modifier key (physical Windows key on the Razer)
M.altMod  = "ALT"
M.term    = "ghostty"
M.menu    = "wofi --show drun"
M.opacity = 1

-- Color palette — Cyberpunk / Razer Green (matches waybar style.css)
M.colors = {
	-- Hero accents
	razer        = "rgb(44D62C)", -- Razer green
	razer_bright = "rgb(76FF58)", -- bright green highlight
	razer_dim    = "rgb(2A8A1A)", -- dim green
	cyan         = "rgb(00F0FF)", -- neon cyan
	magenta      = "rgb(FF2A6D)", -- hot magenta
	yellow       = "rgb(FAFF00)", -- cyber yellow

	-- Surfaces / neutrals
	base         = "rgb(07080E)", -- darkest background
	surface      = "rgb(0D0F18)",
	surface1     = "rgb(12151F)",
	text         = "rgb(D6F5CF)",
	subtext      = "rgb(5E7A8A)",
	off          = "rgb(2A3450)", -- muted / inactive outline

	-- Legacy aliases (kept so other modules don't break on old names)
	light_blue       = "rgb(00F0FF)",
	dark_blue        = "rgb(07080E)",
	light_green_blue = "rgb(00F0FF)",
	light_green      = "rgb(44D62C)",
	dark_green       = "rgb(07080E)",
	pink             = "rgb(FF2A6D)",
	dark_violet      = "rgb(2A3450)",
	light_gray_a     = "rgba(2A3450aa)",
	light_gray       = "rgb(5E7A8A)",
	dark_gray        = "rgb(07080E)",
}

return M
