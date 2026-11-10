#!/bin/bash
# End-to-end test of the release build's `Likely --eval personal` (docs/EVALS.md), with a fake agent.
#
# Never touches your real data, agents or Keychain, and shows no UI:
# - the binaries are built with LIKELY_EVAL_TEST_SEAM, which only lets this script give them a fake home
#   folder (CFFIXED_USER_HOME/HOME); release builds (build.sh, scripts/release.sh) never set it;
# - they run under a throwaway name, so their preferences domain is empty (no saved claudePath, no
#   license), and unsigned, so there's no data key to read;
# - "Claude Code" is a shell script in the fake ~/.local/bin, where Likely's agent lookup finds it first.
#
# Usage: scripts/test-eval-cli.sh   (builds into .build-evalcli-*; takes a few minutes the first time)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP%/}/likely-evalcli.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILURES=$((FAILURES + 1)); }

echo "==> Building (release, LIKELY_EVAL_TEST_SEAM): free and paid editions"
build() {   # build <dir> <name> [flags…] → copies the binary to $WORK/<name>/ under a unique name
    local dir="$1" name="$2"; shift 2
    swift build -c release --build-path "$dir" -Xswiftc -DLIKELY_EVAL_TEST_SEAM "$@" >/dev/null
    local bin; bin="$(swift build -c release --build-path "$dir" -Xswiftc -DLIKELY_EVAL_TEST_SEAM "$@" --show-bin-path)"
    mkdir -p "$WORK/$name"
    cp "$bin/Likely" "$WORK/$name/likely-evalcli-test-$name-$$"
    ditto "$bin/Sparkle.framework" "$WORK/$name/Sparkle.framework"
    echo "$WORK/$name/likely-evalcli-test-$name-$$"
}
FREE="$(build .build-evalcli-free free -Xswiftc -DLIKELY_FREE)"
PAID="$(build .build-evalcli-paid paid)"

H="$WORK/home"
DATA="$H/Library/Application Support/Likely"
mkdir -p "$H/.local/bin" "$DATA/evals"
chmod 700 "$H"

# The fake Claude Code: reads the first message, answers with a FILE line, records its environment.
cat > "$H/.local/bin/claude" <<'FAKE'
#!/bin/bash
IFS= read -r first
env > "$HOME/agent-env.txt"
perl -e 'print(($SIG{INT} // "DEFAULT"), " ", ($SIG{TERM} // "DEFAULT"), "\n")' > "$HOME/agent-signals.txt"
printf '%s\n' "$*" > "$HOME/agent-args.txt"
if printf '%s' "$first" | grep -qi 'shared folder'; then answer=/Users/Shared; else answer=/Applications; fi
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"STATUS: looking\\nFILE: %s\\n"}]}}\n' "$answer"
printf '{"type":"result","is_error":false,"result":"done","total_cost_usd":0.0012,"num_turns":1}\n'
cat > /dev/null
FAKE
chmod 755 "$H/.local/bin/claude"

# The fake Codex: starts a thread, saves its session like Codex (~/.codex/sessions/<y>/<m>/<d>/…-<thread>.jsonl),
# answers, or with HANG-FOREVER-TEST in the prompt never finishes (for the Ctrl-C test).
cat > "$H/.local/bin/codex" <<'FAKE'
#!/bin/bash
prompt="${@: -1}"
tid="0199aaaa-bbbb-cccc-dddd-$(printf '%012d' $$)"
dir="$HOME/.codex/sessions/$(date +%Y/%m/%d)"; mkdir -p "$dir"
echo '{"secret":"the query"}' > "$dir/rollout-2026-$tid.jsonl"
printf '{"type":"thread.started","thread_id":"%s"}\n' "$tid"
if printf '%s' "$prompt" | grep -q 'HANG-FOREVER-TEST'; then touch "$HOME/codex-hanging"; exec sleep 600; fi
printf '{"type":"item.completed","item":{"type":"agent_message","text":"FILE: /Users/Shared\\n"}}\n'
printf '{"type":"turn.completed"}\n'
FAKE
chmod 755 "$H/.local/bin/codex"

# Runs a binary the way a coding agent would, in a deliberately dirty environment.
run() {   # run <binary> <args…>; sets OUT, ERR, CODE
    set +e
    OUT="$(env -i CFFIXED_USER_HOME="$H" HOME="$H" LIKELY_EVAL_TEST_ALLOW="${ALLOW-1}" ${TOKEN:+LIKELY_RUN_TOKEN="$TOKEN"} \
           PATH="/tmp/attacker:/usr/bin:/bin" NODE_OPTIONS="--require /tmp/x.js" \
           DYLD_FALLBACK_LIBRARY_PATH=/tmp/attacker ZDOTDIR=/tmp/attacker LIKELY_FIXTURES=/tmp/attacker \
           "$@" 2>"$WORK/stderr")"
    CODE=$?
    set -e
    ERR="$(cat "$WORK/stderr")"
}
json() {   # json <python expression over d>: prints it, or "ERROR" if stdout isn't that JSON
    python3 -I -c "import json,sys
try:
    d = json.loads(sys.stdin.read()); print(eval(sys.argv[1], {'d': d}))
except Exception as e:
    print('ERROR', type(e).__name__, e)" "$1" <<<"$OUT"
}
expect_code() {   # expect_code <code> <name>
    if [ "$CODE" = "$1" ]; then pass "$2 (exit $CODE)"; else fail "$2: exit $CODE, expected $1"; echo "$ERR" | tail -5 | sed 's/^/     /'; fi
}

