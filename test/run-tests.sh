#!/usr/bin/env bash
# Offline tests: herdr-fork and the hooks, against stand-in herdr and claude commands.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fi; }
has() { case "$2" in *"$3"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL %s\n  missing: %s\n  in: %s\n' "$1" "$3" "$2" ;; esac; }

# Stand-in herdr for herdr-fork: logs each call (one argument per line, then ---)
# and answers like Herdr. FORK_START=fail|notready|trust changes `agent start`.
cat > "$tmp/herdr-f" <<'H'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; echo ---; } >> "$FORK_LOG"
case "$1 $2" in
  "agent list") echo '{"result":{"agents":[{"name":"taken","workspace_id":"w9","pane_id":"w9:p1","tab_id":"w9:t1"},{"name":"me","workspace_id":"w1","pane_id":"w1:p1","tab_id":"w1:t1"},{"name":"other","workspace_id":"w1","pane_id":"w1:p5","tab_id":"w1:t5","agent_status":"idle","cwd":"/x"}]}}' ;;
  "tab create") echo '{"result":{"root_pane":{"pane_id":"w1:p9"},"tab":{"tab_id":"w1:t9"}}}' ;;
  "agent start")
    case ${FORK_START:-} in
      fail) echo '{"error":{"code":"boom"}}' >&2; exit 1 ;;
      notready|trust) echo '{"error":{"code":"agent_not_ready"}}' >&2; exit 1 ;;
    esac ;;
  "pane read") [ "${FORK_START:-}" = trust ] && echo "Do you trust this folder?" ;;
esac
exit 0
H
chmod +x "$tmp/herdr-f"
export CLAUDE_CONFIG_DIR=$tmp/claude FORK_LOG=$tmp/fork.log
proj=$tmp/proj; mkdir -p "$proj/.worktrees/fx"; proj=$(cd "$proj" && pwd -P)
enc() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
mkdir -p "$tmp/claude/projects/$(enc "$proj")"
echo '{}' > "$tmp/claude/projects/$(enc "$proj")/sid-1.jsonl"
fork() { : > "$FORK_LOG"; (cd "$proj" && HERDR_BIN_PATH=$tmp/herdr-f HERDR_WORKSPACE_ID=${WS-w1} HERDR_PANE_ID=w1:p1 CLAUDE_CODE_SESSION_ID=${SID-sid-1} "$root/bin/herdr-fork" "$@"); }
call() { awk -v want="$1 " 'BEGIN{RS="---\n"} { gsub(/\n/, " "); if (index($0, want) == 1) printf "%s", $0 }' "$FORK_LOG"; }

out=$(fork fx "fix the docs"); code=$?
check "fork exits 0" "$code" 0
check "fork opens tab" "$(call "tab")" "tab create --workspace w1 --cwd $proj --label fx --no-focus "
check "default args" "$(call "agent start")" "agent start fx --kind claude --pane w1:p9 -- --permission-mode auto --resume sid-1 --fork-session "
has "task sent" "$(call "agent prompt")" "fix the docs"
has "task says fork" "$(call "agent prompt")" "You are a fork of the conversation above"
has "task asks for report" "$(call "agent prompt")" "/tmp/herd/fx.md"
has "fork prints summary" "$out" "fork=fx session=sid-1 tab=w1:t9"

fork -a "--model opus" fx "t" >/dev/null
check "-a replaces default" "$(call "agent start")" "agent start fx --kind claude --pane w1:p9 -- --model opus --resume sid-1 --fork-session "

fork -C .worktrees/fx fx "t" >/dev/null
has "-C sets tab folder" "$(call "tab")" "--cwd $proj/.worktrees/fx "

err=$(SID= fork fx t 2>&1); code=$?
check "no session id refused" "$code" 2; has "no session id message" "$err" CLAUDE_CODE_SESSION_ID
err=$(WS= fork fx t 2>&1); code=$?
check "outside Herdr refused" "$code" 2; has "outside Herdr message" "$err" HERDR_WORKSPACE_ID
err=$(SID=sid-missing fork fx t 2>&1); code=$?
check "missing transcript refused" "$code" 2
err=$(fork fx 2>&1); code=$?
check "missing task refused" "$code" 2
err=$(fork -C nope fx t 2>&1); code=$?
check "bad -C refused" "$code" 2
err=$(fork -C .. fx t 2>&1); code=$?
check "-C outside folder refused" "$code" 2
err=$(fork taken t 2>&1); code=$?
check "name in use refused" "$code" 2; has "name in use message" "$err" "already in use"
check "name in use opens no tab" "$(call "tab")" ""

