--------------------------------------------------------------------------------
-- Hyprland — env.lua (environment variables, was conf/system/env.conf)
--------------------------------------------------------------------------------

-- hl.env("GTK_USE_PORTAL", "1") -- Commented out - causes theme loading issues
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

-- Cursor theme + size for Wayland apps
hl.env("HYPRCURSOR_THEME", "Bibata-Modern-Ice")
hl.env("HYPRCURSOR_SIZE", "21")

-- Xcursor (GTK/Qt/Electron honor these)
hl.env("XCURSOR_THEME", "Bibata-Modern-Ice")
hl.env("XCURSOR_SIZE", "21")

-- PRIME hybrid graphics: iGPU (card2/Intel) primary, dGPU (card1/NVIDIA) offload-only
hl.env("WLR_DRM_DEVICES", "/dev/dri/card2:/dev/dri/card1")

-- Zen/Firefox: disable the "dedicated profile per installation" feature so Zen
-- always opens the profiles.ini Default=1 profile and can NEVER silently fork a
-- fresh profile when its install dir/symlink changes (e.g. an install.sh re-link).
-- This is what previously fragmented the profile and looked like a settings reset.
hl.env("MOZ_LEGACY_PROFILES", "1")

-- HiDPI scaling.
-- Qt: prefer native Wayland so the compositor applies the monitor scale (~1.6x)
-- exactly once. The old QT_SCALE_FACTOR=1.6 was a blunt multiplier applied ON TOP
-- of the compositor scale for native-Wayland Qt apps (qbittorrent etc.), blowing
-- them up to ~2.5x. Fall back to xcb (Xwayland) for Qt apps without Wayland support;
-- force a single app back with `QT_QPA_PLATFORM=xcb <app>` if it misbehaves.
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")

-- GTK XWayland apps: paired with misc.lua's xwayland.force_zero_scaling, this hints
-- the 1.6x display scale so they render sharp at native px.
-- (Steam ignores these; it's scaled via -forcedesktopscaling 1.6 in its .desktop.)
hl.env("GDK_SCALE", "1.6")
