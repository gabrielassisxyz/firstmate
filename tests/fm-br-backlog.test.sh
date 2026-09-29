#!/usr/bin/env bash
# tests/fm-br-backlog.test.sh - behavior tests for the `br` backlog backend
# (config/backlog-backend=br, bin/fm-br-backlog.sh).
#
# Every case runs against a scratch firstmate home and a scratch `br` tracker,
# with a `tasks-axi` on PATH that records any call and exits 99, so the suite
# proves the backend never reaches tasks-axi. `ready-landed` is a stub that
# answers `br ready --unassigned --json` widened by the ids a case lists, which
# is the contract bin/fm-br-backlog.sh relies on and nothing more.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BR_BIN=$(command -v br 2>/dev/null) || { echo "skip: br not found"; exit 0; }
JQ_BIN=$(command -v jq 2>/dev/null) || { echo "skip: jq not found"; exit 0; }

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-br-backlog-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ln -s "$BR_BIN" "$FAKEBIN/br"
[ -x "$FAKEBIN/jq" ] || ln -s "$JQ_BIN" "$FAKEBIN/jq"

TASKS_AXI_LOG="$TMP_ROOT/tasks-axi.calls"
cat > "$FAKEBIN/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TASKS_AXI_LOG'
exit 99
SH
chmod +x "$FAKEBIN/tasks-axi"

READY_EXTRA="$TMP_ROOT/ready-landed.extra"
: > "$READY_EXTRA"
cat > "$FAKEBIN/ready-landed" <<SH
#!/usr/bin/env bash
set -eu
[ "\$1" = --repo ] && [ "\$3" = --json ] || { echo "stub ready-landed: unexpected args \$*" >&2; exit 2; }
(cd "\$2" && br ready --unassigned --json) \\
  | jq --rawfile extra '$READY_EXTRA' '. + [(\$extra | split("\n")[] | select(. != "") | {id: ., title: "landed"})]'
SH
chmod +x "$FAKEBIN/ready-landed"

# The spawn and teardown cases need the toolchain the lifecycle scripts run
# under, which a curated base path does not carry; this suite's stubs still
# shadow it.
FM_TEST_AMBIENT_PATH=$PATH
export PATH="$FAKEBIN:$BASE_PATH"
unset FM_READY_LANDED FM_BR_BACKLOG_CONFIG FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE TASKS_AXI_BACKEND
export FM_HOME="$TMP_ROOT/home"
CONFIG="$FM_HOME/config"
DATA="$FM_HOME/data"
mkdir -p "$CONFIG" "$DATA" "$FM_HOME/state"
printf 'br\n' > "$CONFIG/backlog-backend"

TRACKER="$TMP_ROOT/tracker"
fm_git_init_commit "$TRACKER"
(cd "$TRACKER" && br init --prefix t >/dev/null 2>&1) || fail "br init failed in the scratch tracker"
printf '# trackers\nt %s\n' "$TRACKER" > "$CONFIG/br-projects"

ADAPTER="$ROOT/bin/fm-br-backlog.sh"

bead() {  # <title> [description]
  (cd "$TRACKER" && br q "$1" ${2:+--description "$2"}) || fail "br q $1 failed"
}

br_field() {  # <id> <jq-path>
  (cd "$TRACKER" && br show "$1" --format json) | jq -r ".[0] | $2 // empty"
}

# Source the libraries in a child bash and print the probe's verdict.
probe() {  # <id>
  bash -c '
    . "$1/bin/fm-tasks-axi-lib.sh"
    . "$1/bin/fm-backlog-transition-lib.sh"
    fm_backlog_row_probe "$2" "$3"
    printf "%s|%s|%s|" "$FM_BACKLOG_ROW_RESULT" "$FM_BACKLOG_ROW_STATE" "$FM_BACKLOG_ROW_HOLD_KIND"
    if fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE"; then printf dispatchable; else printf refused; fi
  ' _ "$ROOT" "$DATA" "$1"
}

lib_call() {  # <shell snippet>
  bash -c ". '$ROOT/bin/fm-tasks-axi-lib.sh'; . '$ROOT/bin/fm-backlog-transition-lib.sh'; $1"
}

