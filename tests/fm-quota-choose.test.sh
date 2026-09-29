#!/usr/bin/env bash
# Unit tests for bin/fm-quota-choose.sh.
# Drives the public argv interface with captured `aub status --format json`
# snapshots and a scratch home whose config/accounts names the accounts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-quota-choose.sh"
LAB=$(fm_test_tmproot fm-quota-choose)
HOME_DIR="$LAB/home"
SNAP="$LAB/snapshot.json"
mkdir -p "$HOME_DIR/config"
cat > "$HOME_DIR/config/accounts" <<'ACCOUNTS'
primary claude CLAUDE_CONFIG_DIR=/accounts/primary
gmail claude CLAUDE_CONFIG_DIR=/accounts/gmail
codex-primary codex CODEX_HOME=/accounts/codex-primary
ACCOUNTS

NOW=2000000000000000000
WEEK=604800000000000
# account <name> <freshness> <remaining %> <burn> <elapsed fraction>
account() {
  jq -nc --arg n "$1" --arg f "$2" --argjson r "$3" --arg b "$4" --argjson e "$5" \
    --argjson now "$NOW" --argjson week "$WEEK" '
    {account: $n, freshness: $f, observation_age_nanos: 1,
     limiting_window: {scope: "account_wide", nominal_duration_nanos: $week, burn_rate: $b},
     windows: [{semantic_key: "weekly", scope: "account_wide", quota_used_ppm: ((100 - $r) * 10000 | round),
       resets_at_nanos: ($now + (1 - $e) * $week), nominal_duration_nanos: $week, burn_rate: $b}]}'
}
snapshot() {
  jq -sc --argjson now "$NOW" '{schema: 5, command: "status", run: "run-test", generated_at: $now, accounts: .}' > "$SNAP"
}
choose() { FM_HOME="$HOME_DIR" "$TOOL" --snapshot "$SNAP" "$@" 2>&1; }

{
  account primary fresh 40 1.5 0.6
  account gmail fresh 95 0.2 0.1
  account codex-primary fresh 31 1.0 0.5
  account agy fresh 64 0 0.5
} | snapshot

help=$("$TOOL" --help 2>&1) && fail "help unexpectedly exited zero"
assert_contains "$help" 'fm-quota-choose.sh [--snapshot <path>] [--candidate <harness:model>]...' "help shows usage"
assert_not_contains "$help" 'set -u' "help leaks no source"
pass "help renders the complete header only"

out=$(choose --candidate claude:opus --candidate codex:gpt-5.5)
assert_equals 'claude opus gmail' "$out" "the first candidate runs on its highest-reserve account"
out=$(choose claude:opus codex:gpt-5.5)
assert_equals 'claude opus gmail' "$out" "positional candidates work"
out=$(choose codex agy:gemini)
assert_equals 'codex default codex-primary' "$out" "a bare harness maps to the default model"
out=$(choose agy:gemini)
assert_equals 'agy gemini agy' "$out" "agy is measured on its one default account"
pass "each candidate is printed with the account the ranking rule picks"

jq '(.accounts[] | select(.account == "gmail" or .account == "primary") | .windows[0].quota_used_ppm) = 1000000' "$SNAP" > "$LAB/claude-empty.json"
out=$(FM_HOME="$HOME_DIR" "$TOOL" --snapshot "$LAB/claude-empty.json" claude:opus codex:gpt-5.5)
assert_equals 'codex gpt-5.5 codex-primary' "$out" "a candidate whose accounts are all empty is skipped"
jq '.accounts |= map(.windows[0].quota_used_ppm = 1000000)' "$SNAP" > "$LAB/all-empty.json"
code=0
out=$(FM_HOME="$HOME_DIR" "$TOOL" --snapshot "$LAB/all-empty.json" claude:opus codex:gpt-5.5) || code=$?
assert_equals 'none' "$out" "no eligible account prints none"
expect_code 1 "$code" "no eligible account exits 1"
pass "empty accounts are never chosen"

