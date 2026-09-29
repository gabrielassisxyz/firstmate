#!/usr/bin/env bash
# Behavior tests for named worker accounts (config/accounts, --account;
# bin/fm-accounts-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then runs that command in a synthetic pane whose
# ambient environment names another Claude store. The fake claude records the
# HOME and CLAUDE_CONFIG_DIR it was started with, so the account is observed
# from inside the worker process and not only in the launch text.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-account)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

# new_case <name> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
{
  printf 'HOME=%s\n' "\${HOME-unset}"
  printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}"
} > '$CASE/claude-worker'
SH
  chmod +x "$FAKEBIN/claude"
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$CASE/profile-a" "$CASE/profile-b" "$CASE/codex-a"
  : > "$CASE/launch.log"
}

# write_accounts: the placeholder table every case starts from.
write_accounts() {
  cat > "$HOME_DIR/config/accounts" <<EOF
# <name> <harness> [default] KEY=VALUE [KEY=VALUE ...]

claude-a   claude  default HOME=$CASE/profile-a
claude-b   claude          HOME=$CASE/profile-b
codex-a    codex   default HOME=$CASE/codex-a CODEX_HOME=$CASE/codex-a/.codex
EOF
}

# spawn_ship <id> [fm-spawn args...]: a ship spawn whose invoking process
# forwards its own Claude store, so skipping that forward is observable.
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  mkdir -p "$CASE/ambient-claude"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

# run_pane: execute the recorded launch in a pane that carries another store.
run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

# normalized_launch: the recorded launch with the per-case directory and the
# per-spawn operational message id replaced, so two cases compare byte for byte.
normalized_launch() {
  sed -e "s#$CASE#CASE#g" -e 's#operational-inbox/[0-9a-f-]*\.msg#operational-inbox/MSG.msg#g' "$CASE/launch.log"
}

# assert_refused_before_launch <id> <out> <needle>
assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
  [ -z "$(find "$HOME_DIR/state" -name "$id.*" -print -quit)" ] || fail "a refused spawn must not leave task state: $(ls "$HOME_DIR/state")"
}

test_explicit_account_runs_the_worker_under_its_home() {
  local out rc id=acct-b
  new_case explicit
  write_accounts
  out=$(spawn_ship "$id" --harness claude --account claude-b); rc=$?
  expect_code 0 "$rc" "a spawn on a declared Claude account should succeed: $out"
  assert_contains "$(cat "$CASE/launch.log")" "env HOME='$CASE/profile-b' " \
    "the launch should carry the account's environment"
  assert_not_contains "$(cat "$CASE/launch.log")" "CLAUDE_CONFIG_DIR=" \
    "an account that sets HOME must replace the CLAUDE_CONFIG_DIR forward"
  assert_contains "$out" "account=claude-b" "the spawned line should name the account"
  assert_grep "account=claude-b" "$HOME_DIR/state/$id.meta" "the task record should name the account"
  assert_contains "$(cat "$CASE/profile-b/.claude.json" 2>/dev/null)" "$WT" \
    "workspace trust should be registered in the account's own store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the forwarded store must not receive the trust entry"
  run_pane
  assert_grep "HOME=$CASE/profile-b" "$CASE/claude-worker" "the worker should run under the account's HOME"
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" \
    "a pane's ambient CLAUDE_CONFIG_DIR must not outrank the account's HOME"
  pass "--account selects its line, prefixes its environment, and the worker runs under its HOME"
}

test_default_line_applies_without_account() {
  local out rc id=acct-default
  new_case default
  write_accounts
  out=$(spawn_ship "$id" --harness claude); rc=$?
  expect_code 0 "$rc" "a spawn with a default Claude account should succeed: $out"
  assert_contains "$(cat "$CASE/launch.log")" "env HOME='$CASE/profile-a' " \
    "the harness's default line should apply without --account"
  assert_grep "account=claude-a" "$HOME_DIR/state/$id.meta" "the task record should name the default account"
  run_pane
  assert_grep "HOME=$CASE/profile-a" "$CASE/claude-worker" "the worker should run under the default account's HOME"
  pass "a default line applies to its harness when no --account is given"
}

