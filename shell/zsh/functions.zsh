# Shell functions — cross-platform. WSL branches on $IS_WSL (set in .zshrc);
# purely-Windows helpers (winget, winutil, …) live in wsl.zsh instead.

# Open PDFs — Sioyek on the Windows side under WSL, a native viewer otherwise.
# No args = fzf picker over *.pdf below the current directory.
pdf() {
  local -a files
  if [[ $# -eq 0 ]]; then
    local picked
    picked=$(find . -iname "*.pdf" 2>/dev/null | fzf --prompt="PDF> " --height=40% --layout=reverse --border)
    [[ -z "$picked" ]] && return 0
    files=("$picked")
  else
    local f
    for f in "$@"; do
      if [[ ! -f "$f" ]]; then
        echo "pdf: file not found: $f"
        continue
      fi
      files+=("$f")
    done
  fi
  (( ${#files[@]} == 0 )) && return 0

  local f
  if [[ -n "$IS_WSL" ]]; then
    local exe="/mnt/c/Users/Ritvik/AppData/Local/Programs/Sioyek/sioyek.exe"
    if [[ ! -x "$exe" ]]; then
      echo "pdf: Sioyek not found at: $exe"
      return 1
    fi
    for f in "${files[@]}"; do
      "$exe" "$(wslpath -w "$(realpath "$f")")" &>/dev/null &
      disown
    done
  else
    # Native: prefer sioyek for parity with Windows, then zathura, then xdg-open.
    local viewer
    for viewer in sioyek zathura xdg-open; do
      if command -v "$viewer" &>/dev/null; then
        for f in "${files[@]}"; do
          "$viewer" "$(realpath "$f")" &>/dev/null &
          disown
        done
        return
      fi
    done
    echo "pdf: no PDF viewer found (install sioyek or zathura)"
    return 1
  fi
}

# Watch a Twitch stream via Streamlink + mpv.
#   twitch <name>   stream that channel (and record it as recently watched)
#   twitch          fzf picker over recently watched (vim keys: j/k, ctrl-d/u);
#                   pick an entry, or type a new name and press enter
twitch() {
  local streamlink player
  if [[ -n "$IS_WSL" ]]; then
    # Windows-side binaries; player needs a Windows-style path.
    streamlink="/mnt/c/Program Files/Streamlink/bin/streamlink.exe"
    player="C:\\Program Files (x86)\\mpv\\mpv.exe"
  else
    streamlink="$(command -v streamlink)"
    player="$(command -v mpv)"   # may be empty — Streamlink defaults to mpv
  fi
  local recent="${XDG_DATA_HOME:-$HOME/.local/share}/twitch-recent"

  if [[ -z "$streamlink" || ! -x "$streamlink" ]]; then
    echo "twitch: Streamlink not found${streamlink:+ at: $streamlink}"
    return 1
  fi

  local channel="$1"

  # No channel given — let fzf pick from the recently watched list.
  if [[ -z "$channel" ]]; then
    if [[ ! -s "$recent" ]]; then
      echo "twitch: no recent channels yet — try 'twitch <name>'"
      return 1
    fi
    channel=$(fzf --prompt="twitch> " --height=40% --layout=reverse --border \
                  --print-query --bind='j:down,k:up,ctrl-d:half-page-down,ctrl-u:half-page-up' \
                  < "$recent" | tail -n1)
    [[ -z "$channel" ]] && return 0
  fi

  # Strip a full URL down to the bare channel name if one was pasted.
  channel="${channel##*/}"

  # Record as most-recent: drop any existing entry, prepend, keep newest first.
  touch "$recent"
  local tmp
  tmp=$(mktemp)
  { echo "$channel"; grep -vxF "$channel" "$recent"; } > "$tmp" && mv "$tmp" "$recent"

  local -a player_arg
  [[ -n "$player" ]] && player_arg=(--player "$player")
  "$streamlink" "${player_arg[@]}" "https://twitch.tv/$channel" best &>/dev/null &
  disown
}

# Open a graphical file manager at the given path (default: current directory).
# OneCommander on the Windows side under WSL; the system default otherwise.
fe() {
  if [[ -n "$IS_WSL" ]]; then
    "/mnt/c/Program Files/OneCommander/OneCommander.exe" "${@:-.}" &>/dev/null & disown
  else
    xdg-open "${1:-.}" &>/dev/null & disown
  fi
}
