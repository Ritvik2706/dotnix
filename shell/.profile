export EDITOR=/usr/bin/nano
# NOTE: was QT_QPA_PLATFORMTHEME="qt5ct" — qt5ct is not installed, and most
# Qt apps here are Qt6, so the lookup failed and Qt fell back to a LIGHT
# default palette (that's why the screen-share picker was white). Left unset
# so Qt's generic theme reads the XDG portal color-scheme (prefer-dark).
# Set it to qt6ct only if qt6ct is actually installed.
export QT_AUTO_SCREEN_SCALE_FACTOR=0
export GTK2_RC_FILES="$HOME/.gtkrc-2.0"
