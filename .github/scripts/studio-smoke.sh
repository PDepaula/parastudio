#!/usr/bin/env bash
# Smoke for `para studio` (platform-check.yml, Windows job): start it without a browser, fetch the
# page with the key from the link it printed, check the API refuses a call without the key, ask
# which agent the chat would use and, when `claude` is not on this machine (a hosted runner has
# none, and no login), send one message and check the turn ends with the plain "not installed"
# answer. That exercises the chat route, the turn thread and the event list on this platform
# without any account or cost. If `claude` is installed it sends nothing. Stop it at the end.
# It then presses Play: the game is built with its dev channel and its window is started. A hosted
# runner has no GPU, so the window is expected to fail with a plain sentence (a real machine gets
# "running", and then the script takes one screenshot and checks the picture comes back as a PNG);
# either way the script waits for the outcome, checks the page would have words to show, asks for a
# picture with no window open (a plain refusal) and stops everything.
# The buttons, the browser opening, a real window and a real chat (a greeting and a helper card, with
# the friend's own `claude`) are the tester's checklist (docs/windows-first-game.md, step 7).
set -u
para="${1:-tmp/para}"
out="$(mktemp)"
"$para" studio --no-open > "$out" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; rm -f "$out" "$out.png" "$out.head"' EXIT
link=""
for _ in $(seq 1 30); do
  link=$(grep -o 'http://127\.0\.0\.1:[0-9]*/?token=[A-Za-z0-9_-]*' "$out" | head -n 1)
  [ -n "$link" ] && break
  sleep 1
done
[ -n "$link" ] || { echo "para studio printed no link:"; cat "$out"; exit 1; }
base="${link%%/\?*}"
curl -sS --fail "$link" | grep -q "Para Studio" || { echo "the page did not load"; exit 1; }
curl -sS --fail -H "X-Studio-Token: ${link#*token=}" "$base/api/state" | grep -q '"games"' || { echo "the state call failed"; exit 1; }
code=$(curl -sS -o /dev/null -w '%{http_code}' "$base/api/state")
[ "$code" = 403 ] || { echo "a call without the key answered $code, not 403"; exit 1; }
key="${link#*token=}"
agent=$(curl -sS --fail -H "X-Studio-Token: $key" "$base/api/agent") || { echo "the agent call failed"; exit 1; }
echo "$agent" | grep -q '"installed"' || { echo "the agent call did not say whether claude is installed: $agent"; exit 1; }
code=$(curl -sS -o /dev/null -w '%{http_code}' "$base/api/chat?since=0")
[ "$code" = 403 ] || { echo "a chat call without the key answered $code, not 403"; exit 1; }
if echo "$agent" | grep -q '"installed":false'; then
  state=$(curl -sS --fail -H "X-Studio-Token: $key" "$base/api/state")
  game=$(echo "$state" | grep -o '"game":"[^"]*"' | head -n 1 | sed 's/"game":"\(.*\)"/\1/')
  [ -n "$game" ] || { echo "no game to chat about: $state"; exit 1; }
  curl -sS --fail -X POST -H "X-Studio-Token: $key" -H "Content-Type: application/json" \
    -d "{\"game\":\"$game\",\"text\":\"hello\"}" "$base/api/chat/send" > /dev/null || { echo "the chat send failed"; exit 1; }
  chat=""
  for _ in $(seq 1 30); do
    chat=$(curl -sS --fail -H "X-Studio-Token: $key" "$base/api/chat?game=$game&since=0")
    echo "$chat" | grep -q '"kind":"done"' && break
    sleep 1
  done
  echo "$chat" | grep -q '"code":"not-installed"' || { echo "the turn did not end with the not-installed answer: $chat"; exit 1; }
  echo "para studio chat answered without claude installed (plain not-installed message)"
fi

# --- the Play panel ---------------------------------------------------------------------------
state=$(curl -sS --fail -H "X-Studio-Token: $key" "$base/api/state")
game=$(echo "$state" | grep -o '"game":"[^"]*"' | head -n 1 | sed 's/"game":"\(.*\)"/\1/')
if [ -z "$game" ]; then echo "no game to play, so the Play panel was not exercised"; exit 1; fi
api() { curl -sS -H "X-Studio-Token: $key" "$@"; }
post() { curl -sS -o /dev/null -w '%{http_code}' -X POST -H "X-Studio-Token: $key" -H "Content-Type: application/json" -d "$2" "$base$1"; }
api "$base/api/play" | grep -q '"state":"idle"' || { echo "the game window was not idle at the start"; exit 1; }
code=$(curl -sS -o /dev/null -w '%{http_code}' "$base/api/play")
[ "$code" = 403 ] || { echo "a play call without the key answered $code, not 403"; exit 1; }
code=$(post /api/play/shot "{\"game\":\"$game\"}")
[ "$code" = 409 ] || { echo "a picture with no window answered $code, not the plain 409"; exit 1; }
code=$(post /api/play/start "{\"game\":\"$game\"}")
[ "$code" = 200 ] || { echo "Play answered $code, not 200"; exit 1; }
play=""
for _ in $(seq 1 200); do # up to ten minutes: the first build on a new machine is slow
  play=$(api "$base/api/play")
  case "$play" in *'"state":"building"'*|*'"state":"starting"'*) sleep 3;; *) break;; esac
done
case "$play" in
  *'"state":"running"'*)
    echo "$play" | grep -q '"live":true' || { echo "the window is open but is not answering: $play"; exit 1; }
    shot=$(api -X POST -H "Content-Type: application/json" -d "{\"game\":\"$game\"}" "$base/api/play/shot")
    name=$(echo "$shot" | grep -o 'shot-[0-9]*-[0-9]*-[0-9]*\.png' | head -n 1)
    [ -n "$name" ] || { echo "the screenshot did not come back with a name: $shot"; exit 1; }
    api "$base/api/shot?name=$name" -o "$out.png" -D "$out.head"
    grep -qi '^content-type: image/png' "$out.head" || { echo "the picture was not served as image/png"; exit 1; }
    [ "$(head -c 4 "$out.png" | tail -c 3)" = "PNG" ] || { echo "the picture is not a PNG"; exit 1; }
    rm -f "$out.png" "$out.head"
    echo "para studio opened the game window and took a screenshot ($name)"
    ;;
  *'"state":"failed"'*|*'"state":"exited"'*)
    echo "$play" | grep -q '"message":"[^"]' || { echo "the window ended with no words for the page: $play"; exit 1; }
    echo "para studio Play ended in a plain sentence (expected where there is no graphics): $(echo "$play" | grep -o '"code":"[^"]*"')"
    ;;
  *) echo "Play did not settle: $play"; exit 1 ;;
esac
stopped=$(api -X POST -H "Content-Type: application/json" -d '{}' "$base/api/play/stop")
echo "$stopped" | grep -q '"stopped"' || { echo "the stop call did not answer: $stopped"; exit 1; }
echo "para studio answered at $base (page, state, agent, Play, and 403 without the key)"
