#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-lib.sh, the aub quota source, and the three
# readers that share it: bin/fm-dispatch-resolve.sh, bin/fm-quota-choose.sh,
# and bin/fm-procevent-quota.sh, plus bootstrap's aub requirement.
#
# A fake aub on PATH prints tests/fixtures/aub-status.json, a real
# `aub status --format json` capture, or a two-account variant built from it.
# Every case runs in a scratch home whose config/accounts this file writes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-quota-lib.sh"
FIXTURE="$ROOT/tests/fixtures/aub-status.json"
TMP_ROOT=$(fm_test_tmproot fm-quota-lib)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
NO_AUB_PATH=$(fm_test_base_path_sans "$PATH" aub)
mkdir -p "$HOME_DIR/config"

cat > "$FAKEBIN/aub" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'aub 0.1.0 (fake)'
  exit 0
fi
[ "$*" = 'status --format json' ] || exit 2
cat "${AUB_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/aub"
export AUB_FIXTURE="$FIXTURE"

# lib <shell code>: run code with the library sourced, fake aub first on PATH.
lib() {
  PATH="$FAKEBIN:$NO_AUB_PATH" bash -c '. "$1"; shift; eval "$1"' _ "$LIB" "$1"
}

# --- the source check ------------------------------------------------------------
code=0
err=$(lib 'fm_quota_source_compatible' 2>&1) || code=$?
expect_code 0 "$code" "a fake aub printing the captured envelope is compatible"
assert_equals '' "$err" "a compatible aub prints nothing"

code=0
err=$(PATH="$NO_AUB_PATH" bash -c '. "$1"; fm_quota_source_compatible' _ "$LIB" 2>&1) || code=$?
expect_code 1 "$code" "an absent aub is incompatible"
assert_equals '1' "$(grep -c . <<<"$err")" "an absent aub prints one line"
assert_equals 'aub: not on PATH (install: cargo install --git https://github.com/gabrielassisxyz/agent-usage-book)' "$err" "the line names aub and its install hint"

jq '.schema = 4' "$FIXTURE" > "$TMP_ROOT/schema4.json"
code=0
err=$(AUB_FIXTURE="$TMP_ROOT/schema4.json" lib 'fm_quota_source_compatible 5' 2>&1) || code=$?
expect_code 1 "$code" "an aub answering schema 4 is incompatible"
assert_contains "$err" 'aub: status --format json did not answer a schema 5 snapshot within 5s' "the schema failure names aub"
pass "fm_quota_source_compatible accepts the captured envelope and names aub when it is absent"

# --- the validator -----------------------------------------------------------------
lib "fm_quota_json_valid < '$FIXTURE'" || fail "the captured envelope is valid"
jq '.accounts[0] |= del(.windows)' "$FIXTURE" > "$TMP_ROOT/no-windows.json"
for bad in "$TMP_ROOT/schema4.json" "$TMP_ROOT/no-windows.json"; do
  if lib "fm_quota_json_valid < '$bad'"; then
    fail "an invalid envelope was accepted: $bad"
  fi
done
pass "fm_quota_json_valid accepts the captured envelope and rejects schema 4 and a missing windows array"

# --- the harness-to-account-set lookup ---------------------------------------------
cat > "$HOME_DIR/config/accounts" <<'ACCOUNTS'
# accounts for the lookup
primary claude default CLAUDE_CONFIG_DIR=/accounts/primary
gmail claude CLAUDE_CONFIG_DIR=/accounts/gmail
broken claude
codex-primary codex CODEX_HOME=/accounts/codex-primary
ACCOUNTS
assert_equals $'primary\ngmail' "$(lib "fm_quota_accounts_for_harness '$HOME_DIR/config' claude")" "every valid account of the harness, in file order"
assert_equals 'codex-primary' "$(lib "fm_quota_accounts_for_harness '$HOME_DIR/config' codex")" "another harness has its own set"
assert_equals '' "$(lib "fm_quota_accounts_for_harness '$HOME_DIR/config' pi")" "a harness without accounts has an empty set"
assert_equals '' "$(lib "fm_quota_accounts_for_harness '$TMP_ROOT/no-config' claude")" "an absent config/accounts is an empty set"
assert_equals 'agy' "$(lib 'fm_quota_default_account_for_harness agy')" "agy is one account"
assert_equals 'opencode-go' "$(lib 'fm_quota_default_account_for_harness opencode')" "opencode is one account"
lib 'fm_quota_default_account_for_harness claude' && fail "claude has no default account"
pass "the harness-to-account-set lookup reads config/accounts"

