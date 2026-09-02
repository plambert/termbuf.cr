#!/bin/bash
# Drives one counted-width run: one host terminal, one multiplexer layer.
#
#     scripts/survey.sh <terminal|ghostty|iterm|kitty> <none|tmux|screen4|screen5> \
#                       <outdir> [corpus.tsv]
#
# No screen capture is involved, so this needs a window and nothing else — it
# runs with the screen locked. See `measurements/SURVEY.md`.
#
# Every host makes its own window, nothing is typed into a window this did not
# create, and everything it opened is closed again on the way out:
#
#   * the window it made, by the id the launcher handed back
#   * the application, but only when it was not already running. Quitting a
#     terminal somebody was using would be worse than leaving one behind.
#   * the process it spawned, by pid, never by name
#
# `tmux` and `screen` get a private socket or session name and no config file,
# so an existing session cannot be attached, resized or killed by accident.
set -euo pipefail

HOST=${1:?host}
LAYER=${2:?layer}
OUT=$(mkdir -p "${3:?outdir}" && cd "$3" && pwd)
CORPUS=${4:-}

# The window this opens starts in whatever directory it likes, so anything it
# is handed has to be an absolute path.
[ -n "$CORPUS" ] && CORPUS=$(cd "$(dirname "$CORPUS")" && pwd)/$(basename "$CORPUS")

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${TMPDIR:-/tmp}/termbuf-survey
TAG="$HOST-$LAYER"
SENTINEL="$WORK/done.$TAG"
INNER="$WORK/inner.$TAG.sh"
LOG="$WORK/log.$TAG"
BINARY=${MEASURE_COLUMNS:-$WORK/measure_columns}

mkdir -p "$WORK"
rm -f "$SENTINEL" "$LOG"

if [ ! -x "$BINARY" ]; then
  echo "building the instrument" >&2
  crystal build "$HERE/scripts/measure_columns.cr" -o "$BINARY"
fi

# Which binary each layer is, so the reading records the one that was launched
# rather than the one on the PATH — they are not the same screen.
case "$LAYER" in
  none)    LAYER_BIN= ;;
  tmux)    LAYER_BIN=/opt/homebrew/bin/tmux ;;
  screen4) LAYER_BIN=/usr/bin/screen ;;
  screen5) LAYER_BIN=/opt/homebrew/bin/screen ;;
  *) echo "unknown layer $LAYER" >&2; exit 1 ;;
esac

cat > "$INNER" <<EOF
#!/bin/bash
export TERMBUF_LAYER="$LAYER"
export TERMBUF_LAYER_BIN="$LAYER_BIN"
"$BINARY" "$OUT" $CORPUS 2>> "$LOG"
echo \$? > "$SENTINEL"
EOF
chmod +x "$INNER"

case "$LAYER" in
  none)    RUN="$INNER" ;;
  tmux)    RUN="$LAYER_BIN -L termbuf -f /dev/null new-session -- $INNER" ;;
  screen4) RUN="$LAYER_BIN -c /dev/null -S termbuf4 $INNER" ;;
  screen5) RUN="$LAYER_BIN -c /dev/null -S termbuf5 $INNER" ;;
esac

# What was already running is not ours to close.
running() { osascript -e "application \"$1\" is running" 2>/dev/null || echo false; }

ghostty_pids() {
  ps -Ao pid,comm | awk '$2 ~ /Ghostty.app\/Contents\/MacOS\/ghostty/ {print $1}' | sort
}

APP=
WAS_RUNNING=false
WINDOW_ID=
CHILD_PID=
BEFORE=

cleanup() {
  set +e

  # The window first, so an application that quits when its last one closes
  # does not need telling twice.
  if [ -n "$WINDOW_ID" ] && [ -n "$APP" ]; then
    osascript -e "tell application \"$APP\" to close (every window whose id is $WINDOW_ID)" \
      > /dev/null 2>&1
  fi

  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null
    for _ in 1 2 3 4 5; do kill -0 "$CHILD_PID" 2>/dev/null || break; sleep 1; done
    kill -9 "$CHILD_PID" 2>/dev/null
  fi

  # Ghostty is launched through `open`, which hands back no pid, so the one to
  # close is whichever appeared. Anything that was already there stays.
  if [ "$HOST" = ghostty ] && [ -n "$BEFORE" ]; then
    for pid in $(comm -13 <(echo "$BEFORE") <(ghostty_pids)); do
      kill "$pid" 2>/dev/null
    done
  fi

  if [ -n "$APP" ] && [ "$WAS_RUNNING" = false ]; then
    osascript -e "tell application \"$APP\" to quit" > /dev/null 2>&1
  fi
}
trap cleanup EXIT

case "$HOST" in
  terminal)
    APP=Terminal
    WAS_RUNNING=$(running Terminal)
    WINDOW_ID=$(osascript <<APPLESCRIPT
tell application "Terminal"
  activate
  do script "$RUN; exit"
  delay 1
  return id of front window
end tell
APPLESCRIPT
)
    ;;

  iterm)
    APP=iTerm
    WAS_RUNNING=$(running iTerm)
    WINDOW_ID=$(osascript <<APPLESCRIPT
tell application "iTerm"
  activate
  set win to (create window with default profile)
  tell current session of win to write text "$RUN; exit"
  return id of win
end tell
APPLESCRIPT
)
    ;;

  ghostty)
    BEFORE=$(ghostty_pids)
    CONF="$WORK/ghostty-config"
    mkdir -p "$CONF"
    cat > "$CONF/config" <<EOF
font-family = SF Mono
font-size = 11
window-decoration = false
shell-integration = none
confirm-close-surface = false
quit-after-last-window-closed = true
window-save-state = never
initial-window = true
initial-command = $RUN
title = termbuf-survey
EOF
    open -na /Applications/Ghostty.app --args \
      --config-default-files=false --config-file="$CONF/config"
    ;;

  kitty)
    # kitty is the one that can be launched from the command line, so its
    # process is ours to wait for and ours to close.
    /Applications/kitty.app/Contents/MacOS/kitty --config NONE \
      -o font_family="SF Mono" -o font_size=11 \
      -o confirm_os_window_close=0 \
      $RUN >> "$LOG" 2>&1 &
    CHILD_PID=$!
    ;;

  *) echo "unknown host $HOST" >&2; exit 1 ;;
esac

for _ in $(seq 1 60); do
  [ -f "$SENTINEL" ] && break
  sleep 2
done

if [ -f "$SENTINEL" ]; then
  echo "$TAG exit=$(cat "$SENTINEL")"
else
  echo "$TAG TIMED OUT"
  [ -s "$LOG" ] && tail -3 "$LOG"
  exit 1
fi
