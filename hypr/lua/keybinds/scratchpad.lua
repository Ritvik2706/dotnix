--------------------------------------------------------------------------------
-- Hyprland — keybinds/scratchpad.lua (scratchpad and special workspaces)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- ===== Scratchpad / Special Workspaces =====
hl.bind(main .. " + W", hl.dsp.workspace.toggle_special("special"))
hl.bind(main .. " + SHIFT + W", hl.dsp.window.move({ workspace = "special:special", follow = false }))
