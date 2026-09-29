# This fork

This repository is a fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate), adapted for one operator's fleet. Upstream is merged deliberately, with `git fetch upstream && git merge upstream/main`, when a change there is wanted; `/updatefirstmate` is not used here because it fast-forwards from `origin` and refuses a diverged tree.

The rest of `AGENTS.md` is upstream's contract and stays as upstream wrote it. This file holds what the fork adds on top, so that upstream merges touch as little as possible: keep fork changes in new files where a new file will do, keep edits to upstream files small, and record every deliberate edit in the table below.

## Conventions every worker follows here

- **Task ids come from `br`, one tracker per project.** A task that comes from a bead carries the bead id in the commit subject and in the PR title, in the form `(<id>)` at the end of the subject. The bead is the source of truth; firstmate's backlog row mirrors it.
- **Files are written in English**: code, comments, docs, commit messages, PR text. Chat with the captain follows the captain's language.
- **No assistant attribution** in commits or PRs: no `Co-Authored-By:` naming an assistant, no "Generated with", no robot emoji. The author of the work is the account that pushes it.
- **Commit and PR text is impersonal.** Frame a change as a problem any user of the tool would hit. Do not mention the session, the conversation, or who asked for the change.
- **Private material lives under `local/`**, a symlink to a private notes repository that git ignores here. Captain notes, tracker data (`.beads` links into it) and anything naming accounts, hosts or credentials go there, never into a tracked file.

## Fork changes to upstream files

| File | Change | Why |
|---|---|---|
| `AGENTS.md` | one line pointing at this file | so every worker reads the conventions above |
| `bin/fm-tasks-axi-lib.sh` | `config/backlog-backend=br` resolves the backend to `br`, picks `bin/fm-br-backlog.sh` as the runner, and answers compatibility and availability from `br` | one `br` tracker per project is the only backlog, with no tasks-axi row to drift from it |
| `bin/fm-backlog-transition-lib.sh` | `fm_tasks_axi` and the bounded `show` read run the selected runner instead of a literal `tasks-axi` | so every lifecycle read and mutation reaches the `br` adapter unchanged |
| `bin/fm-captain-hold.sh` | its `tasks_axi` wrapper runs the selected runner, and the `--kind captain` help probe is skipped under `br` | captain holds become `br defer` / `br undefer` |
| `bin/fm-tasks-axi.sh` | hands its arguments to the `br` adapter under `backlog-backend=br` | the routine backlog command must not write a tasks-axi row on a `br` home |
| `bin/fm-teardown.sh` | under `backlog-backend=br` the closing backlog line names the bead's tracker, resolved by the new read-only `bin/fm-br-backlog.sh where` verb | the line said the item closed in a tasks-axi backend while it really closed in a project's `br` tracker |
| `bin/fm-session-start.sh` | the compact backlog listing runs through the selected runner and, under `br`, needs no `data/backlog.md` | the digest shows the `br` queue instead of reporting the backlog absent |
| `docs/configuration.md` | a "Beads per project (`br`)" subsection under "Backlog backend" | documents the `br` value and `config/br-projects` |
| `docs/configuration.md` | one sentence in "Beads per project (`br`)" pointing at the `fleet-beads` skill | says where task creation under `br` is documented |
| `docs/documentation-audiences.json` | a surface entry for `.agents/skills/fleet-beads/SKILL.md` | every maintained prose surface must be classified |
| `bin/fm-spawn.sh` | `--account <name>` in the parser and batch forwarding; account selection beside the worker account pin; the account's `env KEY='VALUE'` prefix at the `CLAUDE_CONFIG_DIR` forward, which it replaces with an unset when the account sets `HOME` for Claude; the Claude and agy trust registrations run under the account; `account=<name>` in the task record and spawned line; a relaunch keeps the recorded account | a crewmate or scout can run on one of several accounts for its harness, picked per spawn from the local `config/accounts` (owned by the new `bin/fm-accounts-lib.sh`) |
| `bin/fm-bootstrap.sh` | sources `bin/fm-accounts-lib.sh` and prints `ACCOUNTS: invalid config/accounts line <n> - <reason>` for each malformed line | a broken account line is reported at session start, not first at spawn |
| `bin/fm-test-run.sh` | `fm-spawn-account.test.sh` joins the `backend-dispatch` family beside `fm-worker-account.test.sh` | the new suite runs with the spawn tests it belongs to |
| `docs/configuration.md` | a "Named worker accounts (config/accounts)" section, its row in "Find a setting", and `account` in the crew-dispatch `use[]` schema | documents the table, the harness match, `default`, and the `HOME` versus `CLAUDE_CONFIG_DIR` rule |
| `.agents/skills/quota-array-dispatch/SKILL.md` | a chosen profile's `account` reaches `fm-spawn.sh` as `--account`, and it is part of a profile's identity | the dispatch skill passes the account through |
| `.agents/skills/bootstrap-diagnostics/SKILL.md`, `.agents/skills/agent-skill-trigger-index/SKILL.md` | the `ACCOUNTS: invalid` diagnostic line | the new bootstrap line has a handling rule and a trigger |
| `docs/documentation-audiences.json` | a surface entry for `FORK.md` | the documentation audience check refuses an unclassified surface |
| `tests/fm-bootstrap.test.sh`, `tests/fm-control-relaunch.test.sh` | one case each: the `ACCOUNTS` diagnostic, and a relaunch keeping its recorded account | covers the bootstrap and relaunch halves of named accounts |
| `bin/fm-remote-home-provision.sh` | the code-root clone passes `--no-local` | a local clone copies the code root's object files one by one, so the auto maintenance a commit detaches there failed it whenever a repack deleted a loose object mid-copy |
| `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` | one case: provisioning succeeds against a code root whose object store a file-by-file copy cannot read | the regression for the `--no-local` clone |
| `.github/workflows/ci.yml` | both Pi installs pin `@earendil-works/pi-coding-agent@0.87.1` | Pi 0.99 changed its stock tool rendering and the Pi extension tests fail against it; an unpinned install turned every pull request red on the day it was published |

## Repository settings that differ from upstream

- **The "Require no-mistakes" workflow is disabled** (`.github/workflows/no-mistakes-required.yml`), as a GitHub repository setting rather than a file edit. That workflow fails every pull request not raised through the no-mistakes pipeline, exempting only the upstream author, while this fork ships its own changes as direct pull requests. The file stays unchanged so upstream merges stay clean.
