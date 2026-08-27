#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# LUMEN · LibreOffice — apply the theme to the live user profile.
#
# LibreOffice keeps its settings in a single generated file,
# ~/.config/libreoffice/4/user/registrymodifications.xcu, which it rewrites
# wholesale on exit. That makes it a bad thing to symlink into git (same trap
# as the Zen profile) and a bad thing to edit while the app is running — so
# this script merges lumen.conf into that file instead, and refuses to run if
# LibreOffice has it open.
#
#   ./apply.sh              apply the theme (dark chrome, light page)
#   ./apply.sh --dark-page  ... with the page dark too — see lumen-light.conf
#                           for why that costs you shaded documents
#   ./apply.sh --revert     remove it and fall back to LibreOffice's defaults
#
# Idempotent: every run strips the previously written Lumen entries first.
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
conf="$here/lumen.conf"
light="$here/lumen-light.conf"
reg="${HOME}/.config/libreoffice/4/user/registrymodifications.xcu"

revert=0 dark_page=0
case "${1:-}" in
  --revert)    revert=1 ;;
  --dark-page) dark_page=1 ;;
  '')          ;;
  *)           echo "usage: $0 [--dark-page|--revert]" >&2; exit 2 ;;
esac
# The page-colour delta is layered on top of the base scheme; later files win.
confs="$conf"
(( dark_page )) || confs="$conf:$light"

# ── Guards ────────────────────────────────────────────────────────────────
if [[ ! -f "$reg" ]]; then
  echo "error: $reg not found — launch LibreOffice once to create the profile." >&2
  exit 1
fi

# A defunct soffice.bin still shows up in pgrep, but it is a dead process
# awaiting reaping — it holds nothing open and must not block us, or a stray
# zombie leaves this script permanently unable to run.
lo_running() {
  local pid
  for pid in $( { pgrep -x soffice.bin; pgrep -f '/soffice(\.bin)?\b'; } 2>/dev/null | sort -u); do
    case "$(ps -o stat= -p "$pid" 2>/dev/null)" in
      ''|Z*) continue ;;
      *)     return 0 ;;
    esac
  done
  return 1
}

if lo_running; then
  echo "error: LibreOffice is running. It rewrites this file on exit, so any" >&2
  echo "       change made now would be silently discarded. Quit it first" >&2
  echo "       (including the Quickstarter) and re-run." >&2
  exit 1
fi

backup="$reg.bak-$(date +%Y%m%d-%H%M%S)"
cp -- "$reg" "$backup"

# ── Merge ─────────────────────────────────────────────────────────────────
CONFS="$confs" REG="$reg" REVERT="$revert" DARK_PAGE="$dark_page" python3 <<'PY'
import os, re, sys

confs = os.environ['CONFS'].split(':')
reg, revert = os.environ['REG'], os.environ['REVERT'] == '1'
dark_page = os.environ['DARK_PAGE'] == '1'
SCHEME = 'Lumen'
UI  = '/org.openoffice.Office.UI'
CMN = '/org.openoffice.Office.Common'
TBM = '/org.openoffice.Office.UI.ToolbarMode'

def item(path, name, value, typ=None):
    t = f' oor:type="{typ}"' if typ else ''
    return (f'<item oor:path="{path}"><prop oor:name="{name}"{t} oor:op="fuse">'
            f'<value>{value}</value></prop></item>')

lines = []
if not revert:
    # The colour scheme is a *set member*, and a set member can only be created
    # by declaring the node itself with oor:op="replace" — addressing its
    # children by oor:path does not bring it into existence. LibreOffice
    # silently discards path-addressed entries under a set node it has never
    # heard of, which leaves CurrentColorScheme pointing at nothing and crashes
    # it on the next start. This is the idiom LibreOffice uses for its own
    # shipped schemes in share/registry/main.xcd.
    # A dict, not a list: a key restated by a later file replaces the earlier
    # entry outright. Two <node> children of the same name under one
    # oor:op="replace" would be malformed, so the delta has to win here.
    entries = {}
    for conf in confs:
      for raw in open(conf, encoding='utf-8'):
        raw = raw.strip()
        # '#' starts a comment only at the head of a line — everywhere else it
        # is the prefix of a colour, so there is no inline-comment form here.
        if not raw or raw.startswith('#') or '=' not in raw:
            continue
        key, val = (s.strip() for s in raw.split('=', 1))
        parts = val.split()
        m = re.fullmatch(r'#([0-9a-fA-F]{6})', parts[0])
        if not m:
            sys.exit(f'error: {key}: expected #rrggbb, got {parts[0]!r}')
        props = (f'<prop oor:name="Color" oor:type="xs:int">'
                 f'<value>{int(m.group(1), 16)}</value></prop>')
        if len(parts) > 1:
            if parts[1] not in ('visible', 'hidden'):
                sys.exit(f'error: {key}: expected visible/hidden, got {parts[1]!r}')
            vis = 'true' if parts[1] == 'visible' else 'false'
            props += (f'<prop oor:name="IsVisible" oor:type="xs:boolean">'
                      f'<value>{vis}</value></prop>')
        entries[key] = f'<node oor:name="{key}">{props}</node>'

    children = list(entries.values())
    if not children:
        sys.exit(f'error: no colour entries parsed from {confs}')

    lines.append(f'<item oor:path="{UI}/ColorScheme/ColorSchemes">'
                 f'<node oor:name="{SCHEME}" oor:op="replace">'
                 + ''.join(children) + '</node></item>')
    lines.append(item(f'{UI}/ColorScheme', 'CurrentColorScheme', SCHEME, 'xs:string'))
    # This switch repaints every glyph black-or-white by the *window*
    # background, blind to a paragraph's or table cell's own fill. A dark page
    # needs it (otherwise "Automatic" text stays black and vanishes), but it is
    # exactly what turns light-shaded table headers into white-on-white. On the
    # light page it must be off, so documents render in their authored colours.
    lines.append(item(f'{CMN}/Accessibility', 'IsAutomaticFontColor',
                      'true' if dark_page else 'false', 'xs:boolean'))
    # Sifr Dark: thin monochrome outlines, the closest stock set to the
    # feather glyphs the waybar uses.
    lines.append(item(f'{CMN}/Misc', 'SymbolStyle', 'sifr_dark', 'xs:string'))
    # One compact toolbar + sidebar, so the chrome is a single glass slab.
    for mod in ('Writer', 'Calc', 'Impress', 'Draw'):
        lines.append(item(TBM, f'Active{mod}', 'Single', 'xs:string'))

