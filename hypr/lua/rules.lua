--------------------------------------------------------------------------------
-- Hyprland — rules.lua (was conf/rules/rules.conf)
-- Window rules, layer rules, workspace rules
--------------------------------------------------------------------------------

----------------------------------------
-- APP → WORKSPACE PLACEMENT (ORDER MATTERS)
----------------------------------------
-- Generic Brave first → ChatGPT-in-Brave after it (more specific) so it wins.

-- Brave (generic): workspace 1
hl.window_rule({
	name = "brave-ws1",
	match = { class = [[^(brave-browser|app\.brave\.Browser)$]] },
	workspace = "1",
})

-- Brave → ChatGPT (PWA/window): workspace 11 (overrides generic rule above)
hl.window_rule({
	name = "chatgpt-ws11-title",
	match = { class = [[^(brave|Brave-browser|app\.brave\.Browser|Brave)$]], title = "^ChatGPT(.*)$" },
	workspace = "11",
})
hl.window_rule({
	name = "chatgpt-ws11-initialtitle",
	match = { class = [[^(brave|Brave-browser|app\.brave\.Browser|Brave)$]], initial_title = "^ChatGPT(.*)$" },
	workspace = "11",
})

-- Ghostty: workspace 2, fullscreen, no blur
hl.window_rule({
	name = "ghostty",
	match = { class = [[^(com\.mitchellh\.ghostty)$]] },
	workspace = "2",
	fullscreen = true,
	no_blur = true,
	opacity = "0.99 override 0.99 override",
})

-- Any terminal on workspace 2: fullscreen
hl.window_rule({
	name = "ws2-fullscreen",
	match = { workspace = "2", class = [[^(com\.mitchellh\.ghostty|org\.alacritty|kitty|foot|wezterm)$]] },
	fullscreen = true,
})

----------------------------------------
-- BLUR & OPACITY
----------------------------------------
-- Disable blur for empty-class/title Xwayland popups
hl.window_rule({
	name = "noblur-empty-popups",
	match = { class = "^$", title = "^$" },
	no_blur = true,
})

----------------------------------------
-- FLOATING WINDOWS
----------------------------------------
-- Generic dialogs — float + center
hl.window_rule({
	name = "dialogs-float",
	match = { title = "^(Open File|Select a File|Choose wallpaper|Open Folder|Save As|Library|File Upload)(.*)$" },
	float = true,
	center = true,
})

-- Wallpaper chooser — custom size
hl.window_rule({
	name = "wallpaper-chooser-size",
	match = { title = "^(Choose wallpaper)(.*)$" },
	size = "60% 65%",
})

-- "Wants to save/open" dialogs
hl.window_rule({
	name = "wants-save-open",
	match = { title = "^(.*)(wants to (save|open))$" },
	float = true,
	center = true,
})

-- App-specific float rules
hl.window_rule({
	name = "small-apps-float",
	match = { class = [[^(blueberry\.py|guifetch|Zotero)$]] },
	float = true,
})
hl.window_rule({
	name = "zotero-size",
	match = { class = "^(Zotero)$" },
	size = "45% 45%",
})

-- PulseAudio / Pavucontrol
hl.window_rule({
	name = "pavucontrol",
	match = { class = [[^(pavucontrol|org\.pulseaudio\.pavucontrol)$]] },
	float = true,
	size = "45% 45%",
	center = true,
})

-- Network Manager editor
hl.window_rule({
	name = "nm-connection-editor",
	match = { class = "^(nm-connection-editor)$" },
	float = true,
	size = "45% 45%",
	center = true,
})

-- KDE helpers / applets
hl.window_rule({ name = "plasmawindowed-float", match = { class = ".*plasmawindowed.*" }, float = true })
hl.window_rule({ name = "kcm-float", match = { class = "kcm_.*" }, float = true })
hl.window_rule({ name = "bluedevil-float", match = { class = ".*bluedevilwizard" }, float = true })

