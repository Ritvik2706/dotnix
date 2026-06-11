--------------------------------------------------------------------------------
-- Hyprland — misc.lua (was conf/system/misc.conf)
--------------------------------------------------------------------------------

hl.config({
	misc = {
		mouse_move_focuses_monitor = true,
		disable_hyprland_logo = true,
		disable_splash_rendering = true,
		vrr = 1,
		-- vfr was removed as a misc option (frame limiting is automatic now)
		mouse_move_enables_dpms = true,
		key_press_enables_dpms = true,
		animate_manual_resizes = false,
		animate_mouse_windowdragging = false,
		enable_swallow = false,
		-- new_window_takes_over_fullscreen = 2 no longer exists; closest match
		-- today is on_focus_under_fullscreen — uncomment if you miss the old
		-- "new window kicks me out of fullscreen" behavior:
		-- on_focus_under_fullscreen = 2,
		allow_session_lock_restore = true,
		session_lock_xray = true,
		initial_workspace_tracking = false,
		focus_on_activate = true,
	},
})