Q=$(bead "Queued work" "Original description")
S=$(bead "Started work")
H=$(bead "Held work")
O=$(bead "Open blocker")
B=$(bead "Blocked by an open bead")
K=$(bead "Closed blocker")
L=$(bead "Blocked by a closed bead")
W=$(bead "Blocked by a landed bead")
P=$(bead "Pending blocker")
(cd "$TRACKER" && br dep add "$B" "$O" && br dep add "$L" "$K" && br dep add "$W" "$P") >/dev/null 2>&1 \
  || fail "br dep add failed"
(cd "$TRACKER" && br close "$K" --reason fixture) >/dev/null 2>&1 || fail "br close $K failed"

# --- backend selection -------------------------------------------------------

out=$(lib_call "fm_backlog_backend_value '$CONFIG'")
assert_equals br "$out" "backlog-backend=br selects the br backend"
lib_call "fm_backlog_backend_manual '$CONFIG'" && fail "the br backend must not read as manual"
lib_call "fm_tasks_axi_backend_available '$CONFIG'" || fail "br on PATH with a tracker listed is available"
EMPTY_CONFIG="$TMP_ROOT/empty-config"
mkdir -p "$EMPTY_CONFIG"
printf 'br\n' > "$EMPTY_CONFIG/backlog-backend"
out=$(lib_call "fm_tasks_axi_backend_available '$EMPTY_CONFIG'" 2>&1) && fail "an absent br-projects must not be available"
assert_contains "$out" "$EMPTY_CONFIG/br-projects" "unavailability names the tracker table"
printf '# nothing yet\n\n' > "$EMPTY_CONFIG/br-projects"
out=$(lib_call "fm_tasks_axi_backend_available '$EMPTY_CONFIG'" 2>&1) && fail "an empty br-projects must not be available"
assert_contains "$out" "$EMPTY_CONFIG/br-projects" "unavailability names the empty tracker table"
pass "config/backlog-backend=br selects br, is not manual, and is available only with a tracker listed"

lib_call "fm_backlog_transition_applies '$CONFIG' '$DATA' task" \
  || fail "the automatic transition gate applies on a br home with no backlog file"
pass "the transition gate applies on a br home without data/backlog.md"

# --- show and probe ----------------------------------------------------------

out=$("$ADAPTER" show "$Q")
assert_equals "  state: queued
  held: no
  blocked: no
  hold_kind: none" "$(printf '%s\n' "$out" | head -4)" "an open unclaimed bead shows as queued, unheld, unblocked"
assert_equals "found|queued no no|none|dispatchable" "$(probe "$Q")" "probe of a queued bead"
pass "show prints the four state lines first and the probe reads a queued bead as dispatchable"

"$ADAPTER" start "$S" >/dev/null || fail "start $S failed"
assert_equals in_progress "$(br_field "$S" .status)" "start claims the bead"
assert_equals firstmate "$(br_field "$S" .assignee)" "start assigns the bead to firstmate"
assert_contains "$("$ADAPTER" show "$S")" "state: in_flight" "a claimed bead shows as in flight"
assert_equals "found|in_flight no no|none|dispatchable" "$(probe "$S")" "probe of a claimed bead"
"$ADAPTER" start "$S" >/dev/null || fail "a repeated start of a bead firstmate already claimed must succeed"
pass "start claims the bead as firstmate and is idempotent"

"$ADAPTER" "done" "$S" --pr https://example.invalid/pull/7 >/dev/null || fail "done $S failed"
assert_equals closed "$(br_field "$S" .status)" "done closes the bead"
assert_contains "$(br_field "$S" .close_reason)" "https://example.invalid/pull/7" "the close reason names the landed PR"
assert_contains "$("$ADAPTER" show "$S")" "state: done" "a closed bead shows as done"
assert_equals "found|done no no|none|refused" "$(probe "$S")" "probe of a closed bead"
"$ADAPTER" "done" "$S" --pr https://example.invalid/pull/7 >/dev/null || fail "a repeated done must succeed"
pass "done closes the bead with the landed ref and is idempotent"

