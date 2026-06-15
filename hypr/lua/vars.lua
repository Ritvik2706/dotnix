--------------------------------------------------------------------------------
-- Hyprland — vars.lua (shared variables, was conf/system/vars.conf)
--------------------------------------------------------------------------------

local M = {}

M.mainMod = "SUPER" -- Main modifier key (physical Windows key on the Razer)
M.altMod  = "ALT"
M.term    = "ghostty"
M.menu    = "wofi --show drun"
M.opacity = 1

-- Color palette — Liquid Glass (matches waybar style.css)
-- The active language is the glass_* tokens below; the cyberpunk colors
-- are kept so older modules referencing them don't break.
M.colors = {
	-- Liquid-glass language (current)
	glass_accent    = "rgb(8AD8FF)",      -- sky accent (waybar active workspace)
	glass_lilac     = "rgb(C9B6FF)",      -- soft lilac (window border tint)
	glass_edge      = "rgba(FFFFFFCC)",   -- bright specular rim that catches light
	glass_edge_soft = "rgba(FFFFFF1F)",   -- faint hairline for inactive edges
	glass_shadow    = "rgba(0000004D)",   -- soft neutral ambient drop
	glass_shadow_in = "rgba(00000026)",   -- lighter drop for inactive windows

	-- Hero accents (legacy cyberpunk)
	razer        = "rgb(44D62C)", -- Razer green
	razer_bright = "rgb(76FF58)", -- bright green highlight
	razer_dim    = "rgb(2A8A1A)", -- dim green
	cyan         = "rgb(00F0FF)", -- neon cyan
	magenta      = "rgb(FF2A6D)", -- hot magenta
	yellow       = "rgb(FAFF00)", -- cyber yellow
	purple       = "rgb(6E5A8C)", -- muted dusk purple (subtle active border)

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
