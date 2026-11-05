#!/usr/bin/env bash
# niri-patched.sh — keeps the patched niri (~/.local/bin/niri) working across
# system updates, without anyone having to open a TTY.
#
#   niri-patched.sh check [BIN]   is BIN (default: the installed patched build)
#                                 able to start with this config? prints why not
#   niri-patched.sh auto          what the pacman hook and the launcher run:
#                                 nothing if all is well; rebuild when a library
#                                 update broke the binary; re-apply the patches
#                                 onto a newer niri when Arch shipped one
#   niri-patched.sh build         rebuild the patches as they are, install
#   niri-patched.sh update        re-apply the patches onto the niri Arch ships
#   niri-patched.sh fallback WHY  (from niri-launch.sh, inside a stock-niri
#                                 session) say so, then `auto`
#
# The patches: ~/github/projects/niri, branch dotnix-patches (one commit per
# feature on top of a release tag), also exported to dotnix/niri/patches/.
# Installs are atomic: build, verify, then swap in, keeping the last good
# build as niri.prev. Nothing here touches a running niri; a new build takes
# over the next time niri starts, and the notification offers to restart niri
# in place (lumen-session restarts it in the same login, apps restored).
set -uo pipefail

SRC=${NIRI_PATCHED_SRC:-$HOME/github/projects/niri}
BRANCH=dotnix-patches
BIN=$HOME/.local/bin/niri
STOCK=/usr/bin/niri
CONFIG=$HOME/.config/niri/config.kdl
PATCHES=$HOME/github/config/dotnix/niri/patches
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/niri-patched
RUN=${XDG_RUNTIME_DIR:-/run/user/$UID}
mkdir -p "$STATE"

log() { printf '%s\n' "$*"; systemd-cat -t niri-patched -p info echo "$*" 2>/dev/null || true; }

# A notification, with a "Restart niri now" button when a new build is
# waiting and the session can restart niri in place. Never blocks the caller.
notify() { # notify URGENCY TITLE BODY [offer-restart]
	local urg=$1 title=$2 body=$3 offer=${4:-}
	if [[ -n $offer ]] && pgrep -u "$UID" -f 'dotnix/system/lumen-session' >/dev/null; then
		setsid -f bash -c '
			a=$(notify-send -a niri -u "$1" -A restart="Restart niri now" -w "$2" "$3" 2>/dev/null)
			[[ $a == restart ]] && exec "$4" restart-niri' _ "$urg" "$title" "$body" "$0" >/dev/null 2>&1
	else
		notify-send -a niri -u "$urg" "$title" "$body" 2>/dev/null || true
	fi
}

# ── health ────────────────────────────────────────────────────────────────
# Can BIN start? Every library present, every symbol resolvable (LD_BIND_NOW
# makes a missing one fail here, not mid-session), and it accepts the config.
check() { # check BIN -> prints the problem, returns 1
	local b=$1 missing
	[[ -x $b ]] || { echo "$b is missing"; return 1; }
	missing=$(ldd "$b" 2>/dev/null | awk '/not found/ {print $1}' | tr '\n' ' ')
	[[ -z $missing ]] || { echo "libraries gone after an update: $missing"; return 1; }
	LD_BIND_NOW=1 timeout 10 "$b" --version >/dev/null 2>&1 || { echo "it no longer loads (a library changed under it)"; return 1; }
	timeout 10 "$b" validate -c "$CONFIG" >/dev/null 2>&1 || { echo "it rejects the config"; return 1; }
	return 0
}