"$ADAPTER" hold "$H" --reason "which way" --kind captain >/dev/null || fail "hold $H failed"
assert_equals deferred "$(br_field "$H" .status)" "hold defers the bead"
out=$("$ADAPTER" show "$H")
assert_contains "$out" "held: yes" "a deferred bead shows as held"
assert_contains "$out" "hold_kind: captain" "a deferred bead is a captain hold"
assert_equals "found|queued yes no|captain|refused" "$(probe "$H")" "probe of a deferred bead"
bash "$ROOT/bin/fm-captain-hold.sh" open "$H" || fail "captain-hold open must report a deferred bead as held"
"$ADAPTER" unhold "$H" >/dev/null || fail "unhold $H failed"
assert_equals open "$(br_field "$H" .status)" "unhold makes the bead open again"
out=$("$ADAPTER" show "$H")
assert_contains "$out" "held: no" "an undeferred bead is not held"
assert_contains "$out" "hold_kind: none" "an undeferred bead carries no hold kind"
code=0
bash "$ROOT/bin/fm-captain-hold.sh" open "$H" || code=$?
expect_code 1 "$code" "captain-hold open on an undeferred bead"
pass "hold defers and unhold undefers, and captain-hold open follows the deferral"

assert_contains "$("$ADAPTER" show "$B")" "blocked: yes" "a bead with an open blocker is blocked"
assert_equals "found|queued no yes|none|refused" "$(probe "$B")" "probe of a blocked bead"
assert_contains "$("$ADAPTER" show "$L")" "blocked: no" "a bead whose blocker closed is not blocked"
assert_contains "$("$ADAPTER" show "$W")" "blocked: yes" "a bead whose blocker has not landed is blocked"
printf '%s\n' "$W" > "$READY_EXTRA"
assert_contains "$("$ADAPTER" show "$W")" "blocked: no" "a bead ready-landed releases is not blocked"
assert_equals "found|queued no no|none|dispatchable" "$(probe "$W")" "probe of a released bead"
: > "$READY_EXTRA"
pass "blocked follows ready-landed's verdict on the same tracker"

# --- absent ids --------------------------------------------------------------

code=0
"$ADAPTER" show zz-1 > "$TMP_ROOT/nf.out" 2> "$TMP_ROOT/nf.err" || code=$?
expect_code 1 "$code" "show of an unlisted prefix"
assert_grep "code: NOT_FOUND" "$TMP_ROOT/nf.out" "an unlisted prefix carries the not-found marker"
assert_equals 1 "$(wc -l < "$TMP_ROOT/nf.err" | tr -d ' ')" "an unlisted prefix prints one stderr line"
assert_grep "'zz-1'" "$TMP_ROOT/nf.err" "the stderr line names the id"
assert_grep "$CONFIG/br-projects" "$TMP_ROOT/nf.err" "the stderr line names the tracker table"
assert_equals "not_found|||refused" "$(probe zz-1 2>/dev/null)" "probe of an unlisted prefix"
assert_equals "not_found|||refused" "$(probe t-zzzz 2>/dev/null)" "probe of an id the tracker lacks"
pass "an unlisted prefix or unknown bead is not_found, and the prefix case names the table"

# --- prefix resolution -------------------------------------------------------

SLUGGED="$TMP_ROOT/daytrace"
fm_git_init_commit "$SLUGGED"
(cd "$SLUGGED" && br init --prefix daytrace >/dev/null 2>&1) || fail "br init failed in the slugged tracker"
SLUG_ID=$(cd "$SLUGGED" && br create "slugged" --slug session-events 2>/dev/null | sed -n 's/.* \(daytrace-session-events-[a-z0-9]*\):.*/\1/p')
[ -n "$SLUG_ID" ] || fail "br create --slug printed no id"
ARCH="$TMP_ROOT/arch"
ARCHIVE="$TMP_ROOT/archive"
fm_git_init_commit "$ARCH"
fm_git_init_commit "$ARCHIVE"
(cd "$ARCH" && br init --prefix arch >/dev/null 2>&1) || fail "br init failed in the arch tracker"
(cd "$ARCHIVE" && br init --prefix archive >/dev/null 2>&1) || fail "br init failed in the archive tracker"
ARCH_ID=$(cd "$ARCH" && br q "arch bead") || fail "br q in arch failed"
ARCHIVE_ID=$(cd "$ARCHIVE" && br q "archive bead") || fail "br q in archive failed"
cp "$CONFIG/br-projects" "$TMP_ROOT/br-projects.saved"
printf 'arch %s\narchive %s\ndaytrace %s\nt %s\n' "$ARCH" "$ARCHIVE" "$SLUGGED" "$TRACKER" > "$CONFIG/br-projects"