jq '(.accounts[] | select(.account == "gmail") | .freshness) = "stale"' "$SNAP" > "$LAB/gmail-stale.json"
out=$(FM_HOME="$HOME_DIR" "$TOOL" --snapshot "$LAB/gmail-stale.json" claude:opus)
assert_equals 'claude opus primary' "$out" "a fresh account wins over a stale one with more reserve"
jq '(.accounts[] | select(.account == "primary" or .account == "gmail") | .freshness) = "stale"' "$SNAP" > "$LAB/claude-stale.json"
out=$(FM_HOME="$HOME_DIR" "$TOOL" --snapshot "$LAB/claude-stale.json" claude:opus codex:gpt-5.5)
assert_equals 'codex gpt-5.5 codex-primary' "$out" "a later candidate with a fresh account beats an earlier one with only stale accounts"
jq '.accounts[].freshness = "stale"' "$SNAP" > "$LAB/all-stale.json"
out=$(FM_HOME="$HOME_DIR" "$TOOL" --snapshot "$LAB/all-stale.json" claude:opus codex:gpt-5.5)
assert_equals 'claude opus gmail' "$out" "stale accounts are chosen only when no fresh one is eligible"
jq '.accounts[].freshness = "auth_required"' "$SNAP" > "$LAB/all-auth.json"
out=$(FM_HOME="$HOME_DIR" "$TOOL" --snapshot "$LAB/all-auth.json" claude:opus codex:gpt-5.5) && fail "auth_required accounts were chosen"
assert_equals 'none' "$out" "auth_required accounts are never chosen"
pass "fresh accounts first, stale only as a fallback, auth_required never"

out=$(choose pi:anthropic/claude-sonnet-5 codex:gpt-5.5)
assert_equals 'codex gpt-5.5 codex-primary' "$out" "a harness with no measured account is skipped"
out=$(FM_HOME="$HOME_DIR" "$TOOL" --snapshot "$SNAP" pi:anthropic/claude-sonnet-5) && fail "an unmeasured candidate was chosen"
assert_equals 'none' "$out" "an unmeasured candidate alone is none"
pass "a candidate without a measured account is never selected"

out=$(FM_HOME="$HOME_DIR" "$TOOL" claude:opus < "$SNAP")
assert_equals 'claude opus gmail' "$out" "the snapshot is accepted on stdin"
pass "stdin snapshot is accepted"

for bad in 'spaceship:x' ':opus' 'claude:' 'claude:op us'; do
  code=0
  out=$(choose "$bad") || code=$?
  expect_code 2 "$code" "invalid candidate is refused: $bad"
done
code=0
out=$(choose claude:opus spaceship:x) || code=$?
expect_code 2 "$code" "every candidate is validated before selection"
assert_contains "$out" 'unknown harness: spaceship' "the unknown harness is named"
pass "invalid candidates fail closed"

for mutation in '.schema = 4' '.accounts = []' 'del(.accounts[0].windows)' '.accounts[1].account = "primary"' '.accounts[0].windows[0].quota_used_ppm = "0"'; do
  jq "$mutation" "$SNAP" > "$LAB/bad.json"
  code=0
  out=$(FM_HOME="$HOME_DIR" "$TOOL" --snapshot "$LAB/bad.json" claude:opus 2>&1) || code=$?
  expect_code 2 "$code" "malformed snapshot is refused: $mutation"
  assert_contains "$out" 'invalid aub status snapshot' "malformed snapshot is named: $mutation"
done
printf '%s\n%s\n' "$(cat "$SNAP")" "$(cat "$SNAP")" > "$LAB/two.json"
code=0
out=$(FM_HOME="$HOME_DIR" "$TOOL" --snapshot "$LAB/two.json" claude:opus 2>&1) || code=$?
expect_code 2 "$code" "two JSON values are refused"
pass "malformed snapshots fail closed"

printf '# all fm-quota-choose tests passed\n'
