#!/usr/bin/env bash
# window-snap.sh — snap the focused (or specified) window to a fixed size/position.
#
# KWin's frameGeometry is in LOGICAL (scaled) pixels. E.g. on a 7680x2160
# display at 150% scale the logical screen is 5120x1440. This script converts
# the requested physical size to logical pixels automatically.
#
# Usage:
#   ./window-snap.sh --center --noToggle  center 3840x2160  (logical 2560x1440)
#   ./window-snap.sh --left             1920 -> 1280 -> 2560 -> 3840, flush left
#   ./window-snap.sh --right            same cycle, flush right
#   ./window-snap.sh --full              fill the whole screen
#   ./window-snap.sh --center --noTitleBar  also hide the title bar
#   ./window-snap.sh --active --toggle   hotkey: 3840 <-> 2560 wide (center)
#                                        (toggle is ON by default)
#   ./window-snap.sh --active --noToggle hotkey: fixed PW width
#   PW=2560 PH=1440 ./window-snap.sh --center   override physical size
#   PID=12345 ./window-snap.sh --center  target a specific process
#   ./window-snap.sh --center --watch 5  keep re-applying for 5 seconds
#   SIDE_CYCLE='1920 1280 2560 3840' / MIN_GAP_MS=100 / SCREEN_TTL=60 tunable
#
# Bind to a global shortcut:
#   System Settings -> Keyboard -> Shortcuts -> Custom Shortcuts -> New ->
#   Global Shortcut -> Command/URL
#   Action: /path/to/window-snap.sh --active --toggle

set -u -o pipefail

die() { echo "error: $*"; exit 1; }
ri() { [ -n "${1:-}" ] && printf '%.0f' "$1"; }

PW_GIVEN=0
[ -n "${PW:-}" ] && PW_GIVEN=1
PW="${PW:-3840}"
PH="${PH:-2160}"
TW1="${TW1:-3840}"        # center cycle: width A (physical px)
TW2="${TW2:-2560}"        # center cycle: width B
SIDE_CYCLE="${SIDE_CYCLE:-1920 1280 2560 3840}"  # left/right cycle, physical px
DELAY="${DELAY:-0.35}"          # wait after NO_BORDER (decoration change)
RETRY_WAIT="${RETRY_WAIT:-0.008}" # pause between geometry retries
MIN_GAP_MS="${MIN_GAP_MS:-100}"   # drop duplicate launches closer than this
SCREEN_TTL="${SCREEN_TTL:-60}"    # seconds to reuse cached screen size/scale
VERIFY="${VERIFY:-0}"             # 1 = poll geometry until it matches
TRIES="${TRIES:-6}"

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
now_s=${EPOCHREALTIME%.*}

no_titlebar=0
mode="center"
active=0
watch_secs=0
toggle=1
while [ $# -gt 0 ]; do
    case "$1" in
        --full)        mode="full"; shift ;;
        --left)        mode="left"; shift ;;
        --center)      mode="center"; shift ;;
        --right)       mode="right"; shift ;;
        --active)      active=1; shift ;;
        --noTitleBar)  no_titlebar=1; shift ;;
        --toggle)      toggle=1; shift ;;
        --noToggle)    toggle=0; shift ;;
        --watch)       watch_secs="${2:-5}"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done

