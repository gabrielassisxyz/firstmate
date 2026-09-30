#!/usr/bin/env bash
# Regression test for the pane-shell directory change surviving an aliased `cd`.
# Firstmate types its worktree moves into the worker pane's interactive shell,
# which loads the operator's aliases. A `cd` wrapper that only inspects `$1`
# (like the operator's zoxide-backed `zd`) swallows `cd -- <path>` without
# moving, so both sites that send a directory change to a pane must send
# `builtin cd -- <path>` instead: the fresh-spawn entry in
# `spawn_enter_recorded_worktree` and the herdr relaunch return path.
# Both cases run the real bin/fm-spawn.sh against a fake backend and assert on
# the text the pane actually received - never on the script's source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-cd-alias)

# make_cd_case <name> <id> builds a home, a project with a real worktree, a
# brief, and the standard spawn fakebin (fake tmux + no-op treehouse + no-op
# sleep). Echoes "case|home|proj|wt|fakebin".
make_cd_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id" "Exercise pane-shell directory changes for $id."
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_cd_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_cd_spawn() {
  local id=$1 pane_log=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" \
    CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_LOG="$pane_log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# The fresh spawn must move the pane with `builtin cd`, so an aliased `cd`
# cannot swallow the move. Reverting spawn_enter_recorded_worktree to a bare
# `cd --` changes the text the pane receives and fails this test.
test_fresh_spawn_enters_worktree_with_builtin_cd() {
  local rec id out status pane_log
  id=cd-spawn-z1
  rec=$(make_cd_case cd-spawn "$id")
  read_cd_record "$rec"
  mkdir -p "$HOME_DIR/user-home"
  pane_log="$CASE_DIR/pane.log"
  : > "$pane_log"

  out=$(run_cd_spawn "$id" "$pane_log")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  grep -E -q -- '^builtin cd -- ' "$pane_log" \
    || fail "the pane never received a 'builtin cd -- ' line"$'\n'"--- pane log ---"$'\n'"$(cat "$pane_log")"
  assert_grep "builtin cd -- '$WT_DIR'" "$pane_log" \
    "the pane's directory change did not carry the recorded worktree"
  if grep -E -q -- '^cd -- ' "$pane_log"; then
    fail "the pane received a bare 'cd -- ' line an aliased cd would swallow"$'\n'"--- pane log ---"$'\n'"$(cat "$pane_log")"
  fi
  pass "a fresh spawn moves the pane shell with 'builtin cd -- <worktree>'"
}

# make_herdr_cd_fakebin <dir> builds a fakebin whose `herdr` stub models one
# agent-free pane: `pane get` reports the primary checkout as the foreground
# cwd until a `pane run` carrying a directory change is observed, then reports
# the worktree. Every `pane run` payload is appended to FM_HERDR_RUN_LOG, one
# per line, in send order. All other calls succeed silently.
make_herdr_cd_fakebin() {
  local fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "${FM_HERDR_LOG:-/dev/null}"
case "${1:-}" in
  status)
    printf '{"client":{"version":"0.9.9","protocol":99},"server":{"running":true}}\n'
    exit 0
    ;;
  pane)
    case "${2:-}" in
      get)
        if [ -e "${FM_FAKE_HERDR_MOVED_MARKER:-/dev/null}" ]; then
          cwd="${FM_FAKE_HERDR_WT:-}"
        else
          cwd="${FM_FAKE_HERDR_PRIMARY:-}"
        fi
        printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' \
          "${FM_FAKE_HERDR_PANE:-}" "$cwd"
        exit 0
        ;;
      run)
        printf '%s\n' "${4:-}" >> "${FM_HERDR_RUN_LOG:-/dev/null}"
        case "${4:-}" in
          *'cd -- '*) : > "${FM_FAKE_HERDR_MOVED_MARKER:-/dev/null}" ;;
        esac
        exit 0
        ;;
    esac
    exit 0
    ;;
  agent)
    printf '{"error":{"code":"agent_not_found"}}\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

# The herdr relaunch return path must re-home a drifted pane with
# `builtin cd`, for the same aliased-shell reason. The pane starts in the
# project primary (the Herdr-restore shape from the incident) and the recorded
# worktree is reused as-is. Reverting the relaunch site to a bare `cd --`
# changes the `pane run` payload and fails this test.
test_herdr_relaunch_returns_with_builtin_cd() {
  local case_dir home proj wt fakebin id out status run_log
  id=cd-relaunch-z2
  case_dir="$TMP_ROOT/cd-relaunch"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_herdr_cd_fakebin "$case_dir")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-cd-relaunch"
  fm_test_spawn_brief "$home" "$id" "Exercise herdr relaunch re-homing for $id."
  fm_write_meta "$home/state/$id.meta" \
    "window=testses:testpane" \
    "endpoint_task_id=$id" \
    "backend=herdr" \
    "herdr_session=testses" \
    "herdr_workspace_id=testws" \
    "herdr_tab_id=testtab" \
    "herdr_pane_id=testpane" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "branch=fm/$id" \
    "spawn_gen=1"
  mkdir -p "$home/user-home"
  run_log="$case_dir/run.log"
  : > "$run_log"

  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HERDR_SOCKET_PATH -u HERDR_SESSION \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    FM_HERDR_LOG="$case_dir/herdr.log" FM_HERDR_RUN_LOG="$run_log" \
    FM_FAKE_HERDR_PANE=testpane FM_FAKE_HERDR_PRIMARY="$proj" \
    FM_FAKE_HERDR_WT="$wt" FM_FAKE_HERDR_MOVED_MARKER="$case_dir/moved" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  expect_code 0 "$status" "a drifted, agent-free herdr pane should be re-homed and relaunched"$'\n'"$out"
  grep -E -q -- '^builtin cd -- ' "$run_log" \
    || fail "the pane never received a 'builtin cd -- ' line"$'\n'"--- pane run log ---"$'\n'"$(cat "$run_log")"
  assert_grep "builtin cd -- '$wt'" "$run_log" \
    "the pane's return did not carry the recorded worktree"
  if grep -E -q -- '^cd -- ' "$run_log"; then
    fail "the pane received a bare 'cd -- ' line an aliased cd would swallow"$'\n'"--- pane run log ---"$'\n'"$(cat "$run_log")"
  fi
  pass "a herdr relaunch returns a drifted pane with 'builtin cd -- <worktree>'"
}

test_fresh_spawn_enters_worktree_with_builtin_cd
test_herdr_relaunch_returns_with_builtin_cd

echo "# all fm-spawn-cd-alias tests passed"