echo "==> Refused in release builds (exit 2)"
for args in "--agent-path /bin/sh" "--prompt-file /etc/hosts" "--out /tmp/x" "--no-isolate" "--dry-run" \
            "-claudePath /bin/sh" "--model -claudePath" "stray" "--agent /bin/sh"; do
    # shellcheck disable=SC2086
    run "$FREE" --eval personal $args --json
    expect_code 2 "--eval personal $args"
    [ "$(json 'd["exitCode"]')" = 2 ] || fail "$args: JSON error on stdout"
done
for suite in fixtures all "$ROOT/evals/fixtures/cases.jsonl" /tmp/cases.jsonl; do
    run "$FREE" --eval "$suite"
    expect_code 2 "--eval $suite"
done

echo "==> Off unless allowed in Settings → Tests (exit 4)"
ALLOW=0 run "$FREE" --eval personal --json
expect_code 4 "command-line runs switched off"
echo "$ERR" | grep -q "Allow command-line test runs" && pass "says how to turn them on" || fail "switch message"
ALLOW= run "$FREE" --eval personal
expect_code 4 "switch never set (default off)"
# Run Tests in Settings passes a one-time token whose record Likely stored; a made-up one doesn't count.
ALLOW=0 TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA run "$FREE" --eval personal --json
expect_code 4 "made-up run token with the switch off"

echo "==> Licensing"
run "$PAID" --eval personal --json
expect_code 3 "paid build without a license"
[ "$(json 'd["status"]')" = error ] && pass "unlicensed: JSON error" || fail "unlicensed: no JSON error"

echo "==> No tests yet (exit 1)"
run "$FREE" --eval personal
expect_code 1 "no saved tests"
echo "$ERR" | grep -q "no saved tests" && pass "says there are no tests" || fail "no-tests message"

cat > "$DATA/evals/cases.jsonl" <<'CASES'
{"id":"shared","query":"the shared folder","expect":{"anyOf":["/Users/Shared"]},"tags":["folders"],"source":"manual"}
{"id":"utilities","query":"the utilities","expect":{"anyOf":["/Applications/Utilities"]},"tags":["folders"],"source":"captured"}
{"id":"shot","query":"the screenshot one","context":{"screenshot":"/etc/hosts"},"expect":{"anyOf":["/Users/Shared"]},"source":"manual"}
CASES

echo "==> First run"
TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA run "$FREE" --eval personal --agent claude --case shared --case utilities --json
expect_code 0 "run completes although a test fails"
[ "$(json 'd["summary"]["passed"], d["summary"]["scored"]')" = "(1, 2)" ] && pass "1 of 2 passed" || fail "counts: $(json 'd.get("summary")')"
[ "$(json '[c["id"] + ":" + str(c["pass"]) + ":" + str(c.get("rank")) for c in d["cases"]]')" = "['shared:True:1', 'utilities:False:None']" ] \
    && pass "per-case pass and rank" || fail "cases: $(json 'd.get("cases")')"
[ "$(json 'd.get("comparison")')" = None ] && pass "no previous run" || fail "unexpected comparison"
REPORT="$(json 'd["reportPath"]')"; RESULTS="$(json 'd["resultsPath"]')"
[ -f "$REPORT" ] && [ -f "$RESULTS" ] && pass "results.json and report.html written" || fail "run files missing"
case "$REPORT" in "$DATA/evals/runs/"*) pass "inside the data folder's runs/" ;; *) fail "report outside runs/: $REPORT" ;; esac
[ "$(stat -f %Lp "$(dirname "$REPORT")")" = 700 ] && [ "$(stat -f %Lp "$RESULTS")" = 600 ] && pass "owner-only (700/600)" || fail "permissions"
echo "$ERR" | grep -q '^\[1/2\] PASS shared' && pass "progress on stderr" || fail "progress missing from stderr"
echo "$OUT" | grep -q 'PASS' && fail "progress leaked into stdout (--json)" || pass "stdout is JSON only"

echo "==> Hermes runs one test at a time"
run "$FREE" --eval personal --agent hermes --jobs 2
expect_code 2 "--agent hermes --jobs 2"

echo "==> Clean environment"
grep -q 'NODE_OPTIONS\|DYLD_\|ZDOTDIR\|LIKELY_FIXTURES\|/tmp/attacker' "$H/agent-env.txt" && fail "caller's environment reached the agent" || pass "caller's environment dropped"
grep -q 'LIKELY_RUN_TOKEN' "$H/agent-env.txt" && fail "run token reached the agent" || pass "run token not passed to the agent"
grep -q '^PATH=.*/usr/bin:/bin:/usr/sbin:/sbin' "$H/agent-env.txt" && pass "agent PATH built from the clean PATH" || fail "agent PATH: $(grep ^PATH= "$H/agent-env.txt")"
[ "$(cat "$H/agent-signals.txt")" = "DEFAULT DEFAULT" ] && pass "agent doesn't inherit ignored SIGINT/SIGTERM" || fail "agent signals: $(cat "$H/agent-signals.txt")"

