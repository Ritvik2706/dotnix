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
