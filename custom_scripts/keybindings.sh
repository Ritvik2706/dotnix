#!/usr/bin/env bash
set -euo pipefail

# Hyprland keybinds viewer (Wofi dmenu)
# Shows: "<mods + key>\t<action/command>"

CONFIG_FILE="$HOME/.config/hypr/hyprland/keybinds.conf"

echo "Reading from: $CONFIG_FILE" >&2

keybinds="$(
  awk '
    function trim(s){ sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    # Replace $mainMod with SUPER inside a token list (mods)
    function norm_mods(s){
      gsub(/\$mainMod/,"SUPER",s);
      gsub(/[[:space:]]+/," ",s);
      return trim(s)
    }
    # Turn tokens like "H, movefocus, l" into pretty columns
    function join_args(arr, start,   out,i){
      out=""
      for(i=start;i in arr;i++){
        if(out!="") out=out ", "
        out=out trim(arr[i])
      }
      return out
    }

    BEGIN{ FS="=" }

    # Keep lines that start with bind/bindl/bindel (ignore commented ones)
    /^[ \t]*bind([a-z]*)[ \t]*=/{
      line=$0

      # Strip trailing comments
      sub(/#.*/,"", line)

      # Right side of the = is the bind spec
      spec=line; sub(/^[^=]*=/,"", spec)

      # Now split by commas
      n=split(spec, a, ",")
      for(i=1;i<=n;i++) a[i]=trim(a[i])

      mods = norm_mods(a[1])
      key  = (n>=2 ? a[2] : "")
      act  = (n>=3 ? a[3] : "")
      rest = (n>=4 ? join_args(a,4) : "")

      # Pretty action text
      if (tolower(act) == "exec") {
        action = rest
      } else if (rest != "") {
        action = act " " rest
      } else {
        action = act
      }

      # Normalize arrows a bit (optional)
      gsub(/\<</,"«", key); gsub(/\>\>/,"»", key)

      printf "%-24s\t%s\n", mods " + " key, action
    }
  ' "$CONFIG_FILE"
)"

# Show in Vicinae (dmenu mode): renders the list from stdin and prints the
# chosen line to stdout, same contract as the old `wofi --dmenu`.
choice="$(printf "%s\n" "$keybinds" | vicinae dmenu --placeholder 'Keybinds' --no-section)"

# Optional: copy action (right column) to clipboard
# action="${choice#*$'\t'}"
# [ -n "${action:-}" ] && printf %s "$action" | wl-copy