assert_contains "$("$ADAPTER" show "$SLUG_ID")" "state:" "a slugged id resolves to its tracker"
code=0
"$ADAPTER" show daytrace-nope > "$TMP_ROOT/dn.out" 2> "$TMP_ROOT/dn.err" || code=$?
expect_code 1 "$code" "show of an id the slugged tracker lacks"
assert_grep "code: NOT_FOUND" "$TMP_ROOT/dn.out" "an id a listed tracker lacks is not found"
assert_no_grep "br-projects" "$TMP_ROOT/dn.err" "an id under a listed prefix is not reported as an unlisted prefix"
assert_contains "$("$ADAPTER" show "$ARCHIVE_ID")" "state:" "the longer overlapping prefix wins"
assert_contains "$("$ADAPTER" show "$ARCH_ID")" "state:" "the shorter overlapping prefix still resolves"
code=0
"$ADAPTER" show "archive-${ARCH_ID#arch-}" > /dev/null 2>&1 || code=$?
expect_code 1 "$code" "an arch hash under archive- goes to the archive tracker"
cp "$TMP_ROOT/br-projects.saved" "$CONFIG/br-projects"
pass "an id resolves by the longest listed prefix, slug or not"

# --- lists -------------------------------------------------------------------

"$ADAPTER" hold "$H" >/dev/null || fail "re-hold $H failed"
held_ids=$("$ADAPTER" list --state held | awk -F, '/^  /{ sub(/^ +/, "", $1); print $1 }')
assert_equals "$H" "$held_ids" "list --state held prints only deferred beads"
printf '%s\n' "$W" > "$READY_EXTRA"
queued_ids=$("$ADAPTER" list --state queued | awk -F, '/^  /{ sub(/^ +/, "", $1); print $1 }' | sort)
landed_ids=$(ready-landed --repo "$TRACKER" --json | jq -r '.[].id' | sort)
assert_equals "$landed_ids" "$queued_ids" "list --state queued prints exactly ready-landed's ids"
assert_contains "$queued_ids" "$W" "the queued list carries the landed widening"
: > "$READY_EXTRA"
pass "held lists deferred beads and queued is exactly ready-landed's answer"

PATH_SANS_READY=$(fm_test_base_path_sans "$FAKEBIN:$BASE_PATH" ready-landed)
code=0
out=$(PATH="$PATH_SANS_READY" "$ADAPTER" list --state queued 2>&1) || code=$?
expect_code 2 "$code" "list --state queued without ready-landed"
assert_contains "$out" "ready-landed" "the refusal names ready-landed"
code=0
out=$(PATH="$PATH_SANS_READY" "$ADAPTER" show "$B" 2>&1) || code=$?
expect_code 2 "$code" "show of a bead with an open blocker without ready-landed"
assert_contains "$out" "ready-landed" "the show refusal names ready-landed"
assert_not_contains "$out" "blocked: yes" "a bead is not reported blocked when ready-landed could not be asked"
pass "the queued list and a blocker read refuse by name when ready-landed is unavailable"

# --- reopen and update ---------------------------------------------------------

R=$(bead "Reopened work")
"$ADAPTER" start "$R" >/dev/null || fail "start $R failed"
"$ADAPTER" reopen "$R" >/dev/null || fail "reopen $R failed"
assert_equals open "$(br_field "$R" .status)" "reopen returns the bead to open"
assert_equals "" "$(br_field "$R" .assignee)" "reopen drops the assignee"
printf 'First line\n\nDeliverable of the finished work: PR x\n' > "$TMP_ROOT/body"
"$ADAPTER" update "$Q" --body-file "$TMP_ROOT/body" --archive-body >/dev/null || fail "update $Q failed"
assert_equals "$(cat "$TMP_ROOT/body")" "$(br_field "$Q" .notes)" "update --body-file replaces the bead's notes"
assert_equals "Original description" "$(br_field "$Q" .description)" "update leaves the description alone"
shown=$("$ADAPTER" show "$Q" | sed -n 's/^  body: //p' | jq -r .)
assert_equals "$(cat "$TMP_ROOT/body")" "$shown" "show prints the notes back as the body"
"$ADAPTER" update "$Q" --pr https://example.invalid/pull/9 >/dev/null || fail "update --pr $Q failed"
comments=$(cd "$TRACKER" && br comments "$Q" --json | jq -r '.[].text')
assert_contains "$comments" "https://example.invalid/pull/9" "update --pr records the deliverable as a comment"
pass "reopen releases the claim, and the body round-trips through the bead's notes"