# --- width cycle: ON by default, so a cached shortcut command still cycles ---
if [ "$toggle" = 1 ] && [ "$PW_GIVEN" = 0 ] && [ "$mode" != "full" ]; then
    case "$mode" in
        left|right)
            state_file="$cache_dir/window-snap-${mode}.state"
            read -r -a cycle <<<"$SIDE_CYCLE"
            ;;
        *)
            state_file="$cache_dir/window-snap-toggle.state"
            cycle=("$TW1" "$TW2")
            ;;
    esac
    [ "${#cycle[@]}" -gt 0 ] || die "empty width cycle"
    lock_file="$cache_dir/window-snap-toggle.lock"

    # Hold the lock ONLY around the state read/decide/write critical section:
    # closing fd 9 releases it, so the ~10ms kdotool work never blocks a
    # subsequent press. Busy runs just exit.
    exec 9>"$lock_file"
    flock -n 9 || exit 0

    now_ms=${EPOCHREALTIME/./}   # bash builtin, no subprocess
    now_ms=${now_ms:0:13}
    last_ms=0
    lastw=""
    if [ -f "$state_file" ]; then
        read -r last_ms lastw <"$state_file" || true
    fi
    [[ "$last_ms" =~ ^[0-9]+$ ]] || last_ms=0

    # Record every launch so a single press cannot fire twice. Only launches
    # closer than MIN_GAP_MS are dropped; rapid deliberate taps still toggle.
    if [ $((now_ms - last_ms)) -lt "$MIN_GAP_MS" ]; then
        printf '%s %s\n' "$now_ms" "$lastw" >"$state_file"
        exit 0
    fi

    # Advance one step in the cycle; an unknown/empty state starts at step 0.
    next="${cycle[0]}"
    for ((j = 0; j < ${#cycle[@]}; j++)); do
        if [ "$lastw" = "${cycle[$j]}" ]; then
            next="${cycle[$(( (j + 1) % ${#cycle[@]} ))]}"
            break
        fi
    done
    PW="$next"
    printf '%s %s\n' "$now_ms" "$PW" >"$state_file"
    exec 9>&-                  # unlock; fd close releases flock (no subprocess)
fi

# --- screen geometry (logical pixels + scale), cached for SCREEN_TTL seconds ---
screen_cache="$cache_dir/window-snap-screen.state"
SW="${SW:-}"; SH="${SH:-}"; SCALE="${SCALE:-}"
if [ -z "$SW" ] || [ -z "$SH" ] || [ -z "$SCALE" ]; then
    cached=0
    if [ "$SCREEN_TTL" -gt 0 ] && [ -f "$screen_cache" ]; then
        read -r c_ts c_sw c_sh c_scale <"$screen_cache" || true
        if [[ "${c_ts:-}" =~ ^[0-9]+$ ]] \
            && [ $((now_s - c_ts)) -lt "$SCREEN_TTL" ] \
            && [ -n "${c_sw:-}" ] && [ -n "${c_sh:-}" ] && [ -n "${c_scale:-}" ]; then
            SW="$c_sw"; SH="$c_sh"; SCALE="$c_scale"; cached=1
        fi
    fi
    if [ "$cached" = 0 ]; then
        strip_ansi() { sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }
        screen_info=$(kscreen-doctor -o 2>/dev/null | strip_ansi)
        SW=""; SH=""; SCALE=""
        while IFS= read -r line; do
            if [[ -z "$SW" && $line =~ Geometry:[[:space:]]*[0-9.,]+[[:space:]]+([0-9]+)x([0-9]+) ]]; then
                SW="${BASH_REMATCH[1]}"; SH="${BASH_REMATCH[2]}"
            elif [[ -z "$SCALE" && $line =~ Scale:[[:space:]]*([0-9.]+) ]]; then
                SCALE="${BASH_REMATCH[1]}"
            fi
            [[ -n "$SW" && -n "$SCALE" ]] && break
        done <<<"$screen_info"
        [ -n "$SW" ] || die "cannot read screen size"
        [ -n "$SCALE" ] || SCALE=1
        printf '%s %s %s %s\n' "$now_s" "$SW" "$SH" "$SCALE" >"$screen_cache"
    fi
fi

# --- target geometry in logical pixels ---
if [ "$mode" = "full" ]; then
    W="$SW"; H="$SH"
else
    read -r W H <<<"$(awk -v pw="$PW" -v ph="$PH" -v s="$SCALE" \
        'BEGIN{printf "%.0f %.0f", pw/s, ph/s}')"
fi
case "$mode" in
    full)   X=0;            Y=0 ;;
    center) X=$(( (SW - W) / 2 )); Y=$(( (SH - H) / 2 )) ;;
    left)   X=0;            Y=$(( (SH - H) / 2 )) ;;
    right)  X=$(( SW - W )); Y=$(( (SH - H) / 2 )) ;;
