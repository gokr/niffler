#!/usr/bin/env bash
# Open the movie with sound, in one command.
#
#   bash tools/play.sh              # voice-over if rendered, else captions
#   bash tools/play.sh --no-voice   # force captions only
#   bash tools/play.sh --voice=browser   # OS speech synthesis (no audio files)
#   bash tools/play.sh --at=58      # start at 58s (a scene, e.g. self-extension)
#   MOVIE_PORT=8721 bash tools/play.sh   # pin a port (default: OS-assigned)
#
# It serves over http://127.0.0.1:PORT rather than opening file:// directly:
# both work in Chrome, but a local origin is friendlier to autoplay policies,
# and it means the same command works when the movie is opened on another
# machine on your LAN. No dependencies — python3's http.server.
#
# The PORT IS ASSIGNED BY THE OS (bind :0) unless MOVIE_PORT is set. A fixed
# default is a landmine on a developer machine: 8000/8080/8099 are all in use by
# other checkouts here (ktd2 alone uses 3000, 8080, 8098, 8099), and quietly
# serving somebody else's app — or dying on "address in use" — is worse than
# an unfamiliar number in the URL.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOVIE="$(dirname "$HERE")"
PORT="${MOVIE_PORT:-}"    # empty = let the OS choose
VOICE="track"
AT=""
for arg in "$@"; do
  case "$arg" in
    --no-voice) VOICE="none" ;;
    --voice=*) VOICE="${arg#*=}" ;;
    --at=*) AT="&t=${arg#*=}" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# A missing voice-over is the most likely reason someone hears nothing; say so
# up front instead of letting the film play silently.
if [ "$VOICE" = "track" ]; then
  if ! compgen -G "$MOVIE/audio/s*.wav" >/dev/null 2>&1 && \
     ! compgen -G "$MOVIE/audio/s*.mp3" >/dev/null 2>&1; then
    echo "! no narration rendered yet — running with captions only."
    echo "  to add the voice:  bash tools/fetch-piper.sh"
    echo "                     node tools/render-voiceover.mjs --engine=piper"
    VOICE="none"
  fi
fi

portOpen() { [ -n "$PORT" ] && (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }

# Reuse a server already listening on an EXPLICIT port, else start a DETACHED
# one: a plain `&` is killed when the invoking shell exits in some harnesses
# (measured — the server was SIGTERM'd right after the wrapper returned), so use
# setsid. With an OS-assigned port there is nothing to reuse: bind :0 and read
# the port the server reports.
if ! portOpen; then
  # --directory, not a `cd` in a subshell: the detached child did not inherit
  # the subshell's cwd in testing (index.html served, audio/ 404'd).
  log="/tmp/niffler-movie-server.log"
  : > "$log"
  # Ask the OS for a free port ourselves instead of scraping the server's
  # banner: python's "Serving HTTP on ... port N" did not reach the log when
  # detached (buffering), so the banner parse is not dependable. The tiny race
  # between closing this probe socket and the server binding is acceptable and
  # is caught by the readiness check below.
  if [ -z "$PORT" ]; then
    PORT=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')
    [ -n "$PORT" ] || { echo "! could not obtain a free port" >&2; exit 1; }
  fi
  startServer() {
    setsid python3 -u -m http.server "$PORT" --bind 127.0.0.1 \
      --directory "$MOVIE" >"$log" 2>&1 &
    echo $! > /tmp/niffler-movie-server.pid
  }
  startServer 2>/dev/null || {
    python3 -u -m http.server "$PORT" --bind 127.0.0.1 \
      --directory "$MOVIE" >"$log" 2>&1 &
    echo $! > /tmp/niffler-movie-server.pid
  }
  ok=""
  for _ in $(seq 1 80); do portOpen && { ok=1; break; }; sleep 0.1; done
  if [ -z "$ok" ]; then
    echo "! could not start the server on port $PORT (see $log)" >&2
    echo "  try:  MOVIE_PORT=8721 bash tools/play.sh" >&2
    exit 1
  fi
fi

URL="http://127.0.0.1:$PORT/index.html?voice=$VOICE&autoplay=1$AT"
echo "→ $URL"
echo "  (voice: $VOICE · captions always on · space pause · ←/→ scene · f fullscreen)"
echo "  stop the server: kill \$(cat /tmp/niffler-movie-server.pid 2>/dev/null)"

# open it in a browser if we can; print the URL regardless (remote/headless use)
for opener in xdg-open open sensible-browser wslview; do
  if command -v "$opener" >/dev/null 2>&1; then
    "$opener" "$URL" >/dev/null 2>&1 &
    exit 0
  fi
done
