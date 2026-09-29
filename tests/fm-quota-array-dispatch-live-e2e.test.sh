#!/usr/bin/env bash
# Credentialed behavior regression for the agent-owned quota-array-dispatch skill.
#
# This drives the public Pi skill-loading interface against a fake aub
# executable rather than parsing instruction source bytes or recreating the
# ranking rule in test code. The fake serves one `aub status --format json`
# fixture and logs every call, so a skill that takes a second snapshot or asks
# aub anything else is caught by the call log.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E pi jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/quota-array-dispatch/SKILL.md"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

[ -f "$OWNER" ] || fail "quota-array-dispatch skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-array-dispatch-live.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
FIXTURE="$LAB/aub.json"
CALLS="$LAB/aub.calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/quota-array-dispatch" "$FAKEBIN"
cp "$OWNER" "$PROJECT/.agents/skills/quota-array-dispatch/SKILL.md"

cat > "$FAKEBIN/aub" <<'SH'
#!/usr/bin/env bash
# Fake aub: `status --format json` prints the fixture; anything else fails.
set -u
printf '%s\n' "$*" >> "${AUB_CALLS:?}"
case "$*" in
  'status --format json') cat "${AUB_FIXTURE:?}" ;;
  *)
    printf 'unexpected aub invocation: %s\n' "$*" >&2
    exit 64
    ;;
esac
SH
chmod +x "$FAKEBIN/aub"

# write_fixture <account-json>...: one schema 5 envelope at a fixed instant.
write_fixture() {
  printf '%s\n' "$@" | jq -s '{schema: 5, command: "status", run: "run-live", generated_at: 2000000000000000000,
    knowledge_at: 2000000000000000000, ledger_generation: 1, accounts: .}' > "$FIXTURE"
}

# account <name> <freshness> <remaining %> <burn> <elapsed fraction>
account() {
  jq -nc --arg n "$1" --arg f "$2" --argjson r "$3" --arg b "$4" --argjson e "$5" '
    {account: $n, freshness: $f, observation_age_nanos: 60000000000,
     limiting_window: {scope: "account_wide", nominal_duration_nanos: 604800000000000, burn_rate: $b},
     windows: [{semantic_key: "weekly_all", scope: "account_wide", quota_used_ppm: ((100 - $r) * 10000 | round),
       resets_at_nanos: (2000000000000000000 + (1 - $e) * 604800000000000),
       nominal_duration_nanos: 604800000000000, burn_rate: $b, observation_freshness: $f}]}'
}

run_case() {
  local label=$1 expected=$2 prompt=$3 out calls required
  shift 3
  : > "$CALLS"
  out=$(
    cd "$PROJECT" &&
      PATH="$FAKEBIN:$PATH" AUB_CALLS="$CALLS" AUB_FIXTURE="$FIXTURE" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --model openai-codex/gpt-5.6-sol --thinking high \
          "$prompt"
  ) || fail "$label: Pi skill run failed: $out"
  calls=$(cat "$CALLS")
  [ "$calls" = 'status --format json' ] || fail "$label: unexpected aub call sequence: $calls"
  printf '%s\n' "$out" | grep -Fxq "$expected" \
    || fail "$label: expected final line $expected, got: $out"
  for required in "$@"; do
    printf '%s\n' "$out" | grep -Fxq "$required" \
      || fail "$label: expected accounting line $required, got: $out"
  done
  printf '%s\n' "$out"
  printf 'ok - %s\n' "$label"
}

COMMON="Both candidates are the same profile, harness claude with model opus, and config/accounts declares the two Claude accounts primary and gmail. The authoritative catalog already proves the model supported. The likely task-completion horizon is two hours with established confidence, and both limiting windows reset after it. Do not use other vendor or model commands and do not modify files."

write_fixture "$(account primary fresh 40 1.5 0.6)" "$(account gmail fresh 95 0.2 0.1)"
run_case \
  "the fresher, emptier account wins by reserve" \
  "SELECTED=gmail" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and take its one quota snapshot exactly once. $COMMON Return one line per account in the exact form FACT=<account>|remaining=<r>|reserve=<reserve rounded to an integer>, then an exact final line SELECTED=<account>." \
  "FACT=primary|remaining=40|reserve=-20" \
  "FACT=gmail|remaining=95|reserve=77"

write_fixture "$(account primary fresh 40 1.5 0.6)" "$(account gmail stale 95 0.2 0.1)"
run_case \
  "a stale account ranks only when no fresh one is eligible" \
  "SELECTED=primary" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and take its one quota snapshot exactly once. $COMMON Assume primary's runway passes the feasibility gate for this task. Return one line per account in the exact form FACT=<account>|freshness=<freshness>, then an exact final line SELECTED=<account>." \
  "FACT=primary|freshness=fresh" \
  "FACT=gmail|freshness=stale"

write_fixture "$(account primary fresh 40 1.5 0.6)" "$(account gmail auth_required 95 0.2 0.1)"
run_case \
  "an auth_required account is never chosen" \
  "SELECTED=primary" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and take its one quota snapshot exactly once. $COMMON Assume primary's runway passes the feasibility gate for this task. Return one line per account in the exact form FACT=<account>|eligible=<yes|no>, then an exact final line SELECTED=<account>." \
  "FACT=primary|eligible=yes" \
  "FACT=gmail|eligible=no"
