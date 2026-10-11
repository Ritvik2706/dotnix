--------------------------------------------------------------------------------
-- Hyprland — keybinds/screenshots.lua (grim/slurp via scripts/screenshot.sh)
-- Every shot lands on the clipboard; "save" also writes ~/Pictures/Screenshots.
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

local function shot(target, action)
	return hl.dsp.exec_cmd("~/.config/hypr/scripts/screenshot.sh " .. target .. " " .. action)
end

-- Area selection
hl.bind(main .. " + V", shot("area", "copy"))
hl.bind(main .. " + B", shot("area", "save"))
hl.bind(main .. " + SHIFT + V", hl.dsp.exec_cmd("/home/ritvik/.config/custom_scripts/ocr-sel"))

-- Focused window
hl.bind(main .. " + CTRL + V", shot("window", "copy"))
hl.bind(main .. " + CTRL + B", shot("window", "save"))

-- Whole screen
hl.bind("Print", shot("screen", "copy"))
hl.bind("SHIFT + Print", shot("screen", "save"))

-- hl.bind(main .. " + XF86LaunchB", hl.dsp.exec_cmd("/home/ritvik/.config/custom_scripts/ocr-shot.sh"))
