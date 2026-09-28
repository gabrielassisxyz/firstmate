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
