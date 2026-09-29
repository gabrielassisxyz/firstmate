#!/usr/bin/env bash
# Quota-exhaustion process-event adapter.
#
# Usage:
#   fm-procevent-quota.sh arm [--interval <secs>] [--threshold <percent>] [--account <account>]
#   fm-procevent-quota.sh poll [--interval <secs>] [--threshold <percent>] [--account <account>] [--timeout <secs>]
#   fm-procevent-quota.sh classify <result-file>
#   fm-procevent-quota.sh terminal <result-file>
#   fm-procevent-quota.sh source-id [<account>]
#   fm-procevent-quota.sh retire [--account <account>]
#
# arm        Register a recurring `aub status --format json` poll that wakes
#            firstmate when any window of a tracked account drops below
#            <threshold> percent remaining (default 10%) or reaches 0%. The
#            condition is deterministic, the action is only the durable
#            `check: procevent:quota:<seq>` wake, and the watch is registered
#            through `bin/fm-procevent.sh register`.
# poll       The blocking child the generic runner executes; never run this
#            directly in a conversational turn. It polls `aub status --format
#            json` until quota drops below the threshold or an error stops the
#            watch.
# classify   Print the captured outcome class: low, exhausted, error, or unknown.
# terminal   Every quota poll is terminal because the source fires at most once.
# source-id  Print the canonical source id.
# retire     Stop the aggregate watch, or the matching account watch when
#            --account is supplied, and retire the registration.
#
# The canonical source id is `quota` for the aggregate watch over every account
# in the snapshot. An account named with --account (an aub account id) becomes
# the only tracked account and the source id becomes `quota-<account>`.
#
# bin/fm-quota-lib.sh owns the snapshot validator and the window arithmetic.
# Every account is read independently, never combined. The aggregate watch
# skips an auth_required account, since it has no current reading; a watch on
# that one account reports error. Details name each account with its tightest
# window.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-quota-lib.sh
. "$SCRIPT_DIR/fm-quota-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DEFAULT_INTERVAL=60
DEFAULT_THRESHOLD=10

SOURCE_ID_BASE=quota

CANONICAL_SOURCE_ID=
ACCOUNT=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

resolve_account() {
  local LC_ALL=C
  ACCOUNT=${1:-}
  if [ -n "$ACCOUNT" ]; then
    [[ "$ACCOUNT" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "invalid account: $ACCOUNT"
    CANONICAL_SOURCE_ID="$SOURCE_ID_BASE-$ACCOUNT"
  else
    CANONICAL_SOURCE_ID=$SOURCE_ID_BASE
    ACCOUNT=
  fi
  fm_procevent_source_id_valid "$CANONICAL_SOURCE_ID" || die "source id is not path-safe: $CANONICAL_SOURCE_ID"
}

positive_number() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [ "$n" != 0 ] && [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

valid_percent() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  jq -en --arg n "$n" '($n | tonumber) <= 100' >/dev/null 2>&1
}

# quota_json [timeout]
# One validated `aub status --format json` snapshot bounded by the timeout. A
# missing aub or an invalid snapshot is an error condition, not a signal to fire.
quota_json() {
  fm_quota_snapshot "${1:-}" || return 2
}

# condition_status <json> [account] [threshold]
# Print healthy, low, exhausted, or error for the tightest window of the tracked
# accounts.
condition_status() {
  local json=$1 account=${2:-} threshold=${3:-$DEFAULT_THRESHOLD}
  printf '%s\n' "$json" | fm_quota_json_valid || { printf 'error\n'; return; }
  printf '%s\n' "$json" | jq -r --arg account "$account" --arg threshold "$threshold" "$FM_QUOTA_RANK_JQ"'
    [.accounts[] | select($account == "" or .account == $account)] as $tracked |
    if ($tracked | length) == 0 and $account != "" then "error"
    elif $account != "" and any($tracked[]; .freshness == "auth_required") then "error"
    else [$tracked[] | select(.freshness != "auth_required") | .windows[] | aub_remaining] as $pcts |
      if ($pcts | length) == 0 then (if $account == "" then "healthy" else "error" end)
      elif any($pcts[]; . <= 0) then "exhausted"
      elif any($pcts[]; . < ($threshold | tonumber)) then "low"
      else "healthy"
      end
    end
  ' 2>/dev/null || printf 'error\n'
}

# details <json> [account]
# Print a one-line summary of the quota state for the result document.
details() {
  local json=$1 account=${2:-}
  printf '%s\n' "$json" | jq -c --arg account "$account" "$FM_QUOTA_RANK_JQ"'
    [.accounts[] | select($account == "" or .account == $account) |
      {account, freshness,
       tightest: ([.windows[] | {scope: aub_label, remaining: aub_remaining}] | min_by(.remaining))}
    ] as $summary |
    if $account == "" or ($summary | length) > 1 then
      {account: (if $account == "" then "aggregate" else $account end), summary: $summary}
    else
      $summary[0] // {account: $account, tightest: null}
    end
  ' 2>/dev/null
}

cmd_source_id() {
  resolve_account "${1-}"
  printf '%s\n' "$CANONICAL_SOURCE_ID"
}

cmd_arm() {
  local interval=$DEFAULT_INTERVAL threshold=$DEFAULT_THRESHOLD
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)  positive_number "${2-}" || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --threshold) valid_percent "${2-}" || die "--threshold needs a percent 0-100"; threshold=$2; shift 2 ;;
      --account)   [ -n "${2-}" ] || die "--account needs a value"; resolve_account "$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  resolve_account "$ACCOUNT"
  local source_error
  source_error=$(fm_quota_source_compatible 5 2>&1) || die "$source_error"
  local timeout
  timeout=$(perl -e 'print int($ARGV[0] * 0.8 + 0.5)' "$interval") || timeout=30
  [ "$timeout" -ge 5 ] || timeout=5
  "$SCRIPT_DIR/fm-procevent.sh" register quota "$CANONICAL_SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-quota.sh" poll --interval "$interval" --threshold "$threshold" --account "$ACCOUNT" --timeout "$timeout" || exit 1
  printf 'armed: %s\n' "$CANONICAL_SOURCE_ID"
  printf 'account: %s\n' "${ACCOUNT:-(aggregate)}"
  printf 'threshold: %s%%\n' "$threshold"
  printf 'interval: %ss\n' "$interval"
}

