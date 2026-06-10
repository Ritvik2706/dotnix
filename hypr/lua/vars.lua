--------------------------------------------------------------------------------
-- Hyprland — vars.lua (shared variables, was conf/system/vars.conf)
--------------------------------------------------------------------------------

local M = {}

M.mainMod = "SUPER" -- Main modifier key (physical Windows key on the Razer)
M.altMod  = "ALT"
M.term    = "ghostty"
M.menu    = "wofi --show drun"
M.opacity = 1

-- Color palette
M.colors = {
	light_blue       = "rgb(62AEEF)",
	dark_blue        = "rgb(020221)",
	light_green_blue = "rgb(62AEA4)",
	light_green      = "rgb(00AEAA)",
	dark_green       = "rgb(001B26)",
	pink             = "rgb(B542FF)",
	dark_violet      = "rgb(433597)",
	light_gray_a     = "rgba(595959aa)",
	light_gray       = "rgb(595959)",
	dark_gray        = "rgb(0C0C0C)",
}

return M
