--------------------------------------------------------------------------------
-- Hyprland — input.lua (was conf/input/input.conf)
--------------------------------------------------------------------------------

hl.config({
	input = {
		kb_layout = "us",
		-- Razer Blade has a standard PC layout, so the MacBook-era
		-- altwin:swap_alt_win swap is gone. Caps↔Escape stays.
		kb_options = "caps:swapescape",

		-- Global default stays adaptive so the trackpad keeps its acceleration
		-- curve; flat/no-accel is scoped to the real mice in the device blocks
		-- at the bottom of this file.
		sensitivity = 0,
		left_handed = false,
		follow_mouse = 1,
		float_switch_override_focus = 0,

		touchpad = {
			natural_scroll = true, -- macOS "natural" content-tracks-finger scroll
			tap_button_map = "lrm", -- 1/2/3-finger tap = left/right/middle click
			tap_and_drag = true, -- tap then drag = press-and-hold drag (macOS)
			drag_lock = true, -- brief lift mid-drag doesn't drop the drag
			clickfinger_behavior = true, -- 2-finger click = right click (no click zones)
			disable_while_typing = true, -- palm/typing rejection
			scroll_factor = 0.45, -- slightly smoother/heavier glide
			middle_button_emulation = false, -- L+R chord stays two real clicks
		},
	},
})

--------------------------------------------------------------------------------
-- Per-device: raw 1:1 pointing for real mice only
--------------------------------------------------------------------------------
-- Windows' default pointer speed (6/11 slider) is raw counts→pixels with
-- "Enhance pointer precision" off: sensitivity 0 + accel_profile flat.
-- Scoped per-device so the trackpad above keeps libinput's adaptive curve —
-- a trackpad without accel can't flick across a 2560px screen in one swipe.
-- scroll_method is an input-level (not input:touchpad) option, so pin it on the
-- touchpad device itself: two-finger scroll only, never the legacy edge strip.
hl.device({
	name = "1a58201b:00-06cb:cd73-touchpad",
	scroll_method = "2fg",
})

for _, mouse in ipairs({
	"cestus-310-opticalmouse", -- wired Cestus 310
	"x66-2.4g-1", -- X66 wireless dongle's pointer endpoint
	"razer-razer-blade-2", -- Blade's own HID pointer endpoints
	"razer-razer-blade-4",
}) do
	hl.device({
		name = mouse,
		sensitivity = 0,
		accel_profile = "flat",
	})
end

--------------------------------------------------------------------------------
-- Trackpad gestures — tuned for a macOS-like, momentum-y feel
--------------------------------------------------------------------------------

-- Workspace-swipe feel: a short flick commits the switch (like macOS Spaces),
-- the gesture tracks the finger 1:1, and you can keep swiping through several
-- workspaces in one continuous motion.
hl.config({
	gestures = {
		workspace_swipe_distance = 450, -- px of travel for a full 1:1 switch
		workspace_swipe_cancel_ratio = 0.15, -- past 15% it commits; otherwise snaps back
		workspace_swipe_min_speed_to_force = 5, -- quick flick always commits
		workspace_swipe_direction_lock = true, -- lock to horizontal once moving
		workspace_swipe_direction_lock_threshold = 10,
		workspace_swipe_forever = true, -- chain multiple switches in one swipe
		workspace_swipe_create_new = false, -- don't spawn empty workspaces past the end
	},
})

-- Helper: run a dispatcher as a gesture action.
local function dispatch(d)
	return function()
		hl.dispatch(d)
	end
end

-- 3- and 4-finger horizontal swipe → switch workspaces (Spaces).
-- macOS lets you use either, so both are bound.
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })

-- 4-finger swipe down → mute, swipe up → unmute (with a dunst OSD).
-- NOTE: 2-finger edge gestures aren't possible — libinput reserves 2-finger
-- motion for scrolling and exposes no trackpad-region/edge info — so this
-- lives on a full 4-finger vertical swipe instead.
hl.gesture({
	fingers = 4,
	direction = "down",
	action = dispatch(hl.dsp.exec_cmd(
		[[wpctl set-mute @DEFAULT_AUDIO_SINK@ 1 && dunstify -a "Volume" -i audio-volume-muted -r 72932 -u low -h string:x-dunst-stack-tag:volume "Volume" "Muted"]]
	)),
})
hl.gesture({
	fingers = 4,
	direction = "up",
	action = dispatch(hl.dsp.exec_cmd(
		[[wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && dunstify -a "Volume" -i audio-volume-high -r 72932 -u low -h string:x-dunst-stack-tag:volume -h int:value:$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2*100)}') "Volume" "Unmuted — $(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2*100)}')%"]]
	)),
})

-- 3-finger swipe up → bring up the Claude popup; swipe down → hide it again.
hl.gesture({
	fingers = 3,
	direction = "up",
	action = dispatch(hl.dsp.exec_cmd("~/.config/custom_scripts/toggle_claude.sh show")),
})
hl.gesture({
	fingers = 3,
	direction = "down",
	action = dispatch(hl.dsp.exec_cmd("~/.config/custom_scripts/toggle_claude.sh hide")),
})
