--------------------------------------------------------------------------------
-- Hyprland — keybinds/scratchpad.lua (scratchpad and special workspaces)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- ===== Scratchpad / Special Workspaces =====
hl.bind(main .. " + X", hl.dsp.workspace.toggle_special("special")) -- (was Super+W: that is the island's WhatsApp now)
hl.bind(main .. " + SHIFT + X", hl.dsp.window.move({ workspace = "special:special", follow = false }))
