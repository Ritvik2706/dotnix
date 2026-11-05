#!/usr/bin/env bash
# project.sh — one workspace per project, the niri way.
#   project.sh pick        (Mod+A) a floating fzf picker over `sesh list`
#   project.sh open <sel>  the terminal it is attached in, if it is; else the
#                          terminal already on tmux switches to it (sesh
#                          --switch); else a new terminal attached to it
#   project.sh list        for a picker (the lumen island): one project per line,
#                          TSV: name, what to pass to `open`, kind (tmux, config,
#                          zoxide), path, 1 if it has a workspace open now
#   project.sh close       (Mod+Shift+A) drop the focused workspace's name; once
#                          its windows are gone niri removes it like any other
# Everything else for that project (editor, browser, docs) opens beside that
# terminal as more columns, so a project is one strip you scroll through.
set -euo pipefail

SELF=$(readlink -f "$0")

name_of() {
	# "~/github/config/dotnix" -> "dotnix"; tmux session names stay as they are.
	local n=${1%/}
	n=${n##*/}
	printf '%s' "${n:-$1}"
}

HOMES='^(browser|terminal|docs|tools|media|TV [7890])$'

# The niri window a tmux session is attached in (its client's terminal), or nothing: a
# client's process, up its parents, to the one a window belongs to.
window_of() {
	local wins=$1 sess=$2 p id
	for p in $(tmux list-clients -t "$sess" -F '#{client_pid}' 2>/dev/null); do
		for _ in 1 2 3 4 5 6 7 8; do
			p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
			[[ -z $p || $p == 1 ]] && break
			id=$(jq -r --argjson p "$p" '[.[] | select(.pid == $p)] | first | .id // empty' <<<"$wins")
			if [[ -n $id ]]; then
				printf '%s' "$id"
				return
			fi
		done
	done
}

# A project's workspace whose terminal was closed keeps its name (niri keeps named
# workspaces): its name goes, and niri drops it once it is empty like any other.
tidy() {
	local spaces=$1 wins=$2 n
	jq -r --argjson w "$wins" --arg homes "$HOMES" '
		.[] | select(.name != null and (.name | test($homes) | not) and (.is_focused | not))
		| select(.id as $i | all($w[]; .workspace_id != $i)) | .name' <<<"$spaces" |
		while read -r n; do niri msg action unset-workspace-name "$n" >/dev/null 2>&1 || true; done
}

case ${1:-pick} in
pick)
	# Its own instance so the window rule can find it by app id.
	exec ghostty --class=dev.niri.project-picker --title="Projects" -e bash -lc "
		sel=\$(sesh list --icons | fzf --ansi --no-sort --prompt='  ' \
			--border-label ' projects ' --header '  ^a all ^t tmux ^g configs ^x zoxide' \
			--bind 'tab:down,btab:up' \
			--bind 'ctrl-a:change-prompt(  )+reload(sesh list --icons)' \
			--bind 'ctrl-t:change-prompt(  )+reload(sesh list -t --icons)' \
			--bind 'ctrl-g:change-prompt(  )+reload(sesh list -c --icons)' \
			--bind 'ctrl-x:change-prompt(  )+reload(sesh list -z --icons)' \
			--preview-window 'right:50%' --preview 'sesh preview {}') || exit 0
		# Drop the icon column sesh puts in front.
		sel=\${sel#* }
		setsid -f '$SELF' open \"\$sel\" >/dev/null 2>&1
	"
	;;
list)
	spaces=$(niri msg -j workspaces)
	wins=$(niri msg -j windows)
	tidy "$spaces" "$wins"
	# Open: a workspace of its name with windows on it, or its tmux session attached in a terminal.
	open=$(jq -c --argjson w "$wins" '[.[] | select(.name != null) | select(.id as $i | any($w[]; .workspace_id == $i)) | .name]' <<<"$spaces")
	attached=$(tmux list-clients -F '#{session_name}' 2>/dev/null | sort -u | jq -R . | jq -sc .)
	# Same naming as `open` (name_of), done in jq: the last path component.
	sesh list --json | jq -r --argjson open "$open" --argjson att "${attached:-[]}" '
		.[] | (.Name | rtrimstr("/") | split("/") | last) as $n
		| [$n, .Name, .Src, (.Path // ""), (if (($open | index($n)) or ($att | index($n))) then 1 else 0 end)] | @tsv'
	;;
open)
	sel=$2
	name=$(name_of "$sel")
	spaces=$(niri msg -j workspaces)
	wins=$(niri msg -j windows)

	# Its session already attached in a terminal (the one on "terminal", say): that window.
	win=$(window_of "$wins" "$name")
	if [[ -n $win ]]; then
		niri msg action focus-window --id "$win"
		exit 0
	fi

	# Otherwise the terminal already on tmux (the one used last: the one on "terminal") switches
	# to it, as sesh does inside tmux, and gets the focus: no new window, no new workspace. The
	# session it leaves keeps running.
	last=$(tmux list-clients -F '#{client_activity} #{session_name}' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
	if [[ -n $last ]]; then
		cwin=$(window_of "$wins" "$last")
		sesh connect --switch "$sel" >/dev/null 2>&1
		[[ -n $cwin ]] && niri msg action focus-window --id "$cwin"
		exit 0
	fi

	# No terminal on tmux at all: a terminal attached to it (the window rules put it on "terminal").
	setsid -f ghostty -e sesh connect "$sel" >/dev/null 2>&1
	;;
close)
	name=$(niri msg -j workspaces | jq -r '.[] | select(.is_focused) | .name // ""')
	# The fixed homes (conf/workspaces.kdl) keep their names.
	if [[ -z $name || $name =~ $HOMES ]]; then
		exit 0
	fi
	niri msg action unset-workspace-name
	notify-send -a Niri -t 1500 "Project closed" "$name: the workspace goes once it's empty"
	;;
*)
	echo "usage: ${0##*/} pick|open <project>|close" >&2
	exit 2
	;;
esac
