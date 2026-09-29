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
| `bin/fm-session-start.sh` | the compact backlog listing runs through the selected runner and, under `br`, needs no `data/backlog.md` | the digest shows the `br` queue instead of reporting the backlog absent |
| `docs/configuration.md` | a "Beads per project (`br`)" subsection under "Backlog backend" | documents the `br` value and `config/br-projects` |
