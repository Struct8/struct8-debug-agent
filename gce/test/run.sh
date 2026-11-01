#!/bin/sh
# Runs gce/struct8-debug.sh in dash against a stand-in curl that plays the metadata server and
# the Pub/Sub API, and checks what the program published and acknowledged.
# Usage: sh gce/test/run.sh   (needs dash; DASH_BIN overrides where it is)

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PROGRAM="$HERE/../struct8-debug.sh"
DASH="${DASH_BIN:-$(command -v dash || true)}"
[ -n "$DASH" ] || { echo "dash is not installed (set DASH_BIN)" >&2; exit 2; }

FAILED=0
fail() { echo "FAIL: $1" >&2; FAILED=1; }
pass() { echo "ok: $1"; }

# One pull answer of the Pub/Sub API. The API escapes "=" in JSON strings, and base64 ends in it.
pull_answer() {
  id=$1; attrs=$2; data=${3:-}
  encoded=$(printf '%s' "$data" | base64 | tr -d '\n' | sed 's/=/\\u003d/g')
  printf '{\n  "receivedMessages": [\n    {\n      "ackId": "ack-%s",\n      "message": {\n        "data": "%s",\n        "attributes": {%s},\n        "messageId": "%s",\n        "publishTime": "2026-11-01T00:00:00Z"\n      }\n    }\n  ]\n}\n' "$id" "$encoded" "$attrs" "$id"
}

# A fresh folder with the stand-in curl on PATH. $FAKE/queue/<n> are pull answers, served in
# order; with the queue empty the level key goes away, and the program removes itself. Each
# publish body lands in published.<n>, each acknowledge body in acks.
setup() {
  ROOT=$(mktemp -d)
  FAKE="$ROOT/fake"
  mkdir -p "$FAKE/queue" "$ROOT/bin"
  cp "$PROGRAM" "$ROOT/program.sh"
  cat > "$ROOT/bin/curl" << 'FAKE_CURL'
#!/bin/sh
url=""; data=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) data="$2"; shift ;;
    -o) out="$2"; shift ;;
    -H|-X|-w|--max-time) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
reply() { if [ -n "$out" ]; then printf '%s' "$1" > "$out"; else printf '%s' "$1"; fi; }
case "$url" in
  */instance/attributes/struct8-debug-level)
    [ -f "$FAKE/level" ] || exit 22
    reply "$(cat "$FAKE/level")" ;;
  */instance/attributes/struct8-debug-program)
    [ -f "$FAKE/program" ] || exit 22
    cat "$FAKE/program" ;;
  */instance/name) reply web ;;
  */service-accounts/default/token) reply '{"access_token":"tok","expires_in":3599,"token_type":"Bearer"}' ;;
  *:pull)
    next=$(ls "$FAKE/queue" 2>/dev/null | sort | head -n 1)
    if [ -z "$next" ]; then rm -f "$FAKE/level"; reply '{}'; exit 0; fi
    reply "$(cat "$FAKE/queue/$next")"; rm -f "$FAKE/queue/$next" ;;
  *:publish)
    n=$(ls "$FAKE" | grep -c '^published')
    case "$data" in @*) cp "${data#@}" "$FAKE/published.$n" ;; *) printf '%s' "$data" > "$FAKE/published.$n" ;; esac
    echo "publish" >> "$FAKE/order"
    reply '{"messageIds":["1"]}' ;;
  *:acknowledge) printf '%s\n' "$data" >> "$FAKE/acks"; echo "ack" >> "$FAKE/order"; reply '{}' ;;
  *) exit 7 ;;
esac
FAKE_CURL
  chmod +x "$ROOT/bin/curl"
}

run() {
  PATH="$ROOT/bin:$PATH" FAKE="$FAKE" STRUCT8_DEBUG_STATE="$ROOT/state" \
    STRUCT8_DEBUG_SUBSCRIPTION=projects/p/subscriptions/s STRUCT8_DEBUG_OUTPUT_TOPIC=projects/p/topics/t \
    STRUCT8_DEBUG_UPDATE_EVERY="${UPDATE_EVERY:-60}" \
    timeout 60 "$DASH" "$ROOT/program.sh" 2> "$ROOT/stderr"
}

