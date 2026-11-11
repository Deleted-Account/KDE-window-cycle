#!/usr/bin/env bash
# window-state-cycle.sh — four-step cycle on the focused window, using ONLY
# KWin's own window states. No geometry, windowmove or windowsize anywhere.
#
#   normal --1--> No Titlebar and Frame --2--> Maximize
#     ^                                        |
#     |                        3 = cancel No Titlebar and Frame
#     4 = cancel Maximize <---- maximized <-----+
#
# One run = one step. Bind it to a global shortcut and press four times:
#   System Settings -> Keyboard -> Shortcuts -> Custom Shortcuts ->
#     Global Shortcut -> Command/URL
#     Action: /path/to/window-state-cycle.sh
#
#   ./window-state-cycle.sh             walk one step (for a shortcut)
#   ./window-state-cycle.sh --loop 1    keep walking the cycle, 1s per step
#   ./window-state-cycle.sh --help
#
# Why this is "KWin native":
#   * kdotool `windowstate` writes KWin's Window.noBorder property and calls
#     Window.setMaximize(v, h) — the same states behind KWin's built-in
#     "Window No Border" (No Titlebar and Frame) and "Window Maximize" actions.
#     KWin itself decides the maximized area and keeps its restore geometry.
#   * The current step comes from KWin's D-Bus getWindowInfo(uuid)
#     (noBorder / maximizeHorizontal / maximizeVertical), NOT from a cached
#     guess, so manual changes to the window cannot desynchronise the cycle.
#   * MIN_GAP_MS drops the duplicate launch a KDE custom shortcut can fire for
#     a single key press (same guard as window-snap.sh). Set to 0 to disable.

set -euo pipefail

usage() { sed -n '2,28p' "$0"; exit "${1:-0}"; }
die() { echo "error: $*" >&2; exit 1; }

interval=0
while [ $# -gt 0 ]; do
    case "$1" in
        --loop) interval="${2:-1}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
[[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--loop needs a number of seconds"

QDBUS=${QDBUS:-qdbus}
KDOTOOL=${KDOTOOL:-kdotool}
command -v "$QDBUS" >/dev/null   || die "$QDBUS not found"
command -v "$KDOTOOL" >/dev/null || die "$KDOTOOL not found"

MIN_GAP_MS=${MIN_GAP_MS:-120}
cache=${XDG_CACHE_HOME:-$HOME/.cache}
[ -d "$cache" ] || mkdir -p "$cache"

read_state() {
    local uuid=$1 info line key val nb='' mh='' mv='' maxed=0
    info=$("$QDBUS" org.kde.KWin /KWin org.kde.KWin.getWindowInfo "$uuid" 2>/dev/null) || true
    while IFS= read -r line; do
        key=${line%%:*}
        val=${line#*: }
        case "$key" in
            noBorder)            nb=$val ;;
            maximizeHorizontal) mh=$val ;;
            maximizeVertical)   mv=$val ;;
        esac
    done <<<"$info"
    [[ "$nb" == true || "$nb" == false ]] \
        || die "cannot read noBorder for $uuid"
    [[ "$mh" =~ ^[0-9]+$ && "$mv" =~ ^[0-9]+$ ]] \
        || die "cannot read maximize state for $uuid"
    # KWin reports bit values (0 / 1 / 2): any non-zero means that axis is on.
    if (( mh != 0 && mv != 0 )); then maxed=1; fi
    printf '%s %d\n' "$nb" "$maxed"
}

step() {
    local uuid nb maxed state label action want_nb want_maxed
    local nb2 maxed2 ok=0 try

    uuid=$("$KDOTOOL" -q getactivewindow getwindowid %1 2>/dev/null \
           | grep -m1 -o '{[^}]*}') || true
    [ -n "$uuid" ] || die "no active window"
    read -r nb maxed <<<"$(read_state "$uuid")"

    if (( maxed )); then
        if [ "$nb" = true ]; then               # 3: cancel No Titlebar and Frame
            state='borderless + maximized'
            label='cancel No Titlebar and Frame'
            action=(--remove NO_BORDER)
            want_nb=false; want_maxed=1
        else                                    # 4: cancel Maximize
            state='maximized (with titlebar)'
            label='cancel Maximize'
            action=(--remove MAXIMIZED)
            want_nb=false; want_maxed=0
        fi
    else
        if [ "$nb" = false ]; then              # 1: No Titlebar and Frame
            state='normal'
            label='No Titlebar and Frame'
            action=(--add NO_BORDER)
            want_nb=true; want_maxed=0
        else                                    # 2: Maximize
            state='borderless'
            label='Maximize'
            action=(--add MAXIMIZED)
            want_nb=true; want_maxed=1
        fi
    fi

    "$KDOTOOL" -q windowstate "${action[@]}" "$uuid" >/dev/null

    # KWin ignores maximize on non-maximizable windows (fixed-size dialogs).
    # Verify so the cycle cannot silently get stuck repeating "Maximize".
    for (( try = 1; try <= 5; try++ )); do
        read -r nb2 maxed2 <<<"$(read_state "$uuid")"
        if [ "$nb2" = "$want_nb" ] && [ "$maxed2" = "$want_maxed" ]; then
            ok=1; break
        fi
        sleep 0.1
    done
    (( ok )) || die "KWin did not apply '${action[*]}' (window may not be maximizable)"
    printf '%s -> %s (%s %s)\n' "$state" "$label" "${action[0]}" "${action[1]}"
}

# One-shot (shortcut) mode: serialise and ignore a duplicate launch within
# MIN_GAP_MS. Loop mode runs in one process, so it needs no debounce.
if [ "$interval" = 0 ] && [ "$MIN_GAP_MS" -gt 0 ]; then
    exec 9>"$cache/window-state-cycle.lock"
    flock -n 9 || exit 0
    now_ms=${EPOCHREALTIME/./}
    now_ms=${now_ms:0:13}
    last_ms=0
    if [ -f "$cache/window-state-cycle.state" ]; then
        read -r last_ms <"$cache/window-state-cycle.state" || true
    fi
    [[ "$last_ms" =~ ^[0-9]+$ ]] || last_ms=0
    if (( now_ms - last_ms < MIN_GAP_MS )); then
        exit 0
    fi
    printf '%s\n' "$now_ms" >"$cache/window-state-cycle.state"
    exec 9>&-
fi

if [ "$interval" = 0 ]; then
    step
else
    while :; do
        step
        sleep "$interval"
    done
fi
