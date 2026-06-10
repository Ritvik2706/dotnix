--------------------------------------------------------------------------------
-- Hyprland — keybinds/focus_move.lua (focus and move windows)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- ===== Focus / Move (vim keys + arrows) =====
local dirs = {
	{ "H", "left" },
	{ "J", "down" },
	{ "K", "up" },
	{ "L", "right" },
	{ "left", "left" },
	{ "down", "down" },
	{ "up", "up" },
	{ "right", "right" },
}

for _, d in ipairs(dirs) do
	local key, dir = d[1], d[2]
	hl.bind(main .. " + " .. key, hl.dsp.focus({ direction = dir }))
	hl.bind(main .. " + SHIFT + " .. key, hl.dsp.window.move({ direction = dir }))
end

-- ===== Focus Apps =====
hl.bind(main .. " + S", hl.dsp.exec_cmd("~/.config/custom_scripts/toggle_chatgpt.sh"))

-- ===== Resize ===== (was bindel: repeating + locked)
local resize = {
	{ "J", 0, 30 },
	{ "K", 0, -30 },
	{ "H", -30, 0 },
	{ "L", 30, 0 },
}
for _, r in ipairs(resize) do
	hl.bind(
		main .. " + CTRL + " .. r[1],
		hl.dsp.window.resize({ x = r[2], y = r[3], relative = true }),
		{ repeating = true, locked = true }
	)
end

-- --- Move "mode" for floating windows (hjkl/arrows) ---
hl.bind(main .. " + M", hl.dsp.submap("move"))

hl.define_submap("move", function()
	local steps = {
		{ "H", -20, 0 },
		{ "J", 0, 20 },
		{ "K", 0, -20 },
		{ "L", 20, 0 },
		{ "left", -20, 0 },
		{ "down", 0, 20 },
		{ "up", 0, -20 },
		{ "right", 20, 0 },
	}
	for _, s in ipairs(steps) do
		hl.bind(s[1], hl.dsp.window.move({ x = s[2], y = s[3], relative = true }))
	end
	hl.bind("ESCAPE", hl.dsp.submap("reset"))
	hl.bind("RETURN", hl.dsp.submap("reset"))
end)
