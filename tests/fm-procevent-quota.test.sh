#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-quota.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-quota.XXXXXX")
FAKEBIN="$LAB/fakebin"
COUNT="$LAB/count"

# shellcheck source=bin/fm-timeout-lib.sh
. "$BIN/fm-timeout-lib.sh"

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$FAKEBIN"

# Fake aub. Each account has one weekly account-wide window; AUB_MODE picks the
# snapshot, and AUB_COUNT numbers the status calls so a watch can see quota
# change between polls.
cat > "$FAKEBIN/aub" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'aub 0.1.0 (fake)\n'
  exit 0
fi
[ "$*" = 'status --format json' ] || exit 2
count=0
[ ! -f "${AUB_COUNT:?}" ] || read -r count < "$AUB_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$AUB_COUNT"
# account <name> <freshness> <remaining %> [<resets>]
account() {
  jq -nc --arg n "$1" --arg f "$2" --argjson r "$3" --argjson reset "${4:-2000300000000000000}" '
    {account: $n, freshness: $f, observation_age_nanos: 1,
     limiting_window: {scope: "account_wide", nominal_duration_nanos: 604800000000000, burn_rate: "1.0"},
     windows: [{semantic_key: "weekly", scope: "account_wide", quota_used_ppm: ((100 - $r) * 10000),
       resets_at_nanos: $reset, nominal_duration_nanos: 604800000000000, burn_rate: "1.0"}]}'
}
envelope() {
  jq -sc '{schema: 5, command: "status", run: "run-test", generated_at: 2000000000000000000, accounts: .}'
}
case "${AUB_MODE:-}" in
  schema) printf '{"schema":4,"generated_at":1,"accounts":[]}\n' ;;
  empty) printf '{"schema":5,"generated_at":1,"accounts":[]}\n' ;;
  no-windows) printf '{"schema":5,"generated_at":1,"accounts":[{"account":"codex-primary","freshness":"fresh"}]}\n' ;;
  duplicate) { account codex-primary fresh 50; account codex-primary fresh 50; } | envelope ;;
  types) account codex-primary fresh 50 | jq -c '.windows[0].quota_used_ppm = "0"' | envelope ;;
  exhausted-detail) { account codex-primary fresh 5; account second fresh 50; } | envelope ;;
  auth) { account codex-primary auth_required 0; account second fresh 50; } | envelope ;;
  at-threshold)
    remaining=9
    [ "$count" -ne 1 ] || remaining=10
    account codex-primary fresh "$remaining" | envelope
    ;;
  *)
    codex=0
    [ "$count" -ne 1 ] || codex=20
    { account codex-primary fresh "$codex"; account second fresh 50; } | envelope
    ;;
esac
SH
chmod +x "$FAKEBIN/aub"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }
poll() { AUB_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll "$@"; }

