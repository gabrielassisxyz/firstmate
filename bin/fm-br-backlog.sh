#!/usr/bin/env bash
# fm-br-backlog.sh - the `br` backlog backend: the tasks-axi verbs firstmate
# uses, answered by one `br` tracker per project instead of a firstmate row.
#
# Usage: fm-br-backlog.sh <verb> [args...]
#   show <id> [--full]
#   list [--state queued|in_flight|held|done] [--blocked] [--fields a,b,...]
#   ready
#   start <id>
#   done <id> [--pr <url> | --note <text> | --report <path>]
#   reopen <id>
#   update <id> [--body-file <path>] [--pr <url>] [--report <path>] [--archive-body]
#   hold <id> [--reason <text>] [--kind <kind>] [--until <date>]
#   unhold <id>
#
# Selected by `config/backlog-backend` containing `br`: the backlog runners in
# bin/fm-backlog-transition-lib.sh, bin/fm-captain-hold.sh and
# bin/fm-tasks-axi.sh then run this command with the argument vector they would
# have given tasks-axi, so no caller changes and no tasks-axi row is ever
# written. docs/configuration.md ("Backlog backend") owns the configuration.
#
# PROJECTS. `config/br-projects` maps each tracker, one `<prefix> <absolute
# path>` per line (blank lines and `#` comments ignored). An id's prefix is
# everything before its last `-`, and br runs with the mapped path as its
# working directory. A prefix the table does not list is NOT_FOUND, never a
# guess. The config directory is FM_BR_BACKLOG_CONFIG when the runner passes
# it, else FM_CONFIG_OVERRIDE, else $FM_HOME/config.
#
# STATE. Each bead is printed in the shape tasks-axi's `show` uses, so
# fm_backlog_row_probe and the captain-hold readers parse it unchanged:
#   state     open, blocked, deferred => queued; in_progress, batch_pending =>
#             in_flight; closed => done; a tombstone is NOT_FOUND; any other
#             status is refused rather than mapped by guess.
#   held      yes for a deferred bead, and then hold_kind is captain.
#   blocked   yes when the bead has an unclosed `blocks` dependency and
#             ready-landed does not list it: ready-landed is the single owner of
#             when a blocker counts as landed, so nothing here re-derives it.
# The Queued list is `ready-landed --repo <path> --json` for every tracker.
# ready-landed resolves from FM_READY_LANDED, else PATH; when neither has it,
# every read that needs it stops naming it instead of falling back to
# `br ready`, which would dispatch work whose blocker merely closed.
#
# MUTATIONS run with `--actor firstmate`, so br records who claimed and closed.
# start and done are idempotent, because crash replay re-runs them: a bead
# already claimed by firstmate or already closed is reported as ok.
#
# BODY. The task body firstmate reads and rewrites is the bead's `notes` field,
# not its description: captain holds and retained deliverables rewrite the
# whole body and read it back, which only a field that round-trips can carry.
# `update --body-file` replaces `notes`; `--pr` and `--report` add a comment.
# The description stays the author's and is shown as `description`.
#
# Exit status: 0 ok; 1 not found (with `code: NOT_FOUND` on stdout, the marker
# fm_backlog_row_probe reads) or a br failure; 2 usage or configuration error.
set -u

ACTOR=firstmate

fail() {
  printf 'fm-br-backlog: %s\n' "$*" >&2
  exit 2
}

