#!/usr/bin/env python3
"""Install/select Attitude, or restore the previous middle-finger theme."""
import argparse
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
THEMES = {
    'attitude': 'Bibata-Modern-Ice-Attitude',
    'previous': 'Bibata-Modern-Ice-MiddleFinger',
}
CONFIGS = ('niri/conf/general.kdl', 'hypr/lua/env.lua',
           'gtk-3.0/settings.ini', 'gtk-4.0/settings.ini',
           'xsettingsd/xsettingsd.conf')
PATTERN = re.compile(r'Bibata-Modern-Ice(?:-MiddleFinger|-Attitude)?(?![\w-])')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('theme', choices=THEMES)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    name = THEMES[args.theme]
    edits = {}
    for relative in CONFIGS:
        path = REPO / relative
        if path.exists():
            before = path.read_text()
            after, count = PATTERN.subn(name, before)
            if not count:
                raise SystemExit(f'No known Bibata theme found in {path}; refusing partial switch.')
            edits[path] = (before, after)
    icons = Path(os.environ.get('XDG_DATA_HOME', str(Path.home()/'.local/share'))) / 'icons'
    for theme in THEMES.values():
        source, target = ROOT/theme, icons/theme
        if not (source/'cursors/hand2').is_file():
            raise SystemExit(f'Missing built theme: {source}')
        if (target.exists() or target.is_symlink()) and target.resolve() != source:
            raise SystemExit(f'Refusing to replace {target}')
    if args.dry_run:
        print(f'Would select {name} in desktop preferences and {len(edits)} config files.')
        return
    old_theme = subprocess.check_output(
        ['gsettings','get','org.gnome.desktop.interface','cursor-theme'], text=True
    ).strip().strip("'")
    icons.mkdir(parents=True, exist_ok=True)
    for theme in THEMES.values():
        target = icons/theme
        if not target.is_symlink():
            target.symlink_to(ROOT/theme)
    try:
        subprocess.run(['gsettings','set','org.gnome.desktop.interface','cursor-theme',name],check=True)
        for path,(_,after) in edits.items():
            path.write_text(after)
    except Exception:
        for path,(before,_) in edits.items():
            path.write_text(before)
        subprocess.run(['gsettings','set','org.gnome.desktop.interface','cursor-theme',old_theme],check=False)
        raise
    print(f'Selected {name}. Cursor size preserved. Restart apps that cache cursors.')


if __name__ == '__main__':
    main()