-- Misc popups
hl.window_rule({ name = "welcome-float", match = { title = ".*Welcome" }, float = true })
hl.window_rule({ name = "ii-settings-float", match = { title = "^(illogical-impulse Settings)$" }, float = true })
hl.window_rule({ name = "shell-conflicts-float", match = { title = ".*Shell conflicts.*" }, float = true })

-- Flatpak/KDE portals
hl.window_rule({
	name = "kde-portal",
	match = { class = [[org\.freedesktop\.impl\.portal\.desktop\.kde]] },
	float = true,
	size = "60% 65%",
})

----------------------------------------
-- WINDOW MOVEMENT / FOCUS ODDITIES
----------------------------------------
-- KDE "change icons" — float + hide off-screen
hl.window_rule({
	name = "plasma-changeicons",
	match = { class = "^(plasma-changeicons)$" },
	float = true,
	no_initial_focus = true,
	move = "999999 999999",
})

----------------------------------------
-- THUNAR WINDOW RULES
----------------------------------------
-- Main Thunar windows: subtle glass, tile by default
hl.window_rule({
	name = "thunar-main",
	match = { class = "^(Thunar|thunar)$" },
	opacity = "0.96 override 0.92 override",
	rounding = 14,
	tile = true,
})

-- Properties & Preferences
hl.window_rule({
	name = "thunar-props",
	match = { class = "^(Thunar|thunar)$", title = "^(Properties|Preferences)(.*)$" },
	float = true,
	center = true,
	size = "55% 60%",
})

-- Bulk Rename
hl.window_rule({
	name = "thunar-bulk-rename",
	match = { class = "^(Thunar|thunar)$", title = [[.*(Bulk\s?Rename).*]] },
	float = true,
	center = true,
	size = "70% 65%",
})

-- "Open With" / "Choose Application"
hl.window_rule({
	name = "thunar-open-with",
	match = { class = "^(Thunar|thunar)$", title = "^(Open With|Choose Application)(.*)$" },
	float = true,
	center = true,
	size = "55% 55%",
})

-- File operation progress (Copy/Move/Delete/Merge/Replace)
hl.window_rule({
	name = "thunar-file-ops",
	match = { class = "^(Thunar|thunar)$", title = "^(File Operation Progress|Copying|Moving|Deleting|Transferring|Replacing|Merging)(.*)$" },
	float = true,
	no_initial_focus = true,
	size = "36% 22%",
	move = "40 80",
})
-- Extra catch for some themes that name it like "Copying — thunar"
hl.window_rule({
	name = "thunar-copying-catch",
	match = { class = "^(Thunar|thunar)$", title = "^Copying( —| -)? thunar(.*)$" },
	float = true,
	no_initial_focus = true,
	size = "36% 22%",
	move = "40 80",
})

-- Confirms / conflicts
hl.window_rule({
	name = "thunar-confirms",
	match = { class = "^(Thunar|thunar)$", title = "^(Replace|Overwrite|Merge|Empty Trash|Confirm|Permissions)(.*)$" },
	float = true,
	center = true,
	size = "45% 40%",
})

-- Thunar "Open/Save/File Upload" (fallback if global rules miss)
hl.window_rule({
	name = "thunar-open-save",
	match = { class = "^(Thunar|thunar)$", title = "^(Open File|Save As|File Upload)(.*)$" },
	float = true,
	center = true,
	size = "60% 65%",
})

-- Thunar Custom Actions editor
hl.window_rule({
	name = "thunar-custom-actions",
	match = { class = "^(Thunar|thunar)$", title = ".*(Custom Action|Custom Actions).*" },
	float = true,
	center = true,
	size = "60% 60%",
})

-- Catfish (if launched from Thunar)
hl.window_rule({
	name = "catfish",
	match = { class = "^(catfish)$" },
	float = true,
	center = true,
	size = "70% 70%",
})

