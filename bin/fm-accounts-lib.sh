#!/usr/bin/env bash
# fm-accounts-lib.sh - the single owner of the local named-account table,
# config/accounts: its line format, its validation, and which account a
# crewmate or scout spawn launches under.
#
# docs/configuration.md "Named worker accounts" owns the operator-facing
# contract. Sourced by bin/fm-spawn.sh and bin/fm-bootstrap.sh.
#
# One account per line, blank lines and lines starting with # ignored:
#   <name> <harness> [default] KEY=VALUE [KEY=VALUE ...]
# Tokens are separated by spaces or tabs, so a value cannot contain either.
# A name is [A-Za-z0-9][A-Za-z0-9._-]*, except `ordinary`, which the worker
# account pin records for its own vendor-default selection. A KEY is
# [A-Z_][A-Z0-9_]*. At most one line per harness may carry `default`.
#
# Every parsed line becomes one record, "<line>\t<name>\t<harness>\t<default>\t<status>\t<detail>",
# where default is 1 or 0, status is `ok` or `bad`, and detail holds the
# space-separated KEY=VALUE pairs for `ok` or the reason for `bad`. A bad line
# still names its account and harness whenever those tokens exist, so a spawn
# that names that account, or relies on that default, refuses instead of
# silently launching on another account while every other line keeps working.

FM_ACCOUNTS_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
FM_ACCOUNTS_KEY_RE='^[A-Z_][A-Z0-9_]*$'

# fm_accounts_records <file>
# Prints one record per account line of an existing readable file.
fm_accounts_records() {
  local file=$1 line n=0 name harness is_default status detail tok key seen_names=' ' seen_defaults=' '
  local -a toks
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
    *[![:space:]]*) ;;
    *) continue ;;
    esac
    read -r -a toks <<<"$line"
    case "${toks[0]}" in '#'*) continue ;; esac
    name=${toks[0]} harness=${toks[1]:-} is_default=0 status=ok detail=
    set -- "${toks[@]:2}"
    if [ "${1:-}" = default ]; then
      is_default=1
      shift
    fi
    if [[ "${line//$'\t'/ }" == *[[:cntrl:]]* ]]; then
      status=bad detail='contains a control character'
    elif ! [[ "$name" =~ $FM_ACCOUNTS_NAME_RE ]] || [ "$name" = ordinary ]; then
      status=bad detail="account name '$name' must match [A-Za-z0-9][A-Za-z0-9._-]* and must not be 'ordinary'"
    elif [ -z "$harness" ] || [ "$#" -eq 0 ]; then
      status=bad detail='expected <name> <harness> [default] KEY=VALUE [KEY=VALUE ...]'
    else
      for tok in "$@"; do
        case "$tok" in
        *=*) ;;
        *)
          status=bad detail="token '$tok' is not KEY=VALUE"
          break
          ;;
        esac
        key=${tok%%=*}
        if ! [[ "$key" =~ $FM_ACCOUNTS_KEY_RE ]]; then
          status=bad detail="key '$key' is not [A-Z_][A-Z0-9_]*"
          break
        fi
      done
      [ "$status" != ok ] || detail="$*"
    fi
    if [ "$status" = ok ]; then
      case "$seen_names" in
      *" $name "*) status=bad detail="account '$name' is declared more than once" ;;
      esac
    fi
    if [ "$status" = ok ] && [ "$is_default" = 1 ]; then
      case "$seen_defaults" in
      *" $harness "*) status=bad detail="a second default for harness '$harness'" ;;
      esac
    fi
    seen_names="$seen_names$name "
    [ "$is_default" = 0 ] || seen_defaults="$seen_defaults$harness "
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$name" "$harness" "$is_default" "$status" "$detail"
  done <"$file"
}

# fm_accounts_diagnostics <config-dir>
# Prints one "ACCOUNTS: invalid config/accounts line <n> - <reason>" line per
# bad line, or one line for an unreadable file; silent when absent or valid.
fm_accounts_diagnostics() {
  local file=$1/accounts n name harness is_default status detail
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "ACCOUNTS: invalid config/accounts - not a readable regular file"
    return 0
  fi
  while IFS=$'\t' read -r n name harness is_default status detail; do
    [ "$status" = bad ] || continue
    echo "ACCOUNTS: invalid config/accounts line $n - $detail"
  done < <(fm_accounts_records "$file")
}

# fm_accounts_select <config-dir> <harness> [<requested-name>]
# Prints "<name>\t<KEY=VALUE ...>" for the account this spawn launches under:
# the requested one, or else the harness's default line. Prints nothing when
# nothing is requested and no default applies. On refusal prints one error
# naming config/accounts and returns 1.
fm_accounts_select() {
  local config=$1 want_harness=$2 requested=${3:-} file n name harness is_default status detail found=
  file=$config/accounts
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    [ -z "$requested" ] || {
      echo "error: account '$requested' is not declared: config/accounts does not exist" >&2
      return 1
    }
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/accounts must be a readable regular file: $file" >&2
    return 1
  fi
  while IFS=$'\t' read -r n name harness is_default status detail; do
    if [ -n "$requested" ]; then
      [ "$name" = "$requested" ] || continue
    else
      [ "$is_default" = 1 ] && [ "$harness" = "$want_harness" ] || continue
    fi
    if [ "$status" = bad ]; then
      echo "error: config/accounts line $n (account '$name') is invalid: $detail" >&2
      return 1
    fi
    [ -z "$found" ] || continue
    found="$name"$'\t'"$harness"$'\t'"$detail"
  done < <(fm_accounts_records "$file")
  if [ -z "$found" ]; then
    [ -z "$requested" ] || {
      echo "error: account '$requested' is not declared in config/accounts" >&2
      return 1
    }
    return 0
  fi
  IFS=$'\t' read -r name harness detail <<<"$found"
  if [ "$harness" != "$want_harness" ]; then
    echo "error: account '$name' in config/accounts is for harness '$harness', not the requested harness '$want_harness'" >&2
    return 1
  fi
  printf '%s\t%s\n' "$name" "$detail"
}