# --- the typed resolver over the two-account example --------------------------------
# primary: fresh, 40% remaining, burn 1.5, 60% elapsed (reserve -20).
# gmail:   fresh, 95% remaining, burn 0.2, 10% elapsed (reserve 77).
two_accounts() {  # <out> <primary freshness> <gmail freshness>
  jq --arg pf "$2" --arg gf "$3" '
    .generated_at as $now |
    def acct($name; $fresh; $r; $b; $e):
      {account: $name, freshness: $fresh, observation_age_nanos: 1000,
       limiting_window: {scope: "account_wide", nominal_duration_nanos: 604800000000000, burn_rate: $b},
       windows: [{semantic_key: "weekly_all", scope: "account_wide",
         quota_used_ppm: ((100 - $r) * 10000),
         resets_at_nanos: ($now + (1 - $e) * 604800000000000),
         nominal_duration_nanos: 604800000000000, burn_rate: $b, observation_freshness: $fresh}]};
    .accounts = [acct("primary"; $pf; 40; "1.5"; 0.6), acct("gmail"; $gf; 95; "0.2"; 0.1)]
  ' "$FIXTURE" > "$1"
}
cat > "$HOME_DIR/config/accounts" <<'ACCOUNTS'
primary claude CLAUDE_CONFIG_DIR=/accounts/primary
gmail claude CLAUDE_CONFIG_DIR=/accounts/gmail
codex-primary codex CODEX_HOME=/accounts/codex-primary
ACCOUNTS
printf '%s\n' '{"rules":[{"when":"Claude work.","use":{"harness":"claude","model":"opus"}}]}' > "$HOME_DIR/config/crew-dispatch.json"
printf '%s\n' '# Task' 'Fix the pager.' > "$TMP_ROOT/brief.md"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
out=''
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
cat > /dev/null
printf '%s\n' '{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}}}}' > "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"
resolve() {  # <fixture>
  AUB_FIXTURE="$1" PATH="$FAKEBIN:$NO_AUB_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=test-key \
    "$ROOT/bin/fm-dispatch-resolve.sh" "$TMP_ROOT/brief.md" 2>/dev/null
}

two_accounts "$TMP_ROOT/fresh-fresh.json" fresh fresh
out=$(resolve "$TMP_ROOT/fresh-fresh.json")
assert_contains "$out" '  status: clear' "fresh/fresh resolves"
assert_contains "$out" '  account: gmail' "the fresher, emptier account wins"
assert_contains "$out" "  profile: --harness 'claude' --model 'opus' --account 'gmail'" "the chosen account reaches fm-spawn.sh"
assert_contains "$out" 'account=primary  freshness=fresh  scope=account_wide  remaining=40%  burn=1.5  elapsed=60%  reserve=-20' "primary's reserve is shown"
assert_contains "$out" 'account=gmail  freshness=fresh  scope=account_wide  remaining=95%  burn=0.2  elapsed=10%  reserve=77' "gmail's reserve is shown"

two_accounts "$TMP_ROOT/fresh-stale.json" fresh stale
out=$(resolve "$TMP_ROOT/fresh-stale.json")
assert_contains "$out" '  account: primary' "a stale gmail yields to the only fresh account"

two_accounts "$TMP_ROOT/auth-auth.json" auth_required auth_required
out=$(resolve "$TMP_ROOT/auth-auth.json")
assert_contains "$out" '  status: error' "both accounts needing authentication is an error"
assert_not_contains "$out" '  account:' "no account is chosen when both need authentication"
pass "the typed resolver ranks the two-account example and emits the chosen account"

# --- the chooser and the quota watch against the captured envelope -----------------
cat > "$HOME_DIR/config/accounts" <<'ACCOUNTS'
primary claude CLAUDE_CONFIG_DIR=/accounts/primary
gmail claude CLAUDE_CONFIG_DIR=/accounts/gmail
bianca claude CLAUDE_CONFIG_DIR=/accounts/bianca
codex-primary codex CODEX_HOME=/accounts/codex-primary
codex-bianca codex CODEX_HOME=/accounts/codex-bianca
ACCOUNTS
code=0
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-quota-choose.sh" --snapshot "$FIXTURE" claude:opus codex:gpt-5.5 2>&1) || code=$?
expect_code 0 "$code" "the chooser runs against the captured envelope"
assert_equals 'claude opus bianca' "$out" "the chooser names the account the ranking rule picks"

code=0
out=$(PATH="$FAKEBIN:$NO_AUB_PATH" "$ROOT/bin/fm-procevent-quota.sh" poll --interval 1 --threshold 90 --timeout 5 2>&1) || code=$?
expect_code 0 "$code" "the quota watch runs against the captured envelope"
assert_contains "$out" 'status: low' "an account below the threshold fires the watch"
detail=$(sed -n 's/^detail: //p' <<<"$out")
jq -e '.account == "aggregate" and ([.summary[].account] | index("codex-primary")) != null and ([.. | objects | has("provider")] | any | not)' <<<"$detail" >/dev/null \
  || fail "the watch detail names accounts, not providers: $detail"
out=$(PATH="$FAKEBIN:$NO_AUB_PATH" "$ROOT/bin/fm-procevent-quota.sh" poll --interval 1 --threshold 90 --account codex-primary --timeout 5 2>&1)
assert_contains "$out" 'quota: quota-codex-primary' "an account watch names its account"
pass "the chooser and the quota watch read the captured envelope and name accounts"

# --- bootstrap in a scratch home without aub ---------------------------------------
BOOT_HOME="$TMP_ROOT/boot-home"
mkdir -p "$BOOT_HOME/config"
printf '%s\n' manual > "$BOOT_HOME/config/backlog-backend"
out=$(PATH="$NO_AUB_PATH" FM_HOME="$BOOT_HOME" FM_ROOT_OVERRIDE="$BOOT_HOME" FM_BOOTSTRAP_DETECT_ONLY=1 \
  "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_contains "$out" 'MISSING: aub (install: cargo install --git https://github.com/gabrielassisxyz/agent-usage-book)' "bootstrap reports a missing aub"
assert_not_contains "$out" 'quota-axi' "bootstrap says nothing about quota-axi"
pass "bootstrap in a home without aub reports MISSING: aub and nothing about quota-axi"

printf '# all fm-quota-lib tests passed\n'
