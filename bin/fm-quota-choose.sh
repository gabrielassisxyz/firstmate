#!/usr/bin/env bash
# Choose the first quota-eligible candidate and its account from a ranked list.
#
# Usage:
#   fm-quota-choose.sh [--snapshot <path>] [--candidate <harness:model>]...
#
# Reads one already-captured `aub status --format json` snapshot from the
# provided file, or from stdin when --snapshot is omitted.
# bin/fm-quota-lib.sh owns the snapshot validator, the harness-to-account-set
# lookup, and the ranking rule this helper applies.
# Each --candidate maps <harness> to its accounts: every config/accounts account
# of that harness in $FM_HOME/config, else the harness's one default account.
# Candidates are tried in order, first against fresh accounts only; a stale
# account is considered only when no candidate has an eligible fresh one, and
# an auth_required account never. Within a candidate the ranking rule picks the
# account. The first candidate with an eligible account is printed as
# "<harness> <model> <account>" and the script exits 0.
# If no candidate is quota-eligible, it prints "none" and exits 1.
#
# Candidates are accepted as `--candidate <harness:model>` or as positional
# colon-separated arguments, with earlier candidates preferred. A bare harness
# with no colon means the default model.
# This script is deterministic and safe: it performs no side effects and exits
# nonzero when the environment would lead to an unsafe dispatch.
#
# The helper is the canonical worker-side selection used after the agent has
# already read the intake snapshot for its model selection. It never replaces
# the agent's reasoning-class or runway-feasibility gates; it only answers which
# ordered candidate, on which account, remains eligible under that snapshot.
# An account missing from the snapshot is unmeasured and never selected here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-lib.sh
. "$SCRIPT_DIR/fm-quota-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

CANDIDATES=()
SNAPSHOT_SOURCE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot)
      [ -n "${2-}" ] || die "--snapshot needs a path"
      SNAPSHOT_SOURCE=$2
      shift 2
      ;;
    --candidate)
      [ -n "${2-}" ] || die "--candidate needs a value"
      CANDIDATES+=("$2")
      shift 2
      ;;
    -h|--help|help) usage ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) CANDIDATES+=("$1") ; shift ;;
  esac
done

# Positional args after an explicit -- are also candidates.
while [ "$#" -gt 0 ]; do
  CANDIDATES+=("$1"); shift
done

[ "${#CANDIDATES[@]}" -gt 0 ] || die "no candidates supplied"

# A candidate is <harness>:<model>. Reject empty harnesses and characters that
# cannot form a safe token. A colon-separated model is legal.
for c in "${CANDIDATES[@]}"; do
  case "$c" in
    ''|:*|*[!A-Za-z0-9._/:-]*) die "invalid candidate: $c" ;;
  esac
done

if [ -n "$SNAPSHOT_SOURCE" ]; then
  [ -f "$SNAPSHOT_SOURCE" ] && [ ! -L "$SNAPSHOT_SOURCE" ] || die "snapshot is not a regular file: $SNAPSHOT_SOURCE"
  QUOTA_JSON=$(cat -- "$SNAPSHOT_SOURCE") || die "cannot read snapshot: $SNAPSHOT_SOURCE"
else
  [ ! -t 0 ] || die "quota snapshot is required on stdin or with --snapshot"
  QUOTA_JSON=$(cat) || die "cannot read quota snapshot from stdin"
fi
[ -n "$QUOTA_JSON" ] || die "empty quota snapshot"
printf '%s\n' "$QUOTA_JSON" | fm_quota_json_valid || die "invalid aub status snapshot"

# accounts_json <harness>: the candidate's account set as a JSON array.
accounts_json() {
  local accounts
  accounts=$(fm_quota_accounts_for_harness "$CONFIG" "$1")
  [ -n "$accounts" ] || accounts=$(fm_quota_default_account_for_harness "$1") || accounts=
  printf '%s' "$accounts" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

SETS='[]'
for c in "${CANDIDATES[@]}"; do
  harness=${c%%:*}
  model=${c#*:}
  [ "$model" = "$c" ] && model="default"
  [ -n "$model" ] || die "invalid candidate: $c"
  fm_control_harness_supported "$harness" || die "unknown harness: $harness"
  SETS=$(jq -c --arg h "$harness" --arg m "$model" --argjson a "$(accounts_json "$harness")" \
    '. + [{harness: $h, model: $m, accounts: $a}]' <<<"$SETS")
done

chosen=$(printf '%s\n' "$QUOTA_JSON" | jq -r --argjson sets "$SETS" "$FM_QUOTA_RANK_JQ"'
  . as $q |
  def pick($tier):
    [$sets[] | . as $c |
      [$c.accounts[] | aub_eval($q; .) | select(.eligible and ((.unranked // false) | not) and .tier == $tier)]
      | sort_by([-.reserve, -.pct, (.age // 0)]) | first
      | select(. != null) | "\($c.harness) \($c.model) \(.account)"] | first;
  pick(1) // pick(2) // "none"
') || die "could not rank the aub snapshot"

printf '%s\n' "$chosen"
[ "$chosen" != "none" ]
