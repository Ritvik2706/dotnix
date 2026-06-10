--------------------------------------------------------------------------------
-- Hyprland — keybinds/screenshots.lua (grim/slurp)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- Area selection to clipboard
hl.bind(main .. " + V", hl.dsp.exec_cmd([[bash -lc 'grim -g "$(slurp)" - | wl-copy']]))
hl.bind(main .. " + SHIFT + V", hl.dsp.exec_cmd("/home/ritvik/.config/custom_scripts/ocr-sel"))

-- Area selection saved to Screenshots directory
hl.bind(main .. " + B", hl.dsp.exec_cmd([[bash -lc 'grim -g "$(slurp)" "$HOME/Pictures/Screenshots/screenshot-$(date +%F-%H-%M-%S).png"']]))

-- Whole screen to clipboard
hl.bind("Print", hl.dsp.exec_cmd([[bash -lc 'grim - | wl-copy']]))

-- Whole screen saved to Screenshots directory
hl.bind("SHIFT + Print", hl.dsp.exec_cmd([[bash -lc 'grim "$HOME/Pictures/Screenshots/screenshot-$(date +%F-%H-%M-%S).png"']]))

-- hl.bind(main .. " + XF86LaunchB", hl.dsp.exec_cmd("/home/ritvik/.config/custom_scripts/ocr-shot.sh"))