test_no_default_keeps_the_launch_byte_identical() {
  local out rc id=acct-none baseline
  new_case none-absent
  out=$(spawn_ship "$id" --harness claude); rc=$?
  expect_code 0 "$rc" "a spawn with no accounts table should succeed: $out"
  baseline=$(normalized_launch)
  assert_not_contains "$out" "account=" "a spawn with no account must not report one"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "a task record with no account must carry no account="

  new_case none-present
  cat > "$HOME_DIR/config/accounts" <<EOF
claude-b   claude          HOME=$CASE/profile-b
codex-a    codex   default HOME=$CASE/codex-a
EOF
  out=$(spawn_ship "$id" --harness claude); rc=$?
  expect_code 0 "$rc" "a spawn with no default for its harness should succeed: $out"
  [ "$(normalized_launch)" = "$baseline" ] \
    || fail "with no default line for the harness the launch must be byte-identical to the no-table launch"$'\n'"$(diff <(printf '%s\n' "$baseline") <(normalized_launch))"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "a task record with no account must carry no account="
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/ambient-claude" "$CASE/claude-worker" \
    "without an account the invoking store is still forwarded"
  pass "no default line and no --account leaves the launch byte-identical"
}

test_mismatched_and_unknown_accounts_refuse() {
  local out rc
  new_case refusals
  write_accounts
  out=$(spawn_ship acct-mismatch --harness claude --account codex-a); rc=$?
  expect_code 1 "$rc" "an account for another harness must refuse"
  assert_refused_before_launch acct-mismatch "$out" \
    "account 'codex-a' in config/accounts is for harness 'codex', not the requested harness 'claude'"
  out=$(spawn_ship acct-unknown --harness claude --account nope); rc=$?
  expect_code 1 "$rc" "an undeclared account must refuse"
  assert_refused_before_launch acct-unknown "$out" "account 'nope' is not declared in config/accounts"
  rm "$HOME_DIR/config/accounts"
  out=$(spawn_ship acct-notable --harness claude --account claude-b); rc=$?
  expect_code 1 "$rc" "an account with no table must refuse"
  assert_refused_before_launch acct-notable "$out" "config/accounts does not exist"
  pass "a mismatched or unknown account refuses before any task state exists"
}

test_secondmate_account_refuses() {
  local out rc id=acct-sm
  new_case secondmate
  write_accounts
  : > "$CASE/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" --secondmate --account claude-b); rc=$?
  expect_code 1 "$rc" "--account on a secondmate spawn must refuse"
  assert_refused_before_launch "$id" "$out" "config/secondmate-harness"
  pass "--account on a secondmate spawn refuses and names config/secondmate-harness"
}

test_malformed_line_refuses_only_its_account() {
  local out rc
  new_case malformed
  write_accounts
  cat >> "$HOME_DIR/config/accounts" <<EOF
broken     claude  HOME=$CASE/profile-b notapair
lowkey     claude  home=$CASE/profile-b
EOF
  out=$(spawn_ship acct-broken --harness claude --account broken); rc=$?
  expect_code 1 "$rc" "an account on a malformed line must refuse"
  assert_refused_before_launch acct-broken "$out" "config/accounts line 6 (account 'broken') is invalid: token 'notapair' is not KEY=VALUE"
  out=$(spawn_ship acct-lowkey --harness claude --account lowkey); rc=$?
  expect_code 1 "$rc" "an account with an invalid key must refuse"
  assert_refused_before_launch acct-lowkey "$out" "key 'home' is not [A-Z_][A-Z0-9_]*"
  out=$(spawn_ship acct-ok --harness claude --account claude-b); rc=$?
  expect_code 0 "$rc" "a valid account must keep working beside a malformed line: $out"
  assert_grep "account=claude-b" "$HOME_DIR/state/acct-ok.meta" "the valid account should still be recorded"

  new_case malformed-default
  cat > "$HOME_DIR/config/accounts" <<EOF
claude-a   claude  default HOME=$CASE/profile-a stray
EOF
  out=$(spawn_ship acct-baddefault --harness claude); rc=$?
  expect_code 1 "$rc" "a malformed default line must refuse its harness rather than fall back"
  assert_refused_before_launch acct-baddefault "$out" "config/accounts line 1 (account 'claude-a') is invalid"
  pass "a malformed line refuses the spawns that name it and leaves other accounts working"
}

test_account_and_pin_refuse_together() {
  local out rc id=acct-pin
  new_case pin
  write_accounts
  mkdir -p "$CASE/pinned"
  printf '%s\n' "$CASE/pinned" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id" --harness claude --account claude-b); rc=$?
  expect_code 1 "$rc" "an account and a worker account pin for the same runner must refuse"
  assert_refused_before_launch "$id" "$out" "config/claude-account pins every claude launch from this home, and config/accounts selects account 'claude-b'"
  pass "an account and a worker account pin for one runner refuse together"
}

test_explicit_account_runs_the_worker_under_its_home
test_default_line_applies_without_account
test_no_default_keeps_the_launch_byte_identical
test_mismatched_and_unknown_accounts_refuse
test_secondmate_account_refuses
test_malformed_line_refuses_only_its_account
test_account_and_pin_refuse_together

echo "# all fm-spawn-account tests passed"