A=$(bead "Captain call")
bash "$ROOT/bin/fm-captain-hold.sh" hold "$A" --reason "pick one" >/dev/null \
  || fail "captain-hold hold failed on a br bead"
assert_equals deferred "$(br_field "$A" .status)" "captain-hold hold defers the bead"
printf 'Go with option A.\n' > "$TMP_ROOT/decision"
bash "$ROOT/bin/fm-captain-hold.sh" answer "$A" --decision-file "$TMP_ROOT/decision" >/dev/null \
  || fail "captain-hold answer failed on a br bead"
assert_equals closed "$(br_field "$A" .status)" "captain-hold answer closes the bead"
assert_contains "$(br_field "$A" .notes)" "Go with option A." "the captain's words are recorded on the bead"
pass "captain-hold hold and answer run end to end on a br bead"

# --- spawn preflight and dispatch ----------------------------------------------

AMBIENT_PATH=$FM_TEST_AMBIENT_PATH

# A spawn case: this suite's home, a real project clone with a pooled worktree,
# and stubs for every tool the spawn path shells out to. The tmux stub marks
# endpoint creation so a refusal can be shown to precede it.
make_spawn_case() {  # <name> <id>
  local case_dir=$TMP_ROOT/$1 id=$2 fakebin
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$DATA/$id"
  cat > "$DATA/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise br backlog dispatch for $id.

## Firstmate spec
Verify the dispatch transition on the br backend.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *new-window*) : > "$case_dir/task-endpoint-created" ;;
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  git -C "$case_dir/project" worktree add --quiet -b pooled "$case_dir/wt"
  printf '%s\n' "$case_dir"
}

run_spawn() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  mkdir -p "$case_dir/user-home"
  FM_ROOT_OVERRIDE="$ROOT" HOME="$case_dir/user-home" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" CLAUDE_CONFIG_DIR='' \
    PATH="$case_dir/fakebin:$FAKEBIN:$AMBIENT_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --mode no-mistakes --yolo off 2>&1
}

printf '%s\n' claude > "$CONFIG/crew-harness"
touch "$FM_HOME/state/.last-watcher-beat"

D=$(bead "Dispatched work")
case_dir=$(make_spawn_case spawn-ok "$D")
out=$(run_spawn "$case_dir" "$D") || fail "spawn of a queued bead failed: $out"
assert_contains "$out" "spawned $D" "spawn of a queued bead reports success"
assert_present "$FM_HOME/state/$D.meta" "spawn of a queued bead publishes its record"
assert_equals in_progress "$(br_field "$D" .status)" "the dispatch transition claims the bead"
assert_equals firstmate "$(br_field "$D" .assignee)" "the dispatch transition claims the bead as firstmate"
pass "spawn passes the backlog preflight for a queued bead and claims it"

