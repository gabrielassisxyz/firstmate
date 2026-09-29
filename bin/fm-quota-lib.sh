# shellcheck shell=bash
# Shared quota source for the bootstrap diagnostic, the dispatch resolver, the
# worker-side chooser, and the mid-task quota watch.
# Usage: . bin/fm-quota-lib.sh
#
# The one quota source is agent-usage-book: `aub status --format json`, schema 5
# envelope (`schema`, `command`, `run`, `generated_at`, then `accounts[]`). Each
# account carries `account`, `freshness` (fresh | stale | auth_required),
# `limiting_window`, and `windows[]` with `quota_used_ppm`, `resets_at_nanos`,
# `nominal_duration_nanos`, `burn_rate`, and a `model` on model-scoped windows.
# The account is the routing unit: firstmate's config/accounts names match aub's
# account ids one to one.
#
# fm_quota_source_compatible [timeout]  aub is on PATH, answers --version, and
#                                        answers `status --format json` with a
#                                        valid schema 5 envelope within the
#                                        timeout (FM_QUOTA_SOURCE_TIMEOUT when
#                                        omitted); otherwise one line naming aub
#                                        on stderr and status 1.
# fm_quota_snapshot [timeout]            print one validated snapshot.
# fm_quota_json_valid                    validate a snapshot on stdin.
# fm_quota_accounts_for_harness <config-dir> <harness>
#                                        every valid config/accounts name whose
#                                        harness matches, one per line.
# fm_quota_default_account_for_harness <harness>
#                                        the one aub account a harness with no
#                                        config/accounts line is measured on.
# FM_QUOTA_RANK_JQ                       the ranking rule, as jq definitions.

FM_QUOTA_AUB_SCHEMA=5
FM_QUOTA_SOURCE_TIMEOUT=10
# aub's README builds from source with cargo; this is that build without a local clone.
FM_QUOTA_AUB_INSTALL='cargo install --git https://github.com/gabrielassisxyz/agent-usage-book'
# A rule floor's `provider` and a profile's `provider` name an aub account id.
# shellcheck disable=SC2034  # read by the sourcing consumers
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

_FM_QUOTA_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ "$(type -t fm_run_timed)" != function ]; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$_FM_QUOTA_LIB_DIR/fm-timeout-lib.sh"
fi
if [ "$(type -t fm_accounts_records)" != function ]; then
  # shellcheck source=bin/fm-accounts-lib.sh
  . "$_FM_QUOTA_LIB_DIR/fm-accounts-lib.sh"
fi