err=$(FORK_START=fail fork fx t 2>&1); code=$?
check "start failure exits 1" "$code" 1
check "start failure closes tab" "$(call "tab close")" "tab close w1:t9 "
err=$(FORK_START=trust fork fx t 2>&1); code=$?
check "trust prompt exits 3" "$code" 3; has "trust prompt message" "$err" "folder-trust prompt"
has "trust prompt keeps task" "$(cat /tmp/herd/fx.task)" "You are a fork"
check "trust prompt sends no task" "$(call "agent prompt")" ""
err=$(FORK_START=notready fork fx t 2>&1); code=$?
check "blocked start exits 3" "$code" 3; has "blocked start message" "$err" "blocked during startup"
rm -f /tmp/herd/fx.task

check "list shows this workspace" "$(fork list)" "$(printf 'other\tw1:t5\tidle\t/x')"
out=$(fork close other); code=$?
check "close exits 0" "$code" 0; check "close closes tab" "$(call "tab close")" "tab close w1:t5 "
err=$(fork close taken 2>&1); code=$?
check "close other workspace refused" "$code" 2
err=$(fork close me 2>&1); code=$?
check "close own tab refused" "$code" 2
err=$(fork close nobody 2>&1); code=$?
check "close unknown refused" "$code" 2

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
case "$1 $2" in "agent list"|"pane list") ;; *) echo "$*" >> "$HERDR_LOG" ;; esac
case "$1 $2" in
  "pane list") echo "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\"},{\"pane_id\":\"w3:p4\"},{\"pane_id\":\"w6:p2\",\"workspace_id\":\"w6\",\"focused\":${FOCUSED:-false}}]}}" ;;
  "tab create") [ -n "${HERDR_FAIL:-}" ] && exit 1; echo '{"result":{"root_pane":{"pane_id":"w1:p9"},"tab":{"tab_id":"w1:t9"}}}' ;;
  "pane split") [ -n "${HERDR_FAIL:-}" ] && exit 1; echo '{"result":{"pane":{"pane_id":"w1:p7"}}}' ;;
  "workspace create") echo '{"result":{"root_pane":{"pane_id":"w2:p1"},"workspace":{"workspace_id":"w2"}}}' ;;
  "agent list") echo '{"result":{"agents":[{"agent_session":{"value":"other-sid"},"workspace_id":"w5","pane_id":"w5:p1"},{"agent_session":{"value":"parent-sid"},"workspace_id":"w3","pane_id":"w3:p4"}]}}' ;;