for refused in "$H:queued yes no:deferred" "$B:queued no yes:blocked"; do
  id=${refused%%:*}
  rest=${refused#*:}
  state=${rest%%:*}
  label=${rest#*:}
  case_dir=$(make_spawn_case "spawn-$label" "$id")
  code=0
  out=$(run_spawn "$case_dir" "$id") || code=$?
  [ "$code" -ne 0 ] || fail "spawn accepted a $label bead"
  assert_contains "$out" "backlog item $id is not dispatchable in state $state; refusing before creating its endpoint" \
    "a $label bead is refused with the held-row message shape"
  assert_absent "$FM_HOME/state/$id.meta" "a $label refusal published a task record"
  assert_absent "$case_dir/task-endpoint-created" "a $label refusal created an endpoint"
  pass "spawn refuses a $label bead before creating any endpoint"
done

# --- teardown close ------------------------------------------------------------

TD_ROOT="$TMP_ROOT/teardown"
mkdir -p "$TD_ROOT"
TD_BIN=$(fm_fakebin "$TD_ROOT")
fm_fake_exit0 "$TD_BIN" treehouse tmux gh no-mistakes
cat > "$TD_BIN/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
chmod +x "$TD_BIN/gh-axi"

# Tears down a landed ship for <id> in its own scratch project and prints the
# teardown's output.
run_teardown() {  # <id>
  local id=$1 td="$TD_ROOT/$1"
  mkdir -p "$td/state"
  touch "$td/state/.last-watcher-beat"
  git init -q --bare "$td/origin.git"
  git -C "$td/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$td/origin.git" "$td/seed" 2>/dev/null
  git -C "$td/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$td/seed" push -q origin main
  git clone -q "$td/origin.git" "$td/project"
  git -C "$td/project" remote set-head origin main 2>/dev/null || true
  git -C "$td/project" worktree add -q -b "fm/$id" "$td/wt" main
  fm_write_meta "$td/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$td/wt" \
    "project=$td/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=br-backlog-test-$id" \
    "pr=https://github.com/example/repo/pull/7"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$td/state" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" PATH="$TD_BIN:$FAKEBIN:$AMBIENT_PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1
}

T=$(bead "Landed work")
"$ADAPTER" start "$T" >/dev/null || fail "start $T failed"
out=$(run_teardown "$T") || fail "teardown of a landed task failed: $out"
assert_equals closed "$(br_field "$T" .status)" "teardown closes the bead"
assert_contains "$(br_field "$T" .close_reason)" "https://github.com/example/repo/pull/7" \
  "the close reason names the landed PR"
assert_absent "$TD_ROOT/$T/state/$T.backlog-close" "teardown retires its pending-close record"
pass "teardown of a landed task closes the bead with the PR in its close reason"

assert_contains "$out" "Backlog: $T is closed in the br tracker at $TRACKER. Run bin/fm-tasks-axi.sh ready" \
  "the closed line names the tracker the bead lives in"
assert_not_contains "$out" "tasks-axi backend" "the closed line does not claim a tasks-axi backend"
pass "teardown reports the close in the bead's br tracker"

R=$(bead "Retained work")
"$ADAPTER" start "$R" >/dev/null || fail "start $R failed"
"$ADAPTER" hold "$R" --reason "captain call" --kind captain >/dev/null || fail "hold $R failed"
out=$(run_teardown "$R") || fail "teardown of a held task failed: $out"
assert_contains "$out" "Backlog: $R stays open in the br tracker at $TRACKER, still held for the captain" \
  "the retained line names the tracker the bead lives in"
pass "teardown reports a retained captain call in the bead's br tracker"

assert_equals "$TRACKER" "$("$ADAPTER" where "$Q")" "where prints the tracker a listed id resolves to"
out=$("$ADAPTER" where "zz-unlisted" 2>/dev/null) && fail "where resolved an unlisted prefix: $out"
assert_contains "$out" "code: NOT_FOUND" "where reports an unlisted prefix as NOT_FOUND"
pass "where resolves an id to its tracker and refuses an unlisted prefix"

# --- session-start digest --------------------------------------------------------

mkdir -p "$TMP_ROOT/session-user-home"
out=$(HOME="$TMP_ROOT/session-user-home" FM_ROOT_OVERRIDE="$ROOT" PATH="$FAKEBIN:$AMBIENT_PATH" \
  timeout 120 "$ROOT/bin/fm-session-start.sh" 2>&1) || fail "session start failed on a br home: $out"
digest=$(printf '%s\n' "$out" | sed -n '/^ready queued (dispatchable now):/,/^(shown/p')
assert_contains "$digest" "  $Q,queued" "the digest's ready list carries a queued bead"
assert_contains "$(printf '%s\n' "$out" | sed -n '/^blocked queued:/,/^$/p')" "  $B,queued" \
  "the digest's blocked list carries a blocked bead"
pass "the session-start digest lists the br queue without a backlog file"

[ ! -s "$TASKS_AXI_LOG" ] || fail "the br backend called tasks-axi: $(cat "$TASKS_AXI_LOG")"
pass "no case reached tasks-axi"
