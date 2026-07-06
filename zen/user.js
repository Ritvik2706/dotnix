// ─────────────────────────────────────────────────────────────
// Managed user.js — symlinked from dotfiles, reapplied every launch.
// Goal: JetBrainsMono Nerd Font as the font for ALL page text.
// ─────────────────────────────────────────────────────────────

// Point every generic family at JetBrainsMono Nerd Font, for both the
// Western and the catch-all Unicode language groups (covers most pages).
user_pref("font.name.serif.x-western",      "SF Pro Text");
user_pref("font.name.sans-serif.x-western", "SF Pro Text");
user_pref("font.name.monospace.x-western",  "JetBrainsMono Nerd Font");
user_pref("font.name.serif.x-unicode",      "SF Pro Text");
user_pref("font.name.sans-serif.x-unicode", "SF Pro Text");
user_pref("font.name.monospace.x-unicode",  "JetBrainsMono Nerd Font");

// Make sans-serif the "default" generic so unstyled text uses it too.
user_pref("font.default.x-western", "sans-serif");
user_pref("font.default.x-unicode", "sans-serif");

// The important one: ignore fonts the page asks for, so EVERYTHING
// falls back to the generics above. (0 = never use page fonts; 1 = do.)
user_pref("browser.display.use_document_fonts", 0);

// Enable userChrome.css so the browser UI (tabs/toolbar/menus) can be
// restyled — see chrome/userChrome.css for the actual font override.
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
