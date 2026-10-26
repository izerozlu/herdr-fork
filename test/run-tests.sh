#!/usr/bin/env bash
# Offline tests: herdr-fork against a stand-in herdr-worker, and the two hooks.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fi; }
has() { case "$2" in *"$3"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL %s\n  missing: %s\n  in: %s\n' "$1" "$3" "$2" ;; esac; }

# Stand-in herdr-worker: print each argument on its own line.
cat > "$tmp/herdr-worker" <<'W'
#!/usr/bin/env bash
printf '%s\n' "$@"
W
chmod +x "$tmp/herdr-worker"
export HERDR_WORKER=$tmp/herdr-worker CLAUDE_CONFIG_DIR=$tmp/claude
proj=$tmp/proj; mkdir -p "$proj/.worktrees/fx"; proj=$(cd "$proj" && pwd -P)
enc() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
mkdir -p "$tmp/claude/projects/$(enc "$proj")"
echo '{}' > "$tmp/claude/projects/$(enc "$proj")/sid-1.jsonl"
fork() { (cd "$proj" && CLAUDE_CODE_SESSION_ID=${SID-sid-1} "$root/bin/herdr-fork" "$@"); }

out=$(fork fx "fix the docs"); code=$?
check "fork exits 0" "$code" 0
check "default args" "$(sed -n 2p <<<"$out")" "--permission-mode auto --resume sid-1 --fork-session"
check "name passed" "$(sed -n 3p <<<"$out")" fx
has "task passed" "$out" "fix the docs"
has "task says fork" "$out" "You are a fork of the conversation above"

out=$(fork -a "--model opus" fx "t")
check "-a replaces default" "$(sed -n 2p <<<"$out")" "--model opus --resume sid-1 --fork-session"

out=$(fork -C .worktrees/fx fx "t")
check "-C passed on" "$(sed -n 3,4p <<<"$out" | tr '\n' ' ')" "-C .worktrees/fx "

err=$(SID= fork fx t 2>&1); code=$?
check "no session id refused" "$code" 2; has "no session id message" "$err" CLAUDE_CODE_SESSION_ID
err=$(SID=sid-missing fork fx t 2>&1); code=$?
check "missing transcript refused" "$code" 2
err=$(fork fx 2>&1); code=$?
check "missing task refused" "$code" 2
err=$(fork -C nope fx t 2>&1); code=$?
check "bad -C refused" "$code" 2
err=$(cd "$proj" && CLAUDE_CODE_SESSION_ID=sid-1 HERDR_WORKER= PATH=/usr/bin:/bin "$root/bin/herdr-fork" fx t 2>&1); code=$?
check "no herdr-worker refused" "$code" 2; has "no herdr-worker message" "$err" herdr-lock

guard() { HERDR_WORKSPACE_ID=${WS-w1} "$root/scripts/fork-guard" <<<"$1"; }
out=$(guard '{"tool_name":"Agent","tool_input":{"subagent_type":"fork","prompt":"x"}}')
check "guard denies fork" "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" deny
has "guard points to herdr-fork" "$out" "herdr-fork <name>"
check "guard allows other agents" "$(guard '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}')" ""
check "guard allows no type" "$(guard '{"tool_name":"Agent","tool_input":{}}')" ""
check "guard off outside Herdr" "$(WS= guard '{"tool_input":{"subagent_type":"fork"}}')" ""

out=$(HERDR_WORKSPACE_ID=w1 "$root/scripts/fork-rule" <<<'{}')
has "rule inside Herdr" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "herdr-fork"
check "no rule outside Herdr" "$(HERDR_WORKSPACE_ID= "$root/scripts/fork-rule" <<<'{}')" ""

# fork-tab: a stand-in herdr logs its calls.
cat > "$tmp/herdr" <<'H'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "tab create") [ -n "${HERDR_FAIL:-}" ] && exit 1; echo '{"result":{"root_pane":{"pane_id":"w1:p9"},"tab":{"tab_id":"w1:t9"}}}' ;;
esac
H
chmod +x "$tmp/herdr"
export HERDR_LOG=$tmp/herdr.log
job=$tmp/job; mkdir -p "$job"
tabhook() { : > "$HERDR_LOG"; HERDR_BIN_PATH=$tmp/herdr HERDR_WORKSPACE_ID=${WS-w1} CLAUDE_JOB_DIR=$job "$root/scripts/fork-tab" <<<'{"session_id":"abcd1234-0000","cwd":"/work/proj"}' 2>&1; }
tabhook >/dev/null
check "no tab for plain bg session" "$(cat "$HERDR_LOG")" ""
touch "$job/parent-transcript.jsonl"
tabhook >/dev/null
check "fork opens tab" "$(sed -n 1p "$HERDR_LOG")" "tab create --workspace w1 --cwd /work/proj --label fork abcd1234 --focus"
check "fork tab attaches" "$(sed -n 2p "$HERDR_LOG")" "pane run w1:p9 claude attach abcd1234"
WS= tabhook >/dev/null
check "no tab outside Herdr" "$(cat "$HERDR_LOG")" ""
out=$(HERDR_FAIL=1 tabhook); code=$?
check "herdr failure does not fail hook" "$code" 0
has "herdr failure note" "$out" "could not open a tab"

if command -v claude >/dev/null; then
  out=$(claude plugin validate "$root" 2>&1); code=$?
  check "claude plugin validate" "$code" 0 || printf '%s\n' "$out"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
