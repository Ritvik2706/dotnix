# Windows-only interop — sourced from .zshrc only on WSL (detected via the
# kernel name; see $IS_WSL). Cross-platform helpers such as pdf/twitch/fe live
# in functions.zsh and branch on $IS_WSL themselves.

# If the shell starts in the Windows home directory, jump to the Linux home
[[ "$PWD" == /mnt/c/Users/* ]] && cd ~

# Windows interop
alias win='cd /mnt/c/Users/Ritvik'

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