-- Yazi portal chooser (Wayland)
hl.window_rule({
	name = "yazi-picker",
	match = { class = "^yazi-picker$" },
	float = true,
	center = true,
	size = "70% 70%",
})
hl.window_rule({
	name = "yazi-picker-initialtitle",
	match = { initial_title = "^Yazi File Picker$" },
	float = true,
	center = true,
	size = "70% 70%",
})

----------------------------------------
-- WORKSPACE-SPECIFIC RULES
----------------------------------------
-- Workspace 2: Remove rounding and borders for tiled windows only
hl.window_rule({
	name = "ws2-tiled-flat",
	match = { workspace = "2", float = false },
	rounding = 0,
	border_size = 0,
})
hl.window_rule({
	name = "ws2-noanim",
	match = { workspace = "2" },
	no_anim = true,
})

----------------------------------------
-- TEARING / PERFORMANCE
----------------------------------------
-- Immediate presentation (low-latency, may tear)
hl.window_rule({ name = "immediate-exe", match = { title = [[.*\.exe]] }, immediate = true })
hl.window_rule({ name = "immediate-minecraft", match = { title = ".*minecraft.*" }, immediate = true })
hl.window_rule({ name = "immediate-steam-apps", match = { class = "^(steam_app).*" }, immediate = true })

----------------------------------------
-- TILING RULES
----------------------------------------
-- Force Warp terminal to tile
hl.window_rule({ name = "warp-tile", match = { class = [[^dev\.warp\.Warp$]] }, tile = true })

----------------------------------------
-- PICTURE-IN-PICTURE
----------------------------------------
hl.window_rule({
	name = "pip",
	match = { title = [[^([Pp]icture[-\s]?[Ii]n[-\s]?[Pp]icture)(.*)$]] },
	float = true,
	keep_aspect_ratio = true,
	move = "73% 72%",
	size = "25% 25%",
	pin = true,
})

----------------------------------------
-- SCRATCHPADS
----------------------------------------
-- CopyQ scratchpad
hl.window_rule({
	name = "copyq",
	match = { class = [[^(copyq|CopyQ|com\.github\.hluk\.copyq)$]] },
	float = true,
	center = true,
	size = "900 600",
})

-- Yazi FM popup (kitty wrapper)
hl.window_rule({
	name = "yazi-fm",
	match = { class = "^yazi-fm$" },
	workspace = "special:yazi",
	float = true,
	center = true,
	size = "80% 75%",
	stay_focused = true,
	rounding = 18,
	opacity = "0.97 override 0.97 override",
})

----------------------------------------
-- Zathura — workspace 3
----------------------------------------
hl.window_rule({
	name = "zathura",
	match = { class = [[^(org\.pwmt\.zathura.*)$]] },
	workspace = "3",
})

----------------------------------------
-- Albert — zero chrome, zero blur/halo
----------------------------------------
hl.window_rule({
	name = "albert",
	match = { class = "^(albert)$" },
	float = true,
	center = true,
	size = "600 400",
	border_size = 0,
	no_shadow = true,
	rounding = 0,
	no_blur = true,
	opacity = "0.97 0.97",
	stay_focused = true,
	no_anim = true,
})

----------------------------------------
-- Sensible defaults kept from the autogenerated config
----------------------------------------
-- Ignore maximize requests from all apps
hl.window_rule({
	name = "suppress-maximize-events",
	match = { class = ".*" },
	suppress_event = "maximize",
})

-- Fix some dragging issues with XWayland
hl.window_rule({
	name = "fix-xwayland-drags",
	match = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
	no_focus = true,
})

----------------------------------------
-- WORKSPACE RULES
----------------------------------------
-- Special scratchpad workspace
hl.workspace_rule({ workspace = "special:special", gaps_out = 30 })

-- Workspace 2: No gaps for tiled windows (terminal workspace)
hl.workspace_rule({ workspace = "2", gaps_in = 0, gaps_out = 0 })

----------------------------------------
-- LAYER RULES
----------------------------------------
-- Global rules
hl.layer_rule({ name = "xray-all", match = { namespace = ".*" }, xray = true })
hl.layer_rule({ name = "noanim-noanim", match = { namespace = "noanim" }, no_anim = true })