esac
H
chmod +x "$tmp/herdr"
export HERDR_LOG=$tmp/herdr.log
job=$tmp/job; mkdir -p "$job"
tabhook() { : > "$HERDR_LOG"; FOCUSED=${FOCUSED-false} HERDR_BIN_PATH=$tmp/herdr HERDR_WORKSPACE_ID=${WS-w1} HERDR_PANE_ID=${PANE-w1:p1} HERDR_FORK_LAYOUT=${LAYOUT-} CLAUDE_PLUGIN_OPTION_LAYOUT=${OPTION-} HERDR_FORK_ON_CLOSE=${ONCLOSE-} CLAUDE_PLUGIN_OPTION_ONCLOSE=${ONCLOSE_OPT-} CLAUDE_JOB_DIR=$job "$root/scripts/fork-open" <<<'{"session_id":"abcd1234-0000","cwd":"/work/proj"}' 2>&1; }
tabhook >/dev/null
check "no tab for plain bg session" "$(cat "$HERDR_LOG")" ""
touch "$job/parent-transcript.jsonl"
tabhook >/dev/null
check "fork splits right by default" "$(sed -n 1p "$HERDR_LOG")" "pane split w1:p1 --direction right --cwd /work/proj --focus"
check "fork split attaches" "$(sed -n 2p "$HERDR_LOG")" "pane run w1:p7 HERDR_FORK_ON_CLOSE=stop '$root/scripts/fork-attach' abcd1234"
LAYOUT=down tabhook >/dev/null
check "layout down" "$(sed -n 1p "$HERDR_LOG")" "pane split w1:p1 --direction down --cwd /work/proj --focus"
LAYOUT=tab tabhook >/dev/null
check "layout tab" "$(sed -n 1p "$HERDR_LOG")" "tab create --workspace w1 --cwd /work/proj --label fork abcd1234 --focus"
check "fork tab attaches" "$(sed -n 2p "$HERDR_LOG")" "pane run w1:p9 HERDR_FORK_ON_CLOSE=stop '$root/scripts/fork-attach' abcd1234"
LAYOUT=left tabhook >/dev/null
check "layout left splits right" "$(sed -n 1p "$HERDR_LOG")" "pane split w1:p1 --direction right --cwd /work/proj --focus"
check "layout left swaps" "$(sed -n 2p "$HERDR_LOG")" "pane swap --source-pane w1:p7 --target-pane w1:p1"
check "layout left attaches" "$(sed -n 3p "$HERDR_LOG")" "pane run w1:p7 HERDR_FORK_ON_CLOSE=stop '$root/scripts/fork-attach' abcd1234"
LAYOUT=up tabhook >/dev/null
check "layout up splits down" "$(sed -n 1p "$HERDR_LOG")" "pane split w1:p1 --direction down --cwd /work/proj --focus"
check "layout up swaps" "$(sed -n 2p "$HERDR_LOG")" "pane swap --source-pane w1:p7 --target-pane w1:p1"
LAYOUT=right tabhook >/dev/null
check "layout right does not swap" "$(grep -c swap "$HERDR_LOG")" 0
LAYOUT=workspace tabhook >/dev/null
check "layout workspace" "$(sed -n 1p "$HERDR_LOG")" "workspace create --cwd /work/proj --label fork abcd1234 --focus"
check "workspace attaches" "$(sed -n 2p "$HERDR_LOG")" "pane run w2:p1 HERDR_FORK_ON_CLOSE=stop '$root/scripts/fork-attach' abcd1234"
OPTION=down tabhook >/dev/null
check "plugin option used" "$(sed -n 1p "$HERDR_LOG")" "pane split w1:p1 --direction down --cwd /work/proj --focus"
OPTION=down LAYOUT=tab tabhook >/dev/null
check "env var beats plugin option" "$(sed -n 1p "$HERDR_LOG")" "tab create --workspace w1 --cwd /work/proj --label fork abcd1234 --focus"
PANE= LAYOUT=workspace tabhook >/dev/null
check "workspace needs no pane id" "$(sed -n 1p "$HERDR_LOG")" "workspace create --cwd /work/proj --label fork abcd1234 --focus"
ONCLOSE=remove tabhook >/dev/null
has "onClose env passed to pane" "$(cat "$HERDR_LOG")" "HERDR_FORK_ON_CLOSE=remove '"
ONCLOSE_OPT=keep tabhook >/dev/null
has "onClose option passed to pane" "$(cat "$HERDR_LOG")" "HERDR_FORK_ON_CLOSE=keep '"
out=$(ONCLOSE=nuke tabhook)
has "bad onClose warns" "$out" "is not stop, remove or keep"
has "bad onClose uses stop" "$(cat "$HERDR_LOG")" "HERDR_FORK_ON_CLOSE=stop '"
PANE= tabhook >/dev/null
check "no pane id falls back to tab" "$(sed -n 1p "$HERDR_LOG")" "tab create --workspace w1 --cwd /work/proj --label fork abcd1234 --focus"
out=$(LAYOUT=sideways tabhook)
has "bad layout warns" "$out" "is not right, left, down, up, tab or workspace"
check "bad layout uses right" "$(sed -n 1p "$HERDR_LOG")" "pane split w1:p1 --direction right --cwd /work/proj --focus"
echo '{"forkParentSessionId":"parent-sid"}' > "$job/state.json"
tabhook >/dev/null
check "fork finds forking pane" "$(sed -n 1p "$HERDR_LOG")" "pane split w3:p4 --direction right --cwd /work/proj --focus"
LAYOUT=tab tabhook >/dev/null
check "fork finds forking workspace" "$(sed -n 1p "$HERDR_LOG")" "tab create --workspace w3 --cwd /work/proj --label fork abcd1234 --focus"
PANE= tabhook >/dev/null
check "found pane beats missing env" "$(sed -n 1p "$HERDR_LOG")" "pane split w3:p4 --direction right --cwd /work/proj --focus"
echo '{"forkParentSessionId":"gone-sid"}' > "$job/state.json"
tabhook >/dev/null
check "unknown parent keeps env pane" "$(sed -n 1p "$HERDR_LOG")" "pane split w1:p1 --direction right --cwd /work/proj --focus"
echo '{"forkParentSessionId":"cont-sid"}' > "$job/state.json"
mkdir -p "$tmp/claude/projects/p"; echo '{"type":"continued-in","sessionId":"parent-sid","continuedInSessionId":"cont-sid"}' > "$tmp/claude/projects/p/parent-sid.jsonl"
tabhook >/dev/null
check "walks back a continued session" "$(sed -n 1p "$HERDR_LOG")" "pane split w3:p4 --direction right --cwd /work/proj --focus"
echo '{"forkParentSessionId":"child-sid"}' > "$job/state.json"
mkdir -p "$tmp/claude/jobs/child-si"; echo '{"forkParentSessionId":"cont-sid"}' > "$tmp/claude/jobs/child-si/state.json"
tabhook >/dev/null
check "walks back a fork of a fork" "$(sed -n 1p "$HERDR_LOG")" "pane split w3:p4 --direction right --cwd /work/proj --focus"
echo '{"forkParentSessionId":"gone-sid"}' > "$job/state.json"
FOCUSED=true tabhook >/dev/null
check "unknown parent uses focused pane" "$(sed -n 1p "$HERDR_LOG")" "pane split w6:p2 --direction right --cwd /work/proj --focus"
FOCUSED=true LAYOUT=tab tabhook >/dev/null
check "unknown parent uses focused workspace" "$(sed -n 1p "$HERDR_LOG")" "tab create --workspace w6 --cwd /work/proj --label fork abcd1234 --focus"
echo '{"forkParentSessionId":"parent-sid"}' > "$job/state.json"
FOCUSED=true tabhook >/dev/null
check "known parent beats focused pane" "$(sed -n 1p "$HERDR_LOG")" "pane split w3:p4 --direction right --cwd /work/proj --focus"
rm -r "$tmp/claude/projects/p" "$tmp/claude/jobs"
rm "$job/state.json"
PANE=w1:gone tabhook >/dev/null
check "closed env pane falls back to tab" "$(sed -n 1p "$HERDR_LOG")" "tab create --workspace w1 --cwd /work/proj --label fork abcd1234 --focus"
WS= tabhook >/dev/null
check "no tab outside Herdr" "$(cat "$HERDR_LOG")" ""
out=$(HERDR_FAIL=1 tabhook); code=$?
check "herdr failure does not fail hook" "$code" 0
has "herdr failure note" "$out" "could not open a right pane"