base_tag() { git -C "$SRC" describe --tags --abbrev=0 "$BRANCH" 2>/dev/null; }
# The niri release Arch has installed, as an upstream tag (26.04-1 -> v26.04).
arch_tag() { local v; v=$(pacman -Q niri 2>/dev/null | awk '{print $2}') || return 1; v=${v%-*}; v=${v#*:}; echo "v$v"; }

# ── build & install ───────────────────────────────────────────────────────
# cargo build in DIR, verify the result, install it atomically.
build_install() { # build_install DIR LABEL
	local dir=$1 label=$2 out why
	log "building $label"
	# Offline first (same sources, new libraries: the common case), then online.
	( cd "$dir" && nice -n 10 cargo build --release --locked --offline ) >"$STATE/build.log" 2>&1 \
		|| ( cd "$dir" && nice -n 10 cargo build --release --locked ) >>"$STATE/build.log" 2>&1 \
		|| { log "build failed ($label), see $STATE/build.log"; return 1; }
	out=$dir/target/release/niri
	why=$(check "$out") || { log "new build is unusable: $why"; return 1; }
	cp -f "$out" "$BIN.new" && chmod +x "$BIN.new" || return 1
	[[ -x $BIN ]] && check "$BIN" >/dev/null && cp -f "$BIN" "$BIN.prev"
	mv -f "$BIN.new" "$BIN"
	rm -f "$STATE/crashed"
	log "installed $label"
}

cmd_build() {
	exec 9>"$STATE/lock"; flock -n 9 || { log "already running"; return 0; }
	[[ $(git -C "$SRC" branch --show-current) == "$BRANCH" ]] || { log "$SRC is not on $BRANCH; not building"; return 1; }
	build_install "$SRC" "$(base_tag) + patches"
}

# Re-apply the patch commits onto TAG in a scratch worktree; only once they
# apply, build and pass the check does the branch move (the old one is kept as
# dotnix-patches-<old tag>). Conflicts leave everything as it was.
cmd_update() {
	exec 9>"$STATE/lock"; flock -n 9 || { log "already running"; return 0; }
	local old new wt
	old=$(base_tag) new=${1:-$(arch_tag)}
	[[ -n $old && -n $new ]] || { log "can't tell the versions"; return 1; }
	[[ $old == "$new" ]] && { log "patches already on $new"; return 0; }
	git -C "$SRC" rev-parse -q --verify "refs/tags/$new" >/dev/null \
		|| git -C "$SRC" fetch -q origin tag "$new" --no-tags 2>>"$STATE/build.log" \
		|| { log "couldn't fetch $new (offline?)"; return 2; }
	wt=$STATE/worktree
	git -C "$SRC" worktree remove -f "$wt" >/dev/null 2>&1; rm -rf "$wt"
	git -C "$SRC" worktree add -q -f --detach "$wt" "$new" || return 1
	if ! git -C "$wt" cherry-pick "$old..$BRANCH" >"$STATE/rebase.log" 2>&1; then
		local where
		where=$(git -C "$wt" diff --name-only --diff-filter=U | tr '\n' ' ')
		git -C "$wt" cherry-pick --abort >/dev/null 2>&1
		git -C "$SRC" worktree remove -f "$wt" >/dev/null 2>&1
		log "patches don't apply cleanly on $new (conflicts in: $where)"
		return 3
	fi
	# Reuse the main build cache: only what changed recompiles.
	CARGO_TARGET_DIR=$SRC/target build_install "$wt" "$new + patches" || {
		git -C "$SRC" worktree remove -f "$wt" >/dev/null 2>&1; return 1; }
	git -C "$SRC" branch -f "$BRANCH-$old" "$BRANCH"
	git -C "$SRC" branch -f "$BRANCH" "$(git -C "$wt" rev-parse HEAD)"
	git -C "$SRC" worktree remove -f "$wt" >/dev/null 2>&1
	# The checkout follows the branch only if it had nothing uncommitted.
	git -C "$SRC" diff --quiet && git -C "$SRC" diff --cached --quiet \
		&& git -C "$SRC" checkout -q -f "$BRANCH"
	rm -f "$PATCHES"/*.patch
	git -C "$SRC" format-patch -q --no-signature -o "$PATCHES" "$new..$BRANCH"
	rm -f "$STATE"/needs-rebase-*
	log "patches moved from $old to $new"
}

# ── auto ──────────────────────────────────────────────────────────────────
cmd_auto() {
	local why rc new
	new=$(arch_tag)
	if [[ -n $new && $new != "$(base_tag)" && ! -e $STATE/needs-rebase-$new ]]; then
		cmd_update "$new"; rc=$?
		case $rc in
			0) notify normal "niri $new, with your patches" \
				"Your patches were re-applied to the new niri and the build checks out. It takes over the next time niri starts." offer
				return 0 ;;
			3) : >"$STATE/needs-rebase-$new"
				notify normal "niri $new: patches need a hand" \
					"Your patches don't apply cleanly to $new, so you stay on $(base_tag) + patches (it still works). Ask Claude to rebase dotnix-patches onto $new." ;;
			2) ;;   # offline: try again after the next update
			*) notify normal "niri $new: rebuild failed" \
					"Staying on $(base_tag) + patches. Build log: $STATE/build.log" ;;
		esac
	fi
	# Broken if it fails the check, or if this very build (same mtime) crashed
	# while starting last time (niri-launch.sh records that).
	if why=$(check "$BIN"); then
		[[ -e $STATE/crashed && $(<"$STATE/crashed") == "$(stat -c %Y "$BIN" 2>/dev/null)" ]] || return 0
		why="it crashed while starting"
	fi
	log "patched niri unusable: $why — rebuilding"
	if cmd_build; then
		notify normal "Patched niri rebuilt" \
			"It had broken ($why). The new build checks out and takes over the next time niri starts." offer
	else
		notify critical "Patched niri needs attention" \
			"It broke ($why) and rebuilding didn't fix it. You'll keep getting stock niri (plain borders) until it's fixed. Build log: $STATE/build.log — ask Claude."
	fi
}

cmd_fallback() {
	local why=${1:-unknown}
	notify normal "Running stock niri" \
		"The patched build couldn't start ($why), so this session is stock niri: everything works, borders are plain. Fixing it in the background…"
	cmd_auto
}

# Restart niri in place under lumen-session: apps are saved and restored, the
# session stays unlocked (the same path as the island's compositor switch).
cmd_restart_niri() {
	pidof -q hyprlock && return 1
	"$HOME/.config/lumen/shells/island/scripts/restore-apps.sh" save 2>/dev/null
	printf 'niri\n' >"$RUN/lumen-switch"
	niri msg action quit --skip-confirmation
}

case ${1:-} in
	check) why=$(check "${2:-$BIN}") && echo ok || { echo "$why"; exit 1; } ;;
	auto) exec 8>"$STATE/auto.lock"; flock -n 8 || exit 0; cmd_auto ;;
	build) cmd_build ;;
	update) cmd_update "${2:-}" ;;
	fallback) cmd_fallback "${2:-}" ;;
	restart-niri) cmd_restart_niri ;;
	*) sed -n '2,17p' "$0"; exit 2 ;;
esac
