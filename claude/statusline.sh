#!/usr/bin/env bash
# Claude Code status line: glass chips that match the tmux bar.
# Hex colours come from the wallpaper theme (theme/wallpaper-theme.py writes
# ~/.cache/lumen/term/{tmux.conf,zsh}); greys/red/yellow are ANSI names so they
# follow ghostty's wall-colours. Read on every render, so Mod+P re-themes it.
export LC_ALL=C.UTF-8

in=$(cat)
cache=${XDG_RUNTIME_DIR:-/tmp}/claude-statusline
mkdir -p "$cache"
printf '%s' "$in" >"$cache/last.json" # handy for debugging new fields

# ── vim cursor shape, FIRST so the mode switch is as quick as possible ───
# Claude Code never sets the cursor shape, so do it like zsh-vi-mode (blinking
# bar in insert, block in normal). Our stdout is captured, so the escape goes
# straight to the Claude process's terminal, once per change. No jq here: a
# plain match on the input keeps this to a few ms.
if [[ $in =~ \"vim\":\{\"mode\":\"([A-Z]+)\" ]]; then
  [[ ${BASH_REMATCH[1]} == INSERT ]] && shape=5 || shape=2
  pf=$cache/cursor-$PPID
  read -r last tty 2>/dev/null <"$pf"
  if [[ -z $tty ]]; then
    pid=$PPID
    while ((pid > 1)) && [[ $(readlink "/proc/$pid/exe" 2>/dev/null) != */claude* ]]; do
      read -r _ _ _ pid _ <"/proc/$pid/stat" 2>/dev/null || break
    done
    tty=$(readlink "/proc/$pid/fd/1" 2>/dev/null)
  fi
  if [[ $last != "$shape" && $tty == /dev/pts/* && -w $tty ]]; then
    printf '\e[%s q' "$shape" >"$tty"
    echo "$shape $tty" >"$pf"
  fi
fi

# ── theme ────────────────────────────────────────────────────────────────
term=$HOME/.cache/lumen/term
opt() { sed -n "s/^set -g @t_$1 '\(#[0-9a-fA-F]*\)'.*/\1/p" "$term/tmux.conf" 2>/dev/null; }
accent=$(opt accent); chip=$(opt chip); quiet=$(opt quiet); rule=$(opt rule)
: "${accent:=#96b9ff}" "${chip:=#32445c}" "${quiet:=#233349}" "${rule:=#364157}"

hex() { local h=${1#\#}; printf '%d;%d;%d' 0x${h:0:2} 0x${h:2:2} 0x${h:4:2}; }
fg() { printf '\e[38;2;%sm' "$(hex "$1")"; }
bg() { printf '\e[48;2;%sm' "$(hex "$1")"; }
R=$'\e[0m'; DIM=$'\e[90m'; TXT=$'\e[37m'; HI=$'\e[97m'; RED=$'\e[31m'; YEL=$'\e[33m'
CL=$'\ue0b6'; CR=$'\ue0b4' # rounded chip caps (same as tmux)
SEP=" $(fg "$rule")·$R "

# chip BG FG TEXT — a rounded glass pill
chip() { printf '%s%s%s%s%s%s ' "$(fg "$1")" "$CL" "$(bg "$1")" "$2" "$3" "$R$(fg "$1")$CR$R"; }

j() { jq -r "$1 // empty" <<<"$in" 2>/dev/null; }


# ── model (vim mode is already shown by Claude Code under the prompt) ────
out=""
model=$(j .model.display_name); model=${model#Claude }
effort=$(j .effort.level)
agent=$(j .agent.name)
m="$HI$model"
[[ -n $effort ]] && m+=" $(fg "$accent")$effort"
[[ -n $agent ]] && m+=" $TXT@$agent"
out+=$(chip "$quiet" "" "$m")

# ── place: dir + git ─────────────────────────────────────────────────────
cwd=$(j .workspace.current_dir); [[ -z $cwd ]] && cwd=$(j .cwd); : "${cwd:=$PWD}"
if [[ $cwd == "$HOME" ]]; then d="~"; else d=${cwd##*/}; fi
out+="$(fg "$accent")"$'\uf07c'"$R $DIM$d$R"

# git status is cached per directory for a few seconds (refreshInterval reruns us)
key=$(printf '%s' "$cwd" | md5sum | cut -c1-12)
gf=$cache/git-$key
if [[ ! -f $gf || $(($(date +%s) - $(stat -c %Y "$gf"))) -ge 4 ]]; then
  git -C "$cwd" --no-optional-locks status --porcelain=v2 --branch 2>/dev/null >"$gf.tmp"
  mv -f "$gf.tmp" "$gf"
fi
if [[ -s $gf ]]; then
  branch=$(sed -n 's/^# branch.head //p' "$gf")
  read -r ahead behind < <(sed -n 's/^# branch.ab +\([0-9]*\) -\([0-9]*\)/\1 \2/p' "$gf")
  dirty=$(grep -vc '^#' "$gf")
  conflicts=$(grep -c '^u ' "$gf")
  g=" $DIM"$'\ue0a0'" $TXT$branch$R"
  ((${ahead:-0})) && g+=" $(fg "$accent")↑$ahead$R"
  ((${behind:-0})) && g+=" $YEL↓$behind$R"
  ((conflicts)) && g+=" $RED✖$conflicts$R"
  ((dirty)) && g+=" $(fg "$accent")● $DIM$dirty$R"
  out+=$g
fi
pr=$(j .pr.number); [[ -n $pr ]] && out+=" $(fg "$accent")#$pr$R"

# ── meters: each one a quiet glass chip with a readable label + bold value
B=$'\e[1m'
level() { if (($1 >= 80)); then printf '%s' "$RED"; elif (($1 >= 60)); then printf '%s' "$YEL"; else printf '%s' "$HI"; fi; }

pct=$(j .context_window.used_percentage)
if [[ -n $pct ]]; then
  p=${pct%.*}; ((p > 100)) && p=100
  c=$(level "$p"); ((p < 60)) && c=$(fg "$accent")
  ctx="${TXT}ctx $B$c$p%$R"
  ((p >= 80)) && ctx+=" ${YEL}/compact$R"
  ctx+="  "
fi

use=""
for w in five_hour seven_day; do
  u=$(j ".rate_limits.$w.used_percentage"); [[ -z $u ]] && continue
  u=${u%.*}
  label=${w/five_hour/5h}; label=${label/seven_day/7d}
  t="$TXT$label $B$(level "$u")$u%$R"
  r=$(j ".rate_limits.$w.resets_at")
  [[ -n $r && ! $r =~ ^[0-9]+$ ]] && r=$(date -d "$r" +%s 2>/dev/null)
  if [[ -n $r ]]; then
    if [[ $w == five_hour ]]; then t+="$(bg "$quiet")$DIM  "$''" $TXT$(date -d "@$r" +%H:%M)"
    elif ((u >= 60)); then t+="$(bg "$quiet")$DIM  "$''" $TXT$(date -d "@$r" +%a)"; fi
  fi
  use+=$(chip "$quiet" "" "$t$(bg "$quiet")")
done
if [[ -z $use && -z $(j .rate_limits) ]]; then
  cost=$(j .cost.total_cost_usd)
  [[ -n $cost ]] && use=$(chip "$quiet" "" "$TXT\$$B$HI$(printf '%.2f' "$cost")")
fi

# ── session: churn + wall time (plain text, it's the least important) ────
add=$(j .cost.total_lines_added); del=$(j .cost.total_lines_removed)
ms=$(j .cost.total_duration_ms)
s=""
((${add:-0} || ${del:-0})) && s+="$(fg "$accent")+${add:-0} $RED-${del:-0}$R"
if [[ -n $ms ]]; then
  t=$((ms / 60000))
  ((t >= 60)) && t="$((t / 60))h$((t % 60))m" || t="${t}m"
  s+="${s:+  }$TXT$t$R"
fi

# ── layout: identity left, meters right (like the tmux bar) ──────────────
vis() { local t; t=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$1"); printf '%d' "${#t}"; }
width=$(( ${COLUMNS:-0} - 4 )) # Claude Code indents the status row
join() { local r="" x; for x in "$@"; do r+="$x"; done; r=${r% }; printf '%s' "$r"; }
right=$(join "$ctx" "$use" "${s:+ $s}")
if ((width > 0)); then
  # drop the least useful meters first when the pane is narrow
  (( $(vis "$out$right") + 2 > width )) && right=$(join "$ctx" "$use")
  (( $(vis "$out$right") + 2 > width )) && right=$(join "$use")
  out=${out% }
  gap=$(( width - $(vis "$out") - $(vis "$right") ))
  ((gap < 2)) && gap=2
  printf '%s%*s%s' "$out" "$gap" "" "$right"
else
  printf '%s %s' "${out% }" "$right"
fi