# The ranking rule stated in .agents/skills/quota-array-dispatch/SKILL.md
# "Rank accounts", as jq definitions a consumer prepends to its program:
#   aub_eval($snap; $name)  one account's evidence: freshness, limiting-window
#                           scope, remaining `pct`, `elapsed`, `burn`, `reserve`,
#                           `tier` (1 fresh, 2 stale), and eligible/unranked with
#                           a reason. An account absent from the snapshot is
#                           eligible but unranked, never blocked.
#   aub_floor($snap; $name; $floor)
#                           "ok", "below", or "unknown" for {scope, min_percent}
#                           against every window whose scope label matches.
#   aub_rank($evals)        the rankable evaluations: fresh ones, or stale ones
#                           only when no fresh one is, by reserve, then
#                           remaining, then the fresher observation.
# A window's scope label is `account_wide`, `model:<model>`, or `group:<group>`,
# the same labels aub prints in `included_scopes`.
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_QUOTA_RANK_JQ='
  def aub_num: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;
  def aub_label:
    .scope as $s |
    if ($s | type) == "object" then
      (if $s.kind == "model_group" then "group:\($s.group)" else ($s | tojson) end)
    elif $s == "model" then "model:\(.model // "")"
    else $s end;
  def aub_untriggered: .resets_at_nanos == null and (.quota_used_ppm // 0) == 0;
  def aub_remaining:
    if aub_untriggered then 100 else 100 - ((.quota_used_ppm | aub_num) // 0) / 10000 end;
  def aub_elapsed($now):
    if .resets_at_nanos == null or ((.nominal_duration_nanos | aub_num) // 0) <= 0 then 0
    else (1 - ((.resets_at_nanos - $now) / .nominal_duration_nanos))
      | if . < 0 then 0 elif . > 1 then 1 else . end
    end;
  def aub_account($snap; $name): [($snap.accounts // [])[] | select(.account == $name)] | first;
  def aub_limiting($a):
    [$a.windows[]? | select(.scope == $a.limiting_window.scope and
      .nominal_duration_nanos == $a.limiting_window.nominal_duration_nanos)] | first;
  def aub_eval($snap; $name):
    aub_account($snap; $name) as $a |
    if $a == null then
      {account: $name, found: false, eligible: true, unranked: true,
       reason: "account \($name) not in the aub snapshot"}
    elif $a.freshness == "auth_required" then
      {account: $name, found: true, freshness: $a.freshness, eligible: false, auth: true,
       reason: "auth_required\(if $a.reason then " (\($a.reason))" else "" end)"}
    elif ($a.freshness != "fresh" and $a.freshness != "stale") then
      {account: $name, found: true, freshness: $a.freshness, eligible: true, unranked: true,
       reason: "freshness \($a.freshness) is not rankable"}
    else
      aub_limiting($a) as $w |
      if $w == null then
        {account: $name, found: true, freshness: $a.freshness, eligible: true, unranked: true,
         reason: "no limiting window in the aub snapshot"}
      else
        ($w | aub_remaining) as $r |
        ($w | aub_elapsed($snap.generated_at)) as $e |
        (($w.burn_rate | aub_num) // 0) as $b |
        (if ($w | aub_untriggered) then 100 else $r - $b * (1 - $e) * 100 end) as $reserve |
        {account: $name, found: true, freshness: $a.freshness,
         tier: (if $a.freshness == "fresh" then 1 else 2 end),
         scope: ($w | aub_label), pct: $r, elapsed: $e, burn: $b, reserve: $reserve,
         age: ($a.observation_age_nanos // null)}
        + (if $r > 0 then {eligible: true, reason: "ok"}
           else {eligible: false, reason: "0% remaining at \($w | aub_label)"} end)
      end
    end;
  def aub_floor($snap; $name; $floor):
    aub_account($snap; $name) as $a |
    if $a == null or $a.freshness == "auth_required" then "unknown"
    else [$a.windows[]? | select(aub_label == $floor.scope) | aub_remaining] as $pcts |
      if ($pcts | length) == 0 then "unknown"
      elif any($pcts[]; . < $floor.min_percent) then "below"
      else "ok" end
    end;
  def aub_rank($evals):
    [$evals[] | select(.eligible and ((.unranked // false) | not))] as $ok |
    ([$ok[] | select(.tier == 1)] | if length > 0 then . else [$ok[] | select(.tier == 2)] end)
    | sort_by([-.reserve, -.pct, (.age // 0)]);
'

fm_quota_json_valid() {
  jq -se --argjson schema "$FM_QUOTA_AUB_SCHEMA" '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      .schema == $schema and
      (.generated_at | type) == "number" and
      (.accounts | type) == "array" and
      (.accounts | length) > 0 and
      all(.accounts[];
        type == "object" and
        (.account | type) == "string" and (.account | length) > 0 and
        (.freshness | type) == "string" and (.freshness | length) > 0 and
        (.windows | type) == "array" and
        all(.windows[];
          type == "object" and
          (.quota_used_ppm | type) == "number" and
          (.nominal_duration_nanos | type) == "number" and
          ((.resets_at_nanos == null) or ((.resets_at_nanos | type) == "number")))) and
      (([.accounts[].account] | length) == ([.accounts[].account] | unique | length))
    )
  ' >/dev/null 2>&1
}

_fm_quota_timeout() {
  local timeout=${1:-$FM_QUOTA_SOURCE_TIMEOUT}
  case "$timeout" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  printf '%s\n' "$timeout"
}

fm_quota_snapshot() {
  local timeout output
  timeout=$(_fm_quota_timeout "${1:-}") || return 1
  command -v aub >/dev/null 2>&1 || return 1
  output=$(fm_run_timed "$timeout" aub status --format json 2>/dev/null </dev/null) || return 1
  printf '%s\n' "$output" | fm_quota_json_valid || return 1
  printf '%s\n' "$output"
}

fm_quota_source_compatible() {
  local timeout
  if ! timeout=$(_fm_quota_timeout "${1:-}"); then
    echo "aub: invalid quota source timeout: ${1:-}" >&2
    return 1
  fi
  if ! command -v aub >/dev/null 2>&1; then
    echo "aub: not on PATH (install: $FM_QUOTA_AUB_INSTALL)" >&2
    return 1
  fi
  if ! fm_run_timed "$timeout" aub --version >/dev/null 2>&1 </dev/null; then
    echo "aub: --version failed (install: $FM_QUOTA_AUB_INSTALL)" >&2
    return 1
  fi
  if ! fm_quota_snapshot "$timeout" >/dev/null; then
    echo "aub: status --format json did not answer a schema $FM_QUOTA_AUB_SCHEMA snapshot within ${timeout}s (install: $FM_QUOTA_AUB_INSTALL)" >&2
    return 1
  fi
}

fm_quota_accounts_for_harness() {
  local config=$1 want=$2 file name harness status
  file=$config/accounts
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS=$'\t' read -r _ name harness _ status _; do
    [ "$status" = ok ] && [ "$harness" = "$want" ] || continue
    printf '%s\n' "$name"
  done < <(fm_accounts_records "$file")
}

# Harnesses that run on exactly one aub account and so need no config/accounts
# line; every other harness is measured only through config/accounts.
fm_quota_default_account_for_harness() {
  case "$1" in
    agy)      printf 'agy\n' ;;
    opencode) printf 'opencode-go\n' ;;
    *)        return 1 ;;
  esac
}