# Two kinds of line get pulled out. `ours` is the colour scheme itself, which
# nothing but this script ever writes. `displaced` is the handful of ordinary
# settings we overwrite — a profile may well have had its own values for those
# (this one arrived with ToolbarMode already set to the tabbed-compact
# notebookbar), so the first apply stashes them and --revert puts them back
# rather than erasing a preference we never owned.
ours = re.compile(
    rf'<node oor:name="{SCHEME}" oor:op="replace">'
    rf"|ColorScheme\['{SCHEME}'\]"          # the old, broken path-addressed form
    rf'|oor:path="{re.escape(UI)}/ColorScheme"')
displaced = re.compile(
    rf'oor:path="{re.escape(CMN)}/Accessibility"[^\n]*IsAutomaticFontColor'
    rf'|oor:path="{re.escape(CMN)}/Misc"[^\n]*SymbolStyle'
    rf'|oor:path="{re.escape(TBM)}"')

stash = os.path.join(os.path.dirname(reg), 'lumen-displaced.xml')

src = open(reg, encoding='utf-8').read()
kept, evicted = [], []
for ln in src.splitlines():
    if displaced.search(ln):
        evicted.append(ln)
    elif not ours.search(ln):
        kept.append(ln)

if revert:
    # Put back whatever the first apply displaced, then forget it.
    if os.path.exists(stash):
        lines = [ln for ln in open(stash, encoding='utf-8').read().splitlines() if ln.strip()]
        os.remove(stash)
elif not os.path.exists(stash):
    # Only the first apply sees the true originals; later ones are evicting
    # their own previous output, which must not overwrite the stash.
    open(stash, 'w', encoding='utf-8').write('\n'.join(evicted) + ('\n' if evicted else ''))

close = '</oor:items>'
try:
    at = next(i for i in range(len(kept) - 1, -1, -1) if close in kept[i])
except StopIteration:
    sys.exit(f'error: {reg} has no {close} — refusing to write.')

# The closing tag shares a line with the last item in LibreOffice's own output,
# so split it rather than assuming it stands alone.
head, tail = kept[at].rsplit(close, 1)
kept[at:at + 1] = ([head] if head else []) + lines + [close + tail]

open(reg, 'w', encoding='utf-8').write('\n'.join(kept) + '\n')
print(f'{"reverted" if revert else "applied"}: {len(lines)} entries')
PY

# ── UI font ───────────────────────────────────────────────────────────────
# LibreOffice takes its UI font from GTK. gtk-3.0/settings.ini already asks for
# SF Pro Text 10, but gsettings can override it via the portal, so align both.
if [[ $revert -eq 0 ]] && command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.interface font-name 'SF Pro Text 10' || true
fi

# ── Verify ────────────────────────────────────────────────────────────────
# LibreOffice rewrites this file on exit, and it drops entries it considers
# malformed *silently* — the symptom is not an error but a scheme that
# vanishes, leaving CurrentColorScheme dangling and the app crashing on the
# next start. So don't trust the write: make LibreOffice load and re-save the
# profile once, headless, and confirm the scheme is still there afterwards.
if [[ $revert -eq 0 ]]; then
  soffice --headless --terminate_after_init >/dev/null 2>&1 || true
  for _ in $(seq 20); do lo_running || break; sleep 1; done

  if grep -q '<node oor:name="Lumen" oor:op="replace">' "$reg"; then
    echo "verified: the scheme survived a LibreOffice round-trip"
  else
    echo "FAILED: LibreOffice discarded the colour scheme on exit." >&2
    echo "        Rolling back so it does not start with a dangling reference." >&2
    cp -- "$backup" "$reg"
    exit 1
  fi
fi

echo "backup: $backup"