echo "==> A tool waiting for approval isn't used"
cat > "$DATA/tools.json" <<'TOOLS'
{"version":1,"tools":[{"id":"rclip","name":"Image search (rclip)","enabled":true,"commands":["rclip -n"],"instructions":"Find images."}]}
TOOLS
run "$FREE" --eval personal --case shared --case utilities --json
expect_code 0 "second run"
[ "$(json 'd["tools"]["pendingApproval"]')" = "['rclip']" ] && pass "rclip pending approval" || fail "pending: $(json 'd["tools"]')"
[ "$(json 'd["tools"]["active"]')" = "[]" ] && pass "no unapproved tool active" || fail "active tools"
grep -q 'rclip' "$H/agent-args.txt" && fail "unapproved tool reached the agent's allowlist" || pass "unapproved tool not allowlisted"
[ "$(json 'd["comparison"]["previousPassed"], d["comparison"]["passedDelta"], d["comparison"]["toolsChanged"]')" = "(1, 0, False)" ] \
    && pass "compared with the previous run" || fail "comparison: $(json 'd.get("comparison")')"

echo "==> Screenshots are never used"
run "$FREE" --eval personal --case shot
expect_code 0 "case with a screenshot"
echo "$ERR" | grep -q "don't use screenshots" && pass "says screenshots aren't used" || fail "screenshot note missing"
grep -q '/etc/hosts' "$H/agent-args.txt" && fail "screenshot reached the agent" || pass "agent never saw it"
find "$DATA/evals/runs" -name 'screenshot-*' | grep -q . && fail "decrypted/copied screenshot left in runs" || pass "no screenshot copies in runs/"
echo "$OUT" | grep -q '^Report: ' && pass "human summary on stdout" || fail "no summary on stdout"

echo "==> Codex sessions are deleted before the run exits"
run "$FREE" --eval personal --agent codex --case shared --timeout 30 --json
expect_code 0 "codex run"
[ "$(json 'd["summary"]["passed"]')" = 1 ] && pass "codex answer scored" || fail "codex: $(json 'd.get("summary")')"
find "$H/.codex/sessions" -name '*.jsonl' | grep -q . && fail "Codex session left behind" || pass "Codex session deleted"

cat >> "$DATA/evals/cases.jsonl" <<'CASES'
{"id":"hang","query":"HANG-FOREVER-TEST","expect":{"anyOf":["/Users/Shared"]},"source":"manual"}
CASES
set +e
env -i CFFIXED_USER_HOME="$H" HOME="$H" LIKELY_EVAL_TEST_ALLOW=1 PATH=/usr/bin:/bin "$FREE" --eval personal --agent codex --case hang --json \
    >"$WORK/hang.out" 2>"$WORK/hang.err" &
CLI=$!
for _ in $(seq 150); do [ -f "$H/codex-hanging" ] && break; sleep 0.1; done
sleep 0.3
kill -INT "$CLI"
wait "$CLI"; CODE=$?
set -e
ERR="$(cat "$WORK/hang.err")"; OUT="$(cat "$WORK/hang.out")"
expect_code 130 "Ctrl-C during a Codex case"
[ "$(json 'd["status"]')" = interrupted ] && pass "partial results written" || fail "interrupted JSON: $(json 'd')"
find "$H/.codex/sessions" -name '*.jsonl' | grep -q . && fail "Codex session left behind after Ctrl-C" || pass "Codex session deleted after Ctrl-C"

echo "==> One run at a time"
perl -e 'use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; open(my $r, ">", $ARGV[1]); close $r; sleep 20' \
    "$DATA/evals/.run.lock" "$WORK/locked" &
LOCKER=$!
for _ in $(seq 100); do [ -f "$WORK/locked" ] && break; sleep 0.1; done
run "$FREE" --eval personal --case shared
expect_code 1 "while another run holds the lock"
echo "$ERR" | grep -q "Another test run is in progress" && pass "says another run is in progress" || fail "lock message"
kill "$LOCKER" 2>/dev/null || true
wait "$LOCKER" 2>/dev/null || true

echo "==> Never through a symlinked runs/ folder"
mv "$DATA/evals/runs" "$WORK/runs-real"
ln -s "$WORK/runs-real" "$DATA/evals/runs"
run "$FREE" --eval personal --case shared
expect_code 1 "runs/ is a symlink"
echo "$ERR" | grep -q "symbolic link" && pass "says why" || fail "symlink message"
rm "$DATA/evals/runs"; mv "$WORK/runs-real" "$DATA/evals/runs"

echo
if [ "$FAILURES" = 0 ]; then echo "All eval CLI checks passed."; else echo "$FAILURES check(s) failed."; exit 1; fi
