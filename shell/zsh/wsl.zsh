# WSL-specific configuration — sourced only when WSL_DISTRO_NAME is set.

# If the shell starts in the Windows home directory, jump to the Linux home
[[ "$PWD" == /mnt/c/Users/* ]] && cd ~

# Windows interop
alias win='cd /mnt/c/Users/Ritvik'
fe() { "/mnt/c/Program Files/OneCommander/OneCommander.exe" "${@:-.}" &>/dev/null & disown; }

# winget — strips Windows CR characters that corrupt WSL terminal output
winget() { winget.exe "$@" | tr -d '\r'; }

# Shortcuts
alias wgu='winget upgrade --all'        # upgrade everything
alias wgs='winget search'               # quick search
alias wgi='winget install'              # quick install

# WinUtil — Chris Titus Tech's Windows utility
# Run 'winutil-setup' once (needs UAC that one time) to register a no-UAC scheduled task
winutil-setup() {
  # Encode the registration command as UTF-16LE base64 — avoids temp files and execution policy issues
  local ps_cmd
  ps_cmd=$(cat << 'PSEOF'
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -Command "irm christitus.com/win | iex"'
Register-ScheduledTask -TaskName "WinUtil" -Action $a -RunLevel Highest -Force
PSEOF
)
  local encoded
  encoded=$(printf '%s' "$ps_cmd" | iconv -t UTF-16LE | base64 -w 0)
  powershell.exe -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-EncodedCommand $encoded'"
  echo "winutil-setup: done — use 'winutil' from now on."
}

winutil() {
  schtasks.exe /run /tn "WinUtil" > /dev/null
}

# Hardware acceleration (Intel iHD driver in WSL)
export LIBVA_DRIVER_NAME=iHD
export MOZ_DISABLE_RDD_SANDBOX=1
export MOZ_X11_EGL=1
export XDG_SESSION_TYPE=wayland

# Watch a Twitch stream via Streamlink + mpv on the Windows side.
#   twitch <name>   stream that channel (and record it as recently watched)
#   twitch          fzf picker over recently watched (vim keys: j/k, ctrl-d/u);
#                   pick an entry, or type a new name and press enter
twitch() {
  local streamlink="/mnt/c/Program Files/Streamlink/bin/streamlink.exe"
  local player="C:\\Program Files (x86)\\mpv\\mpv.exe"
  local recent="${XDG_DATA_HOME:-$HOME/.local/share}/twitch-recent"

  if [[ ! -x "$streamlink" ]]; then
    echo "twitch: Streamlink not found at: $streamlink"
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

  "$streamlink" --player "$player" "https://twitch.tv/$channel" best &>/dev/null &
  disown
}

# Open PDFs with Sioyek on the Windows side; no args = fzf picker
pdf() {
  local exe="/mnt/c/Users/Ritvik/AppData/Local/Programs/Sioyek/sioyek.exe"
  if [[ ! -x "$exe" ]]; then
    echo "pdf: Sioyek not found at: $exe"
    return 1
  fi
  if [[ $# -eq 0 ]]; then
    local file
    file=$(find . -iname "*.pdf" 2>/dev/null | fzf --prompt="PDF> " --height=40% --layout=reverse --border)
    [[ -z "$file" ]] && return 0
    "$exe" "$(wslpath -w "$(realpath "$file")")" &>/dev/null &
    disown
    return
  fi
  local f
  for f in "$@"; do
    if [[ ! -f "$f" ]]; then
      echo "pdf: file not found: $f"
      continue
    fi
    "$exe" "$(wslpath -w "$(realpath "$f")")" &>/dev/null &
    disown
  done
}