esac

# --- helpers for watch mode (not on the hotkey fast path) ---
find_win() {
    if [ "$active" = 1 ] || [ -z "${PID:-}" ]; then
        kdotool getactivewindow 2>/dev/null
        return
    fi
    kdotool search --pid "$PID" 2>/dev/null | head -n1
}

read_geom() {
    kdotool getwindowgeometry "$1" 2>/dev/null | sed -n \
        -e 's/.*Position: *\([-0-9.]*\), *\([-0-9.]*\).*/\1 \2/p' \
        -e 's/.*Geometry: *\([0-9.]*\)x\([0-9.]*\).*/\1 \2/p' | tr '\n' ' '
}

# --- target window + geometry change in ONE KWin script ---
cmd=(kdotool -q)
if [ "$active" = 1 ] || [ -z "${PID:-}" ]; then
    cmd+=(getactivewindow)          # pushes the focused window onto the stack
    winref="%1"
else
    winref=$(kdotool search --pid "$PID" 2>/dev/null | head -n1)
    [ -n "$winref" ] || die "no target window"
fi

if [ "$no_titlebar" = 1 ]; then
    # NO_BORDER changes frameGeometry semantics; let KWin settle before sizing.
    if [ "$winref" = "%1" ]; then
        kdotool -q getactivewindow windowstate --add NO_BORDER %1 >/dev/null 2>&1
    else
        kdotool -q windowstate --add NO_BORDER "$winref" >/dev/null 2>&1
    fi
    sleep "$DELAY"
fi

# getactivewindow -> move -> size -> read back: one D-Bus script, no sleeps.
cmd+=(windowmove "$winref" "$X" "$Y" windowsize "$winref" "$W" "$H"
      getwindowgeometry "$winref")

[ "$VERIFY" = 1 ] || TRIES=1
id=""
for ((i = 1; i <= TRIES; i++)); do
    out=$("${cmd[@]}" 2>/dev/null)
    gx=""; gy=""; gw=""; gh=""
    while IFS= read -r line; do
        if [[ $line =~ ^Window[[:space:]]+(\{[^}]+\}) ]]; then
            id="${BASH_REMATCH[1]}"
        elif [[ $line =~ Position:[[:space:]]*([-0-9.]+),[[:space:]]*([-0-9.]+) ]]; then
            gx="${BASH_REMATCH[1]}"; gy="${BASH_REMATCH[2]}"
        elif [[ $line =~ Geometry:[[:space:]]*([0-9.]+)x([0-9.]+) ]]; then
            gw="${BASH_REMATCH[1]}"; gh="${BASH_REMATCH[2]}"
        fi
    done <<<"$out"
    [ -n "$id" ] || die "no target window"
    if [ "$(ri "$gx")" = "$X" ] && [ "$(ri "$gy")" = "$Y" ] \
        && [ "$(ri "$gw")" = "$W" ] && [ "$(ri "$gh")" = "$H" ]; then
        break
    fi
    [ "$i" -lt "$TRIES" ] && sleep "$RETRY_WAIT"
done

apply() {
    kdotool -q windowmove "$id" "$X" "$Y" \
            windowsize "$id" "$W" "$H" >/dev/null 2>&1
}

echo "snapped: ${W}x${H} @ ${X},${Y} (logical)"

# --- optional watch mode ---
if [ "$watch_secs" -gt 0 ]; then
    end=$(( $(date +%s) + watch_secs ))
    while [ "$(date +%s)" -lt "$end" ]; do
        [ "$active" = 1 ] && id=$(find_win)
        kdotool getwindowname "$id" >/dev/null 2>&1 || exit 0
        read -r gx gy gw gh <<<"$(read_geom "$id")"
        if [ "$(ri "$gx")" != "$X" ] || [ "$(ri "$gy")" != "$Y" ] \
            || [ "$(ri "$gw")" != "$W" ] || [ "$(ri "$gh")" != "$H" ]; then
            apply
        fi
        sleep 1
    done
fi