config_dir() {
  if [ -n "${FM_BR_BACKLOG_CONFIG:-}" ]; then
    printf '%s\n' "$FM_BR_BACKLOG_CONFIG"
  elif [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_CONFIG_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s/config\n' "$FM_HOME"
  else
    fail "cannot locate config/br-projects: FM_HOME is not set"
  fi
}

CONFIG_DIR=$(config_dir) || exit 2
PROJECTS_FILE="$CONFIG_DIR/br-projects"

# Every `<prefix>\t<path>` pair the table lists.
project_rows() {
  [ -f "$PROJECTS_FILE" ] || fail "$PROJECTS_FILE does not exist; list one '<prefix> <absolute path>' per tracker"
  awk '
    { sub(/#.*/, "") }
    NF == 0 { next }
    NF != 2 || $2 !~ /^\// { bad = bad " " NR; next }
    { print $1 "\t" $2 }
    END { if (bad != "") { print "malformed line(s):" bad > "/dev/stderr"; exit 3 } }
  ' "$PROJECTS_FILE" || fail "$PROJECTS_FILE has lines that are not '<prefix> <absolute path>'"
}

not_found() {  # <id> [stderr-line]
  printf 'error: "Task %s not found"\ncode: NOT_FOUND\n' "$1"
  [ -z "${2:-}" ] || printf 'fm-br-backlog: %s\n' "$2" >&2
  exit 1
}

# Sets PROJECT_PATH for <id>, or exits NOT_FOUND naming the prefix and table.
resolve_project() {  # <id>
  local id=$1 prefix rows
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) fail "task id must be a slug: $id" ;;
  esac
  prefix=${id%-*}
  rows=$(project_rows) || exit 2
  PROJECT_PATH=$(printf '%s\n' "$rows" | awk -F '\t' -v p="$prefix" '$1 == p { print $2; exit }')
  if [ "$prefix" = "$id" ] || [ -z "$PROJECT_PATH" ]; then
    not_found "$id" "prefix '$prefix' of $id is not listed in $PROJECTS_FILE"
  fi
  [ -d "$PROJECT_PATH" ] || fail "tracker path for prefix '$prefix' is not a directory: $PROJECT_PATH"
}

br_in() {  # <path> <br args...>
  local path=$1
  shift
  (cd "$path" && br "$@")
}

ready_landed_bin() {
  local bin=${FM_READY_LANDED:-ready-landed}
  command -v "$bin" >/dev/null 2>&1 \
    || fail "ready-landed is not available (set FM_READY_LANDED or put ready-landed on PATH); it alone decides which beads are Queued"
  printf '%s\n' "$bin"
}

# The ids ready-landed would dispatch from <path>, one per line.
ready_ids() {  # <path>
  local bin out
  bin=$(ready_landed_bin) || exit 2
  out=$("$bin" --repo "$1" --json 2>/dev/null) || fail "ready-landed --repo $1 failed"
  printf '%s\n' "$out" | jq -r '.[].id' || fail "ready-landed --repo $1 printed no JSON array"
}

# One bead's br JSON object, or NOT_FOUND. Sets BEAD_JSON.
load_bead() {  # <id>
  local id=$1 out status
  out=$(br_in "$PROJECT_PATH" show "$id" --format json 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    if printf '%s\n' "$out" | grep -q 'ISSUE_NOT_FOUND'; then
      not_found "$id"
    fi
    printf 'error: br show %s failed: %s\n' "$id" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    exit 1
  fi
  BEAD_JSON=$(printf '%s\n' "$out" | jq -c '.[0]') || {
    printf 'error: br show %s printed unreadable JSON\n' "$id"
    exit 1
  }
  [ "$(printf '%s\n' "$BEAD_JSON" | jq -r '.status')" != tombstone ] || not_found "$id"
}

# tasks-axi's state for a br status; empty for a status with no mapping.
JQ_STATE='def fm_state: if .status == "closed" then "done"
  elif .status == "in_progress" or .status == "batch_pending" then "in_flight"
  elif .status == "open" or .status == "blocked" or .status == "deferred" then "queued"
  else "" end;'

bead_blocked() {  # <id>
  local open_blockers
  open_blockers=$(printf '%s\n' "$BEAD_JSON" | jq -r '
    [.dependencies[]? | select(.dependency_type == "blocks" and .status != "closed")] | length')
  if [ "$open_blockers" = 0 ] && [ "$(printf '%s\n' "$BEAD_JSON" | jq -r .status)" != blocked ]; then
    printf 'no\n'
    return 0
  fi
  local ready
  ready=$(ready_ids "$PROJECT_PATH") || exit 2
  if printf '%s\n' "$ready" | grep -Fqx -- "$1"; then
    printf 'no\n'
  else
    printf 'yes\n'
  fi
}

verb_show() {  # <id> [--full]
  local id=${1:-} state blocked
  [ -n "$id" ] || fail "usage: show <id> [--full]"
  resolve_project "$id"
  load_bead "$id"
  state=$(printf '%s\n' "$BEAD_JSON" | jq -r "$JQ_STATE fm_state")
  if [ -z "$state" ]; then
    printf 'error: bead %s has status %s, which has no backlog state\n' \
      "$id" "$(printf '%s\n' "$BEAD_JSON" | jq -r .status)"
    exit 1
  fi
  blocked=$(bead_blocked "$id") || exit $?
  printf '%s\n' "$BEAD_JSON" | jq -r --arg state "$state" --arg blocked "$blocked" \
    --arg repo "${id%-*}" '
    (.status == "deferred") as $held
    | "  state: \($state)",
      "  held: \(if $held then "yes" else "no" end)",
      "  blocked: \($blocked)",
      "  hold_kind: \(if $held then "captain" else "none" end)",
      "  id: \(.id)",
      "  title: \(.title | tojson)",
      "  hold_reason: \"-\"",
      "  hold_until: \((.defer_until // "-") | tojson)",
      "  kind: task",
      "  repo: \($repo)",
      "  assignee: \((.assignee // "-") | tojson)",
      "  description: \((.description // "") | tojson)",
      "  body: \((.notes // "") | tojson)"'
}

# One project's rows as TSV: id, state, title, hold_kind, hold_until, blocked_by.
project_list() {  # <path> <state> <blocked-only: 0|1>
  local path=$1 state=$2 blocked_only=$3 ready json bin
  if [ "$blocked_only" = 1 ]; then
    ready=$(ready_ids "$path") || exit 2
    json=$(br_in "$path" blocked --format json 2>/dev/null) || fail "br blocked failed in $path"
    printf '%s\n' "$json" | jq -r --arg ready "$ready" '
      ($ready | split("\n")) as $r
      | .[] | select(.status != "deferred") | select(.id as $i | $r | index($i) | not)
      | [.id, "queued", .title, "none", "-", (.blocked_by // [] | join(" "))] | @tsv'
    return
  fi
  if [ "$state" = queued ]; then
    bin=$(ready_landed_bin) || exit 2
    json=$("$bin" --repo "$path" --json 2>/dev/null) || fail "ready-landed --repo $path failed"
    printf '%s\n' "$json" | jq -r '.[] | [.id, "queued", .title, "none", "-", "-"] | @tsv'
    return
  fi
  json=$(br_in "$path" list --all --format json 2>/dev/null) || fail "br list failed in $path"
  printf '%s\n' "$json" | jq -r --arg want "$state" "$JQ_STATE"'
    .issues[] | select(fm_state != "")
    | (.status == "deferred") as $held
    | select(if $want == "" then fm_state != "done"
             elif $want == "held" then $held
             else fm_state == $want end)
    | [.id, fm_state, .title, (if $held then "captain" else "none" end),
       (.defer_until // "-"), "-"] | @tsv'
}

render_rows() {  # <header-name> <fields-csv> <tsv-rows>
  local name=$1 fields=$2 rows=$3 count
  count=$(printf '%s' "$rows" | grep -c . || true)
  printf 'count: %s\n' "$count"
  [ "$count" -gt 0 ] || return 0
  printf '%s[%s]{id,state,kind,repo,title%s}:\n' "$name" "$count" "${fields:+,$fields}"
  printf '%s\n' "$rows" | jq -Rr --arg fields "$fields" '
    split("\t") as $c
    | def cell: if test("[,\"]") or test("^ | $") or . == "" then tojson else . end;
      ({hold_kind: $c[3], hold_reason: "-", hold_until: $c[4], blocked_by: $c[5]}) as $extra
    | ([$c[0], $c[1], "task", ($c[0] | sub("-[^-]*$"; "")), $c[2]]
       + [($fields | split(",") | .[] | select(. != "")) | ($extra[.] // "-")])
    | map(cell) | "  " + join(",")'
}

verb_list() {  # [--state s] [--blocked] [--fields f]
  local state='' blocked_only=0 fields='' name=tasks rows='' table prefix path
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) state=${2:-}; shift ;;
      --state=*) state=${1#*=} ;;
      --blocked) blocked_only=1 ;;
      --fields) fields=${2:-}; shift ;;
      --fields=*) fields=${1#*=} ;;
      --ready) state=queued; name=ready ;;
      *) fail "list does not accept $1" ;;
    esac
    shift
  done
  case "$state" in
    ''|queued|in_flight|held|done) ;;
    *) fail "unknown state: $state" ;;
  esac
  table=$(project_rows) || exit 2
  while IFS="$(printf '\t')" read -r prefix path; do
    [ -n "$prefix" ] || continue
    rows="$rows$(project_list "$path" "$state" "$blocked_only")"$'\n' || exit $?
  done <<EOF
$table
EOF
  render_rows "$name" "$fields" "$(printf '%s' "$rows" | grep . || true)"
}

# Run one br mutation, printing an ok line or the first line of br's error.
mutate() {  # <id> <what> <br args...>
  local id=$1 what=$2 out
  shift 2
  if out=$(br_in "$PROJECT_PATH" "$@" --actor "$ACTOR" 2>&1); then
    printf 'ok: %s %s\n' "$what" "$id"
    return 0
  fi
  printf 'error: %s %s failed: %s\n' "$what" "$id" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  exit 1
}

bead_field() {  # <jq-path>
  printf '%s\n' "$BEAD_JSON" | jq -r "$1 // empty"
}

verb_start() {  # <id>
  local id=${1:-}
  [ -n "$id" ] || fail "usage: start <id>"
  resolve_project "$id"
  load_bead "$id"
  if [ "$(bead_field .status)" = in_progress ] && [ "$(bead_field .assignee)" = "$ACTOR" ]; then
    printf 'ok: start %s (already claimed)\n' "$id"
    return 0
  fi
  mutate "$id" start update "$id" --claim
}

verb_done() {  # <id> [--pr url | --note text | --report path]
  local id=${1:-} reason=''
  [ -n "$id" ] || fail "usage: done <id> [--pr <url> | --note <text> | --report <path>]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr) reason="Landed: ${2:-}"; shift ;;
      --note) reason="Landed: ${2:-}"; shift ;;
      --report) reason="Report: ${2:-}"; shift ;;
      *) fail "done does not accept $1" ;;
    esac
    shift
  done
  resolve_project "$id"
  load_bead "$id"
  if [ "$(bead_field .status)" = closed ]; then
    printf 'ok: done %s (already closed)\n' "$id"
    return 0
  fi
  mutate "$id" "done" close "$id" --reason "${reason:-Completed by $ACTOR}"
}

verb_reopen() {  # <id>
  local id=${1:-}
  [ -n "$id" ] || fail "usage: reopen <id>"
  resolve_project "$id"
  load_bead "$id"
  case "$(bead_field .status)" in
    closed) mutate "$id" reopen reopen "$id" >/dev/null ;;
    open|deferred) ;;
    *) mutate "$id" reopen update "$id" --status open >/dev/null ;;
  esac
  mutate "$id" reopen update "$id" --assignee ""
}