-- Disable animations for overlays
hl.layer_rule({
	name = "noanim-overlays",
	match = { namespace = "walker|selection|overview|anyrun|indicator.*|osk|hyprpicker" },
	no_anim = true,
})

-- GTK layer-shell (Waybar, wlogout, etc.)
hl.layer_rule({ name = "gtk-layer-shell", match = { namespace = "gtk-layer-shell" }, blur = true, ignore_alpha = 0 })

-- Launchers & notifications
hl.layer_rule({ name = "launcher", match = { namespace = "launcher" }, blur = true, ignore_alpha = 0.5 })
hl.layer_rule({ name = "notifications", match = { namespace = "notifications" }, blur = true, ignore_alpha = 0.69 })
hl.layer_rule({ name = "logout-dialog", match = { namespace = "logout_dialog" }, blur = true })

-- AGS surfaces
hl.layer_rule({ name = "ags-sideleft", match = { namespace = "sideleft.*" }, animation = "slide left" })
hl.layer_rule({ name = "ags-sideright", match = { namespace = "sideright.*" }, animation = "slide right" })
hl.layer_rule({
	name = "ags-blur",
	match = { namespace = "bar[0-9]*|session[0-9]*|dock[0-9]*|indicator.*|overview[0-9]*|cheatsheet[0-9]*|sideright[0-9]*|sideleft[0-9]*|osk[0-9]*" },
	blur = true,
})
hl.layer_rule({
	name = "ags-ignorealpha",
	match = { namespace = "bar[0-9]*|barcorner.*|dock[0-9]*|indicator.*|overview[0-9]*|cheatsheet[0-9]*|sideright[0-9]*|sideleft[0-9]*|osk[0-9]*" },
	ignore_alpha = 0.6,
})

-- Quickshell
hl.layer_rule({
	name = "quickshell-blur",
	match = { namespace = "quickshell:.*" },
	blur = true,
	blur_popups = true,
	ignore_alpha = 0.79,
})
hl.layer_rule({ name = "qs-bar-anim", match = { namespace = "quickshell:bar|quickshell:verticalBar" }, animation = "slide" })
hl.layer_rule({
	name = "qs-fade-anim",
	match = { namespace = "quickshell:screenCorners|quickshell:notificationPopup" },
	animation = "fade",
})
hl.layer_rule({ name = "qs-sidebar-right", match = { namespace = "quickshell:sidebarRight" }, animation = "slide right" })
hl.layer_rule({ name = "qs-sidebar-left", match = { namespace = "quickshell:sidebarLeft" }, animation = "slide left" })
hl.layer_rule({ name = "qs-bottom-anim", match = { namespace = "quickshell:osk|quickshell:dock" }, animation = "slide bottom" })
hl.layer_rule({
	name = "qs-noanim",
	match = { namespace = "quickshell:session|quickshell:overview|gtk4-layer-shell|quickshell:screenshot|quickshell:lockWindowPusher" },
	no_anim = true,
})
hl.layer_rule({
	name = "qs-session-blur",
	match = { namespace = "quickshell:session|quickshell:backgroundWidgets" },
	blur = true,
})
hl.layer_rule({ name = "qs-session-alpha", match = { namespace = "quickshell:session" }, ignore_alpha = 0 })
hl.layer_rule({ name = "qs-bgwidgets-alpha", match = { namespace = "quickshell:backgroundWidgets" }, ignore_alpha = 0.05 })

-- Outfoxxed's shell namespace
hl.layer_rule({ name = "shell-blur", match = { namespace = "shell:bar|shell:notifications" }, blur = true })
hl.layer_rule({ name = "shell-bar-alpha", match = { namespace = "shell:bar" }, ignore_alpha = 0 })
hl.layer_rule({ name = "shell-notif-alpha", match = { namespace = "shell:notifications" }, ignore_alpha = 0.1 })