# For use inside the runner: parse the spec argv and run one condition evaluation.
# This is intentionally not the public `arm` path; the runner calls this command
# directly, so the argv must match the registration.
cmd_poll() {
  local interval=$DEFAULT_INTERVAL threshold=$DEFAULT_THRESHOLD timeout=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)  [ "$#" -ge 2 ] || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --threshold) [ "$#" -ge 2 ] || die "--threshold needs a percent 0-100"; threshold=$2; shift 2 ;;
      --account)   [ "$#" -ge 2 ] || die "--account needs a value"; ACCOUNT=$2; shift 2 ;;
      --timeout)   [ "$#" -ge 2 ] || die "--timeout needs a positive integer"; timeout=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  positive_number "$interval" || die "--interval needs a positive number"
  valid_percent "$threshold" || die "--threshold needs a percent 0-100"
  [ -z "$timeout" ] || positive_int "$timeout" || die "--timeout needs a positive integer"
  resolve_account "$ACCOUNT"
  local json detail status polls=0
  while :; do
    polls=$((polls + 1))
    if ! json=$(quota_json "${timeout:-}"); then
      printf 'quota: %s\n' "$CANONICAL_SOURCE_ID"
      printf 'status: error\n'
      printf 'detail: aub status --format json failed, or aub is missing or answered an invalid snapshot\n'
      printf 'condition_polls: %s\n' "$polls"
      exit 0
    fi
    status=$(condition_status "$json" "$ACCOUNT" "$threshold")
    case "$status" in
      healthy) sleep "$interval"; continue ;;
      low|exhausted) : ;;
      *) status=error ;;
    esac
    detail=$(details "$json" "$ACCOUNT")
    printf 'quota: %s\n' "$CANONICAL_SOURCE_ID"
    printf 'status: %s\n' "$status"
    printf 'detail: %s\n' "$detail"
    printf 'condition_polls: %s\n' "$polls"
    exit 0
  done
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(awk '
    $0 == "output:" { exit }
    /^status: / { sub(/^status: /, ""); print; exit }
  ' "$file")
  case "$status" in
    low|exhausted|error) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" != unknown ]
}

cmd_retire() {
  local id account=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --account) [ -n "${2-}" ] || die "--account needs a value"; account=$2; shift 2 ;;
      -*) usage ;;
      *) [ -z "$account" ] || usage; account=$1; shift ;;
    esac
  done
  resolve_account "$account"
  id=$CANONICAL_SOURCE_ID
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  source-id) shift; cmd_source_id "${1-}" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