absolute_path() {  # <path>
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

verb_update() {  # <id> [flags]
  local id=${1:-} note='' body_file=''
  [ -n "$id" ] || fail "usage: update <id> [--body-file <path>] [--pr <url>] [--report <path>]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body-file) body_file=$(absolute_path "${2:-}"); shift ;;
      --body-file=*) body_file=$(absolute_path "${1#*=}") ;;
      --pr) note="Deliverable: PR ${2:-}"; shift ;;
      --report) note="Deliverable: report ${2:-}"; shift ;;
      --archive-body) ;;
      *) fail "update on the br backend does not accept $1" ;;
    esac
    shift
  done
  resolve_project "$id"
  if [ -n "$body_file" ]; then
    [ -r "$body_file" ] || fail "cannot read $body_file"
    mutate "$id" update update "$id" --notes "$(cat "$body_file")"
  fi
  [ -z "$note" ] || mutate "$id" update comments add "$id" --message "$note"
  [ -n "$body_file$note" ] || fail "update needs --body-file, --pr or --report"
}

verb_hold() {  # <id> [--reason r] [--kind k] [--until d]
  local id=${1:-} reason='' until=''
  local -a args=()
  [ -n "$id" ] || fail "usage: hold <id> [--reason <text>] [--until <date>]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=${2:-}; shift ;;
      --kind) shift ;;
      --until) until=${2:-}; shift ;;
      *) fail "hold does not accept $1" ;;
    esac
    shift
  done
  resolve_project "$id"
  [ -z "$until" ] || args+=(--until "$until")
  [ -z "$reason" ] || args+=(--transition-comment "Held for the captain: $reason")
  mutate "$id" hold defer "$id" "${args[@]+"${args[@]}"}"
}

verb_unhold() {  # <id>
  local id=${1:-}
  [ -n "$id" ] || fail "usage: unhold <id>"
  resolve_project "$id"
  mutate "$id" unhold undefer "$id"
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v br >/dev/null 2>&1 || fail "br is not on PATH"

verb=${1:-}
[ "$#" -eq 0 ] || shift
case "$verb" in
  show) verb_show "$@" ;;
  list) verb_list "$@" ;;
  ready) verb_list --ready "$@" ;;
  start) verb_start "$@" ;;
  done) verb_done "$@" ;;
  reopen) verb_reopen "$@" ;;
  update) verb_update "$@" ;;
  hold) verb_hold "$@" ;;
  unhold) verb_unhold "$@" ;;
  -h|--help|'') awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
  *) fail "$verb is not a backlog verb on the br backend; create and edit beads with br in the project's checkout" ;;
esac