if help=$("$BIN/fm-procevent-quota.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq 'fm-procevent-quota.sh retire [--account <account>]' \
  || fail "help omitted the retire usage"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then
  fail "help leaked executable source"
fi
ok "help renders only the complete header"

rm -f "$COUNT"
out=$(AUB_MODE=exhausted-detail poll)
printf '%s\n' "$out" | grep -qx 'status: low' \
  || fail "default aggregate poll did not report the low account"
printf '%s\n' "$out" | grep -qx 'quota: quota' \
  || fail "default aggregate poll did not use the aggregate source"
ok "poll accepts its documented defaults"

rm -f "$COUNT"
out=$(poll --interval 0.01 --threshold 10 --account codex-primary --timeout 1)
printf '%s\n' "$out" | grep -qx 'quota: quota-codex-primary' || fail "account watch did not use its source id"
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "account watch did not report exhaustion"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "account watch did not wait through the healthy poll"
ok "account watch blocks until its window is exhausted"

rm -f "$COUNT"
out=$(AUB_MODE=exhausted-detail poll --interval 1 --threshold 10 --account codex-primary --timeout 1)
detail=$(printf '%s\n' "$out" | sed -n 's/^detail: //p')
printf '%s\n' "$detail" | jq -e '
  .account == "codex-primary" and
  .freshness == "fresh" and
  .tightest.scope == "account_wide" and
  .tightest.remaining == 5
' >/dev/null || fail "low poll recorded detail without its account: $detail"
ok "a triggered poll names the account and its tightest window"

rm -f "$COUNT"
out=$(poll --interval 0.01 --threshold 10 --account '' --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "aggregate watch did not report exhaustion"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "aggregate watch did not evaluate every account"
detail=$(printf '%s\n' "$out" | sed -n 's/^detail: //p')
printf '%s\n' "$detail" | jq -e '
  .account == "aggregate" and
  ([.summary[].account] == ["codex-primary", "second"]) and
  ([.summary[] | select(.account == "second") | .tightest.remaining] == [50])
' >/dev/null || fail "aggregate detail did not keep each account separate: $detail"
ok "aggregate watch reads every account without combining them"

rm -f "$COUNT"
out=$(AUB_MODE=auth AUB_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  fm_run_timed 2 "$BIN/fm-procevent-quota.sh" poll --interval 0.2 --threshold 10 --timeout 1)
[ -z "$out" ] || fail "aggregate watch fired on an auth_required account: $out"
ok "aggregate watch skips an auth_required account"

rm -f "$COUNT"
out=$(AUB_MODE=auth poll --interval 1 --threshold 10 --account codex-primary --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: error' || fail "a watch on an auth_required account did not report error"
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "an auth_required account watch did not stop immediately"
ok "an auth_required account is an error for its own watch"

rm -f "$COUNT"
out=$(poll --interval 1 --threshold 10 --account ghost --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: error' || fail "an account absent from the snapshot did not report error"
ok "a watch on an account aub does not list reports error"

if err=$(AUB_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" arm --account 2>&1); then
  fail "missing account value unexpectedly armed a watch"
fi
[ "$err" = "error: --account needs a value" ] || fail "missing account value returned: $err"
ok "arm rejects a missing account value"

for account in -- codex-; do
  if err=$(AUB_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" arm --account "$account" 2>&1); then
    fail "noncanonical account unexpectedly armed a watch: $account"
  fi
  [ "$err" = "error: invalid account: $account" ] || fail "noncanonical account returned: $err"
done
ok "arm rejects noncanonical account identities"

NO_AUB_BIN="$LAB/no-aub-bin"
mkdir -p "$NO_AUB_BIN"
for tool in bash jq perl dirname cat awk sed; do
  command -v "$tool" >/dev/null 2>&1 && ln -s "$(command -v "$tool")" "$NO_AUB_BIN/$tool"
done
if err=$(FM_HOME="$LAB/arm-home" FM_STATE_OVERRIDE="$LAB/arm-state" PATH="$NO_AUB_BIN" \
  "$BIN/fm-procevent-quota.sh" arm --account codex-primary 2>&1); then
  fail "arm without aub unexpectedly registered a watch"
fi
printf '%s\n' "$err" | grep -Fq 'error: aub: not on PATH (install: ' || fail "arm without aub did not name aub: $err"
ok "arm refuses without aub and names it"

out=$(FM_HOME="$LAB/retire-home" FM_STATE_OVERRIDE="$LAB/retire-state" \
  "$BIN/fm-procevent-quota.sh" retire --account codex-primary)
[ "$out" = "retired: quota-codex-primary" ] || fail "account retire targeted the wrong source: $out"
ok "account retire resolves the armed source id"

if err=$(poll --interval 1 --threshold 100.5 --account codex-primary --timeout 1 2>&1); then
  fail "threshold above 100 unexpectedly started polling"
fi
[ "$err" = "error: --threshold needs a percent 0-100" ] || fail "invalid threshold returned: $err"
ok "poll rejects a decimal threshold above 100"

rm -f "$COUNT"
out=$(poll --interval 0.01 --threshold 010 --account codex-primary --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "leading-zero threshold did not evaluate quota"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "leading-zero threshold stopped before exhaustion"
ok "poll accepts a leading-zero threshold"

rm -f "$COUNT"
out=$(AUB_MODE=at-threshold poll --interval 0.01 --threshold 10 --account codex-primary --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: low' || fail "quota below the threshold did not report low"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "quota at the threshold fired before dropping below it"
ok "poll fires only after quota drops below the threshold"

if err=$(poll --account 2>&1); then
  fail "missing poll account value unexpectedly succeeded"
fi
[ "$err" = "error: --account needs a value" ] || fail "missing poll account returned: $err"
ok "poll rejects a missing option value"

rm -f "$COUNT"
out=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash poll --interval 0.01 --threshold 10 --account codex-primary --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "bash timeout fallback did not poll quota"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "bash timeout fallback stopped before exhaustion"
ok "quota polling uses the shared bash timeout fallback"

for malformed in schema empty no-windows duplicate types; do
  out=$(AUB_MODE="$malformed" poll --interval 1 --threshold 10 --account codex-primary --timeout 1)
  printf '%s\n' "$out" | grep -qx 'status: error' || fail "$malformed snapshot did not report an error"
  printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "$malformed snapshot did not stop immediately"
done
ok "poll rejects malformed aub snapshots"

printf '# all fm-procevent-quota tests passed\n'
