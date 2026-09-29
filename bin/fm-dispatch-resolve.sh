#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief with typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>]
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in this process environment, else a
#   TYPESAFE_API_KEY= line in $FM_HOME/.env read with fmx_env_get, the same
#   accessor as FMX_PAIRING_TOKEN (bin/fm-env-lib.sh). The environment wins.
#   Absent in both: one "dispatch-resolve: off" line on stderr, nothing on
#   stdout, exit 0, no network call, so firstmate dispatches exactly as today.
#   The key lives in one shell variable and reaches curl as a header read from
#   a file descriptor, never on argv; nothing logs or writes it.
#
# What it does when on with at least one rule: one POST to
#   https://api.typesafe.ai/v1/systemone with the project name and the brief's
#   `## Captain's intent` and `## Firstmate spec` sections, tagged when it is a
#   scout brief (the whole brief when it has neither section), as state and
#   ONE Choice question whose options are every rule's `when` from
#   config/crew-dispatch.json plus one fixed generic none option. Jev returns
#   the matched rule, a probability per option, and a confidence. Everything
#   after that is jq: the confidence floor (0.6 on the answer confidence, or a
#   rule's declared `min_confidence` on that rule's probability, falling to the
#   most probable other option that clears its own floor), the rule's declared
#   `approval` and `floor`, each profile's declared `floor`, the accounts each
#   profile can run on (its `account`, else its `provider` read as one aub
#   account id, else every config/accounts account of its harness, else the
#   harness's one default account from bin/fm-quota-lib.sh), those accounts'
#   windows from ONE `aub status --format json` snapshot, and the ranking rule
#   bin/fm-quota-lib.sh implements over every profile-and-account candidate. An
#   account absent from the snapshot is unmeasured, never blocked. The model
#   never sees quota, accounts, catalogs, approvals, confidence floors, `why`,
#   or `use`. With no rules, it returns a non-clear result so firstmate keeps
#   using the existing intake.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Never-send check: when the optional $FM_HOME/config/dispatch-never-send list
#   exists, every string value of the built request is checked against it
#   before the POST. Each non-blank, non-# line is a literal matched
#   case-insensitively, with surrounding whitespace trimmed and every run of
#   whitespace, on both sides, treated as one space. A match, or a list that
#   is not a readable regular file, prints one
#   "dispatch-resolve: off (...; nothing sent)" line on stderr naming at most
#   the list line number, never its value, prints nothing on stdout, and exits
#   0 with no network or quota call, exactly like the absent-key off path.
#
# Output (stdout, TOON-style block):
#   dispatch-resolve:
#     status: clear | ambiguous | escalate | error
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     fallback: <runner-up rule taken when the picked rule missed its own floor>
#     reason: <why the status is not clear>
#     candidate: <harness>:<model> account=.. freshness=.. scope=.. remaining=..% burn=.. elapsed=..% reserve=.. -> eligible | eligible, unranked: <reason> | not eligible: <reason>
#     account: <aub account id>                                (status clear only)
#     profile: --harness <h> [--model <m>] [--effort <e>] [--account <a>]
#              (status clear only; --account when the account is a config/accounts name)
#   clear     -> pass the profile line to fm-spawn.sh unless you state a reason to override
#   ambiguous -> confidence below the floor; decide as today from the probabilities
#   escalate  -> the rule requires captain approval, no candidate is rankable, or a genuine tie
#   error     -> API, network, response, or aub failure, or every candidate
#                account needs authentication; decide as today
#   Every outcome exits 0 so an intake is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable brief, an
#   existing unreadable rules file, malformed rules, or missing jq), which is
#   actionable, never selected around.
#
# Environment:
#   TYPESAFE_API_KEY is the only resolver-specific environment setting.
#
# Authority: this tool never replaces firstmate's judgment, quota-array-dispatch,
#   the captain-approval gate, or fm-spawn.sh validation; it publishes one
#   inspectable answer plus every candidate's evidence, in code.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-lib.sh
. "$SCRIPT_DIR/fm-quota-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"

CONFIDENCE_FLOOR=0.6
TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
DEFAULT_WHEN="No listed rule applies to this task."

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
no_rules() {
  printf 'dispatch-resolve:\n  status: escalate\n  reason: no rules to match\n'
  exit 0
}
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BRIEF='' PROJECT='' RULES_PATH="$CONFIG/crew-dispatch.json" RULES=''
NEVER_SEND_PATH="$CONFIG/dispatch-never-send"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

