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

// Let pages use the fonts they ask for. The generics above only kick in
// when a page doesn't specify one. (0 = never use page fonts; 1 = do.)
user_pref("browser.display.use_document_fonts", 1);

// Enable userChrome.css so the browser UI (tabs/toolbar/menus) can be
// restyled — see chrome/userChrome.css for the actual font override.
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// ─────────────────────────────────────────────────────────────
// Scroll feel — tighten Gecko's mass-spring-damper scroll physics
// so wheel scrolling reads closer to Chromium/Brave (snappier
// ease-out instead of the floaty default).
// ─────────────────────────────────────────────────────────────
user_pref("general.smoothScroll", true);
user_pref("general.smoothScroll.msdPhysics.enabled", true);
user_pref("general.smoothScroll.msdPhysics.motionBeginSpringConstant", 600);
user_pref("general.smoothScroll.msdPhysics.regularSpringConstant", 650);
user_pref("general.smoothScroll.msdPhysics.slowdownMinDeltaMS", 12);
user_pref("general.smoothScroll.msdPhysics.slowdownMinDeltaRatio", "2.0");
user_pref("general.smoothScroll.msdPhysics.slowdownSpringConstant", 250);
user_pref("general.smoothScroll.currentVelocityWeighting", "0.15");
user_pref("general.smoothScroll.stopDecelerationWeighting", "0.6");

// Distance per wheel notch (100 = default). Higher = less spinning.
user_pref("mousewheel.default.delta_multiplier_y", 275);