attr() { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$FAKE/published.$1"; }
output() { sed -n 's/.*"data":"\([^"]*\)".*/\1/p' "$FAKE/published.$1" | base64 -d; }

# --- levels, order and removal ---
setup
echo diagnostics > "$FAKE/level"
pull_answer m1 '"instance": "web", "request": "r1", "mode": "diagnostics", "command": "hostname", "args": ""' > "$FAKE/queue/1"
pull_answer m2 '"instance": "web", "request": "r2", "mode": "shell"' 'echo hi' > "$FAKE/queue/2"
pull_answer m3 '"instance": "web", "request": "r3", "mode": "diagnostics", "command": "ip", "args": "route add 1.2.3.4"' > "$FAKE/queue/3"
pull_answer m4 '"instance": "web", "request": "r4", "mode": "diagnostics", "command": "rm", "args": "-rf /"' > "$FAKE/queue/4"
# The same message again, as an at-least-once delivery would bring it.
pull_answer m1 '"instance": "web", "request": "r1", "mode": "diagnostics", "command": "hostname", "args": ""' > "$FAKE/queue/5"
run

[ "$(attr 0 request) $(attr 1 request) $(attr 2 request) $(attr 3 request)" = "r1 r2 r3 r4" ] && pass "one output per command" || fail "requests: $(cat "$FAKE"/published.* 2>/dev/null)"
[ ! -f "$FAKE/published.4" ] && pass "the repeated message is not run again" || fail "a fifth output went out"
[ "$(attr 0 exit) $(attr 0 instance) $(attr 0 truncated) $(attr 0 version)" = "0 web false 1.0.0" ] && pass "diagnostics runs, with the version" || fail "first output: $(cat "$FAKE/published.0")"
[ -n "$(output 0)" ] && pass "the output is in the data" || fail "empty output"
[ "$(attr 1 exit)" = 3 ] && output 1 | grep -q "grants the diagnostics level, below shell" && pass "shell above the level is refused" || fail "shell: $(output 1)"
output 2 | grep -q "operand 'add' writes" && pass "a writing operand is refused" || fail "ip route add: $(output 2)"
output 3 | grep -q "'rm' is not on the diagnostics list" && pass "a command off the list is refused" || fail "rm: $(output 3)"
[ "$(wc -l < "$FAKE/acks" | tr -d ' ')" = 5 ] && pass "five acknowledgements" || fail "acks: $(cat "$FAKE/acks")"
[ "$(tr '\n' ' ' < "$FAKE/order")" = "publish ack publish ack publish ack publish ack ack " ] && pass "each acknowledgement after its publish" || fail "order: $(tr '\n' ' ' < "$FAKE/order")"
[ ! -e "$ROOT/state" ] && pass "with the level key gone, the program removed itself" || fail "the state folder is still there"
rm -rf "$ROOT"

# --- update from the struct8-debug-program key ---
setup
echo shell > "$FAKE/level"
sed 's/^VERSION=.*/VERSION=9.9.9/' "$PROGRAM" > "$FAKE/program"
pull_answer m1 '"instance": "web", "request": "r1", "mode": "shell"' 'echo hi' > "$FAKE/queue/1"
UPDATE_EVERY=0 run
[ "$(attr 0 version)" = 9.9.9 ] && pass "the program in the key answers in place of this one" || fail "version: $(attr 0 version); stderr: $(cat "$ROOT/stderr")"
[ "$(output 0)" = hi ] && pass "and runs the command" || fail "output: $(output 0)"
cmp -s "$FAKE/program" "$ROOT/program.sh" && pass "the program file holds the new program" || fail "the program file was not replaced"
rm -rf "$ROOT"

# --- a program that does not parse is not run ---
setup
echo shell > "$FAKE/level"
printf '#!/bin/sh\nif then\n' > "$FAKE/program"
pull_answer m1 '"instance": "web", "request": "r1", "mode": "shell"' 'echo hi' > "$FAKE/queue/1"
UPDATE_EVERY=0 run
[ "$(attr 0 version)" = 1.0.0 ] && pass "a program with a syntax error is not run" || fail "version: $(attr 0 version)"
grep -q "does not parse" "$ROOT/stderr" && pass "and the log says why" || fail "stderr: $(cat "$ROOT/stderr")"
rm -rf "$ROOT"

# --- the program can still go into a Terraform template as text ---
if grep -nE '[$%]\{' "$PROGRAM"; then fail "a template sequence in the program (lines above)"; else pass "no template sequence"; fi

exit $FAILED