# fork-attach: a stand-in claude logs its calls; attach waits until it is signalled.
cat > "$tmp/claude-bin" <<'C'
#!/usr/bin/env bash
echo "$*" >> "$CLAUDE_LOG"
if [ "$1" = attach ]; then [ -n "${ATTACH_EXIT:-}" ] && exit 0; sleep 1; fi
exit 0
C
chmod +x "$tmp/claude-bin"
export CLAUDE_LOG=$tmp/claude.log
attach() {  # attach [signal]: run fork-attach, send it the signal, list the calls
  : > "$CLAUDE_LOG"
  HERDR_FORK_CLAUDE=$tmp/claude-bin HERDR_FORK_ON_CLOSE=${ONCLOSE-} "$root/scripts/fork-attach" abcd1234 &
  local pid=$!
  if [ -n "${1:-}" ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q attach "$CLAUDE_LOG" && break; sleep 0.2; done
    kill -"$1" "$pid"
  fi
  wait "$pid" 2>/dev/null
  sleep 0.5  # the cleanup runs detached
  tr '\n' ';' < "$CLAUDE_LOG"
}
check "pane close stops fork" "$(attach HUP)" "attach abcd1234;stop abcd1234;"
check "pane kill stops fork" "$(attach TERM)" "attach abcd1234;stop abcd1234;"
check "remove stops and removes" "$(ONCLOSE=remove attach HUP)" "attach abcd1234;stop abcd1234;rm abcd1234;"
check "keep leaves fork" "$(ONCLOSE=keep attach HUP)" "attach abcd1234;"
check "leaving attach leaves fork" "$(ATTACH_EXIT=1 attach)" "attach abcd1234;"

if command -v claude >/dev/null; then
  out=$(claude plugin validate "$root" 2>&1); code=$?
  check "claude plugin validate" "$code" 0 || printf '%s\n' "$out"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
