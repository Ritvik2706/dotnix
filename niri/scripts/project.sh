#!/usr/bin/env bash
# project.sh — one workspace per project, the niri way.
#   project.sh pick        (Mod+A) a floating fzf picker over `sesh list`
#   project.sh open <sel>  jump to the project's workspace, or make it: the
#                          next empty workspace, named after the project, with
#                          a terminal attached to its tmux session (sesh)
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
	# Same naming as `open` (name_of), done in jq: the last path component.
	open=$(niri msg -j workspaces | jq -c '[.[] | .name // empty]')
	sesh list --json | jq -r --argjson open "$open" '
		.[] | (.Name | rtrimstr("/") | split("/") | last) as $n
		| [$n, .Name, .Src, (.Path // ""), (if ($open | index($n)) then 1 else 0 end)] | @tsv'
	;;
open)
	sel=$2
	name=$(name_of "$sel")
	spaces=$(niri msg -j workspaces)

	if jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$spaces" >/dev/null; then
		niri msg action focus-workspace "$name"
		exit 0
	fi

	# niri always keeps one empty workspace at the bottom of each monitor:
	# claim the focused monitor's.
	out=$(niri msg -j focused-output | jq -r '.name')
	wins=$(niri msg -j windows)
	idx=$(jq -r --arg o "$out" --argjson w "$wins" '
		[.[] | select(.output == $o and .name == null) | select(.id as $i | all($w[]; .workspace_id != $i))]
		| max_by(.idx) | .idx // empty' <<<"$spaces")
	[[ -z $idx ]] && idx=$(jq -r --arg o "$out" '[.[] | select(.output == $o)] | max_by(.idx) | .idx + 1' <<<"$spaces")

	niri msg action focus-workspace "$idx"
	niri msg action set-workspace-name "$name"
	setsid -f ghostty -e sesh connect "$sel" >/dev/null 2>&1
	notify-send -a Niri -t 1500 "Project" "$name"
	;;
close)
	name=$(niri msg -j workspaces | jq -r '.[] | select(.is_focused) | .name // ""')
	if [[ -z $name ]]; then
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