# ---- opt-in gate ---------------------------------------------------------------
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  echo "dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  exit 0
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$BRIEF" ] || die "brief file required (see --help)"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
[ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ] || no_rules
[ -r "$RULES_PATH" ] || die "rules file not readable: $RULES_PATH"
command -v jq >/dev/null 2>&1 || die "jq required"
RULES=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RULES"' EXIT
cp "$RULES_PATH" "$RULES" || die "could not snapshot rules file: $RULES_PATH"
chmod 400 "$RULES" || die "could not protect rules snapshot"
VERIFIED_HARNESSES=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
rules_err=$(jq -r --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
    elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
    else true end;
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def floor_bad($f; $need_provider):
    ($f | type) != "object"
    or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or (if $need_provider
        then (provider_id($f.provider) | not)
        else ($f | has("provider"))
        end);
  def profile_bad($p):
    ($p | type) != "object"
    or (($p.harness | type) != "string") or (($p.harness | length) == 0)
    or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or ($p | has("provider") and (provider_id(.provider) | not))
    or ($p | has("account") and ((.account | type) != "string" or (.account | length) == 0))
    or ($p | has("floor") and floor_bad(.floor; false));
  def duplicate_profiles($items):
    ($items | map([.harness, (.model // null), (.effort // null), (.account // null)] | @json)) as $keys
    | ($keys | length) != ($keys | unique | length);
  if type != "object" then "top-level value must be an object"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif any((.rules // [])[]; (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("min_confidence") and ((.min_confidence | type) != "number" or .min_confidence < 0 or .min_confidence > 1)) then "min_confidence must be a number from 0 through 1 when present"
  elif any((.rules // [])[]; has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((.rules // [])[]; has("select") and .select != "quota-balanced") then
    "unknown select: " + ([.rules[] | select(has("select") and .select != "quota-balanced") | .select] | unique | join(", "))
  elif any((.rules // [])[]; has("floor") and floor_bad(.floor; true)) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
  elif any((.rules // [])[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, account, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any((.rules // [])[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, effort, and account profiles"
  elif any((.rules // [])[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
  elif any((.rules // [])[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
  elif has("default") and (profiles(.default) | length) == 0 then "default must be a profile object or non-empty profile array"
  elif has("default") and any(profiles(.default)[]; profile_bad(.)) then "each default profile needs harness; model, effort, account, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif has("default") and duplicate_profiles(profiles(.default)) then "default must not contain duplicate harness, model, effort, and account profiles"
  elif has("default") and any(profiles(.default)[]; (verified(.harness) | not)) then "each default profile must name a verified harness"
  elif has("default") and any(profiles(.default)[]; (effort_ok(.harness; .model; .effort) | not)) then "each default profile effort must be supported by its harness and model"
  else empty end
' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES_PATH (not JSON)"
[ -z "$rules_err" ] || die "malformed rules file: $RULES_PATH - $rules_err"

# ---- harness -> account set, from the single owner in fm-quota-lib.sh ----------
# `spawn` is true when the accounts come from config/accounts, so the chosen one
# can reach fm-spawn.sh as --account; a default account is measured only.
AMAP='{}'
while IFS= read -r h; do
  [ -n "$h" ] || continue
  accounts=$(fm_quota_accounts_for_harness "$CONFIG" "$h" | jq -Rsc 'split("\n") | map(select(length > 0))')
  spawn=true
  if [ "$accounts" = '[]' ]; then
    spawn=false
    accounts=$(fm_quota_default_account_for_harness "$h" | jq -Rsc 'split("\n") | map(select(length > 0))')
  fi
  AMAP=$(jq -c --arg h "$h" --argjson a "$accounts" --argjson s "$spawn" '. + {($h): {accounts: $a, spawn: $s}}' <<<"$AMAP")
done < <(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ([((.rules // [])[]) | profiles(.use)[]] + profiles(.default // null))
  | map(.harness) | unique | .[]' "$RULES")

RULE_COUNT=$(jq -r '(.rules // []) | length' "$RULES")

emit_error() {
  local reason=$1
  echo "dispatch-resolve: error ($reason)" >&2
  printf 'dispatch-resolve:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

if [ "$RULE_COUNT" -eq 0 ]; then
  no_rules
fi

RESP_FILE=$(mktemp) || die "mktemp failed"
QUOTA=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
TASK_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA"; die "mktemp failed"; }
SEND_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA" "$TASK_TEXT"; die "mktemp failed"; }
trap 'rm -f "$RULES" "$RESP_FILE" "$QUOTA" "$TASK_TEXT" "$SEND_TEXT"' EXIT

never_send_off() {
  echo "dispatch-resolve: off ($1; nothing sent)" >&2
  exit 0
}

# Checks every string the request carries, so no text reaches the network
# unchecked. grep's own stderr is discarded because it can echo the pattern.
never_send_check() {
  local list value n=0 rc
  [ -e "$NEVER_SEND_PATH" ] || [ -L "$NEVER_SEND_PATH" ] || return 0
  { [ -f "$NEVER_SEND_PATH" ] && [ -r "$NEVER_SEND_PATH" ]; } \
    || never_send_off "$NEVER_SEND_PATH is not a readable regular file"
  # Collapse whitespace runs on both sides so a value the brief wraps across
  # lines or spaces differently still matches
  jq -r '.. | strings | gsub("\\s+"; " ")' <<<"$REQUEST" > "$SEND_TEXT" 2>/dev/null \
    || never_send_off "could not extract the request text to check"
  list=$(jq -Rr 'gsub("\\s+"; " ")' "$NEVER_SEND_PATH" 2>/dev/null) \
    || never_send_off "could not read $NEVER_SEND_PATH"
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$SEND_TEXT" 2>/dev/null; rc=$?
    case "$rc" in
      0) never_send_off "brief text matches $NEVER_SEND_PATH line $n" ;;
      1) ;;
      *) never_send_off "could not check the request text against $NEVER_SEND_PATH line $n" ;;
    esac
  done <<<"$list"
}

# Send Jev only the task-specific sections bin/fm-brief.sh scaffolds, plus a
# scout tag from the scout contract line; the rest of a scaffolded brief is
# standard boilerplate whose safety language reads as high stakes on every task.
# A brief with neither section goes whole. Ship delivery mode is deliberately
# not sent: live runs showed it pushing routine ship briefs to the top tier.
brief_kind() {
  if grep -qxF 'This is a SCOUT task: the deliverable is a written report, not a PR.' "$BRIEF"; then
    printf 'Brief kind: scout (report only)\n\n'
  fi
}
task_sections() {
  local heading
  for heading in "## Captain's intent" "## Firstmate spec"; do
    fm_brief_task_heading_present "$BRIEF" "$heading" || continue
    printf '%s\n%s\n\n' "$heading" "$(fm_brief_task_heading_body "$BRIEF" "$heading")"
  done
}
SECTIONS=$(task_sections)
if [ -n "$SECTIONS" ]; then
  { brief_kind; printf '%s\n' "$SECTIONS"; } > "$TASK_TEXT" || die "could not read brief: $BRIEF"
else
  cp "$BRIEF" "$TASK_TEXT" || die "could not read brief: $BRIEF"
fi
LAT_MS=null
command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
  REQUEST=$(jq -n --rawfile brief "$TASK_TEXT" --arg project "$PROJECT" --arg model "$TS_MODEL" \
    --arg none_criterion "$DEFAULT_WHEN" --slurpfile rules "$RULES" '
    ($rules[0]) as $cfg |
    ($cfg.rules | to_entries | map({key: ("rule_" + ((.key + 1) | tostring)), value: .value.when}) | from_entries) as $criteria |
    {
      model: $model,
      state: {task: {project: $project, brief: $brief}},
      questions: {
        rule: {
          type: "choice",
          instructions: "Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule'"'"'s own matching condition; pick `default` when no rule'"'"'s condition is met, including when a rule'"'"'s own exemption text excludes this task.",
          criteria: ($criteria + {default: $none_criterion})
        }
      }
    }')
  never_send_check
  T0=$(fm_timing_now_ms)
  HTTP=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
    -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || HTTP=000
  T1=$(fm_timing_now_ms)
  LAT_MS=$(( T1 - T0 ))
  [ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"
jq -e --slurpfile rules "$RULES" '
    (($rules[0].rules | to_entries | map("rule_" + ((.key + 1) | tostring))) + ["default"] | sort) as $choices |
    (.answers.rule.choice | type) == "string" and
    (.answers.rule.confidence | type) == "number" and
    .answers.rule.confidence >= 0 and .answers.rule.confidence <= 1 and
    (.answers.rule.probabilities | type) == "object" and
    ((.answers.rule.probabilities | keys | sort) == $choices) and
    all(.answers.rule.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    ((.answers.rule.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
    ((has("usage") | not) or
      ((.usage | type) == "object" and
       (.usage.input_tokens | type) == "number" and
       (.usage.output_tokens | type) == "number"))' \
  "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a rule Choice answer"

# ---- quota evidence: one aub status --format json snapshot --------------------
command -v aub >/dev/null 2>&1 || emit_error "aub not installed"
fm_quota_snapshot > "$QUOTA" || emit_error "aub status --format json failed or returned an invalid snapshot"

# ---- resolution: declared gates + quota evidence + ranking, all in jq -----------
RESULT=$(jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" --argjson amap "$AMAP" \
  --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" "$FM_QUOTA_RANK_JQ"'
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | ($r.answers.rule) as $a |
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def floor_state($f; $account):
    if $f == null then "none" else aub_floor($q; $account; $f) end;
  def accounts_of($c):
    if $c.account then [{name: $c.account, spawn: true}]
    elif $c.provider then [{name: $c.provider, spawn: false}]
    else ($amap[$c.harness] // {accounts: [], spawn: false}) as $m | [$m.accounts[] | {name: ., spawn: $m.spawn}]
    end;
  def evaluate($c; $acct):
    (aub_eval($q; $acct.name) + {profile: $c, spawn: $acct.spawn}) as $x |
    if ($x.eligible | not) or $c.floor == null then $x
    else floor_state($c.floor; $acct.name) as $fs |
      if $fs == "below" then $x + {eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif $fs == "unknown" and (($x.unranked // false) | not) then
        $x + {unranked: true, reason: "profile floor \($c.floor.scope) is unverifiable: not rankable"}
      else $x end
    end;
  def expand($c):
    accounts_of($c) as $accounts |
    if ($accounts | length) == 0 then
      [{profile: $c, eligible: true, unranked: true,
        reason: "no account for harness \($c.harness): declare one in config/accounts or name provider on the profile"}]
    else [$accounts[] | evaluate($c; .)] end;
  def rule_at($c):
    if ($c | test("^rule_[1-9][0-9]*$")) then
      ($c | ltrimstr("rule_") | tonumber) as $n |
      if $n <= (($cfg.rules // []) | length) then $cfg.rules[$n - 1] else null end
    else null end;
  def declared_confidence($c): rule_at($c) as $x | $x != null and ($x | has("min_confidence"));
  def confidence_floor($c): if declared_confidence($c) then rule_at($c).min_confidence else ($floor | tonumber) end;
  ($a.choice) as $picked |
  (confidence_floor($picked)) as $picked_floor |
  # A declared floor is checked against the probability of that option whether
  # it is the pick or a runner-up, so a runner-up never needs weaker support
  # than it would as the pick. Only a rule that declares its own floor falls
  # through to a runner-up, so a file with no declared floors keeps the single
  # global floor on the answer confidence exactly.
  (if declared_confidence($picked) | not then
     (if $a.confidence >= $picked_floor then {below: false} else {below: true, global: true} end)
   elif $a.probabilities[$picked] >= $picked_floor then {below: false}
   else
     ([$a.probabilities | to_entries[] | select(.key != $picked and .value >= confidence_floor(.key))]
       | sort_by(-.value)) as $ok |
     if ($ok | length) == 0 then {below: true, why: "no other option clears its own floor"}
     elif ($ok | length) > 1 and $ok[1].value == $ok[0].value then {below: true, why: "runner-up tie"}
     else {below: true, to: $ok[0].key, p: $ok[0].value, to_floor: confidence_floor($ok[0].key)} end
   end) as $fb |
  (if $fb.to then $fb.to else $picked end) as $choice |
  (rule_at($choice)) as $rule |
  (if $rule == null then "none" else floor_state($rule.floor; $rule.floor.provider) end) as $rule_floor_state |
  (if $choice != "default" and $rule == null then []
   elif $rule == null then profiles($cfg.default // null)
   else profiles($rule.use)
   end) as $answer_use |
  (if $choice != "default" and $rule == null then {invalid: "rule \($choice) is not in the rules file"}
   elif $rule == null then {source: "default", use: profiles($cfg.default // null), note: "no rule matched"}
   elif ($rule.approval // "") == "captain" then {source: $choice, escalate: "rule requires the captain'"'"'s explicit approval before dispatch"}
   elif $rule_floor_state == "unknown" then {source: $choice, escalate: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unverifiable"}
   elif $rule_floor_state == "below"
     then {source: "default", use: profiles($cfg.default // null), note: "rule \($choice) floor \($rule.floor.scope) below \($rule.floor.min_percent)%: fall through to default"}
   else {source: $choice, use: profiles($rule.use), note: "rule matched"} end) as $sel |
  def when_of($c): (if rule_at($c) == null then $none_criterion else rule_at($c).when end | .[0:60]);
  {
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    rule: $picked,
    rule_when: when_of($picked),
    confidence: $a.confidence, probabilities: $a.probabilities
  }
  + (if $fb.to then {fallback: "\($choice) (\(when_of($choice))) probability \($fb.p) clears its floor \($fb.to_floor); \($picked) probability \($a.probabilities[$picked]) is below its floor \($picked_floor)"} else {} end)
  as $ev |
  if $sel.invalid then $ev + {status: "error", reason: $sel.invalid}
  elif $fb.below and $fb.global then
    $ev + {status: "ambiguous", reason: "confidence \($a.confidence) below floor \($floor)", candidates: ($answer_use | map(expand(.)) | add // [])}
  elif $fb.below and ($fb.to | not) then
    $ev + {status: "ambiguous", reason: "\($picked) probability \($a.probabilities[$picked]) below its floor \($picked_floor); \($fb.why)", candidates: ($answer_use | map(expand(.)) | add // [])}
  elif $sel.escalate then
    $ev + {status: "escalate", reason: $sel.escalate, candidates: ($answer_use | map(expand(.)) | add // [])}
  elif ($sel.use | length) == 0 then $ev + {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
  else
    ($sel.use | map(expand(.)) | add) as $all |
    (any($all[]; .eligible and ((.unranked // false) | not) and .tier == 1)) as $has_fresh |
    ($all | map(if .tier == 2 and .eligible and $has_fresh then . + {held: true} else . end)) as $cands |
    (aub_rank($cands)) as $ranked |
    ([$cands[] | select(.unranked)]) as $unranked |
    if ($ranked | length) == 0 then
      if ($cands | length) > 0 and all($cands[]; .auth // false) then
        $ev + {status: "error", reason: "every candidate account needs authentication in aub: \([$cands[].account] | unique | join(", "))", note: $sel.note, candidates: $cands}
      else $ev + {status: "escalate", reason: "no rankable eligible candidate", note: $sel.note, candidates: $cands}
      end
    else
      ($ranked[0]) as $best |
      ([$ranked[] | select(.reserve == $best.reserve and .pct == $best.pct and .age == $best.age)] | length) as $ties |
      if $ties > 1 then $ev + {status: "escalate", reason: "genuine reserve tie", note: $sel.note, candidates: $cands}
      else $ev + {status: "clear", note: $sel.note, candidates: $cands, chosen: $best}
        + (if $best.tier == 2 then {stale_note: "account \($best.account) is stale; ranked because no fresh account is eligible"} else {} end)
        + (if ($unranked | length) > 0 then
             {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[] | .account // .profile.harness] | unique | join(", ")))"}
           else {} end)
      end
    end
  end') || emit_error "resolution failed"

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def pct($value): if ($value | type) == "number" then ($value * 10 | round / 10 | tostring) else "-" end;
  def shell_arg: flat | @sh;
  "dispatch-resolve:",
  "  status: \(.status | flat)",
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  "  rule: \(.rule | flat) (\(.rule_when | flat))   confidence: \(.confidence | flat)",
  "  probabilities: \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))",
  (if .fallback then "  fallback: \(.fallback | flat)" else empty end),
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
  (.candidates[]? | "  candidate: \(.profile.harness | flat):\(show(.profile.model))"
      + (if .account then "  account=\(.account | flat)" else "" end)
      + (if .freshness then "  freshness=\(.freshness | flat)" else "" end)
      + (if .scope then "  scope=\(.scope | flat)  remaining=\(pct(.pct))%  burn=\(show(.burn))  elapsed=\(pct(.elapsed * 100))%  reserve=\(pct(.reserve))" else "" end)
      + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty"
                   elif .held then "eligible, stale: ranked only when no fresh account is eligible"
                   elif .eligible then "eligible"
                   else "not eligible: \(.reason | flat)" end)),
  (if .stale_note then "  note: \(.stale_note | flat)" else empty end),
  (if .chosen then "  account: \(.chosen.account | flat)" else empty end),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end)
      + (if .chosen.spawn then " --account \(.chosen.account | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
