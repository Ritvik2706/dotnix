--------------------------------------------------------------------------------
-- Hyprland — notify.lua
-- Small dunstify helper for the keybinds that pair an action with a toast.
--------------------------------------------------------------------------------

local M = {}

local ICONS = {
	window = "/usr/share/icons/candy-icons/places/48/folder-windows.svg",
	desktop = "/usr/share/icons/candy-icons/places/48/desktop.svg",
	muted = "/usr/share/icons/candy-icons/status/scalable/audio-volume-muted-symbolic.svg",
}

-- opts: app, icon (key of ICONS or path), replace_id, urgency, stack_tag
function M.send(title, body, opts)
	opts = opts or {}
	local icon = ICONS[opts.icon] or opts.icon or ICONS.window
	local cmd = string.format(
		'dunstify -a "%s" -i "%s" -r %d -u %s -h string:x-dunst-stack-tag:%s "%s" "%s"',
		opts.app or "Window",
		icon,
		opts.replace_id or 72937,
		opts.urgency or "low",
		opts.stack_tag or "layout",
		title,
		body
	)
	hl.exec_cmd(cmd)
end

return M
