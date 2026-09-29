---
name: fleet-beads
description: >-
  Agent-only procedure for turning a request into work on a `br` tracker.
  Load when a request becomes work in a project whose checkout has a `.beads` tracker, and before creating, checking, or wiring a bead for dispatch while `config/backlog-backend` is `br`.
  Owns how a bead is written in the project's checkout, the two checks it passes before dispatch, how a bead id maps to its project, and which `br` verbs the backlog adapter already runs so nobody runs them by hand.
user-invocable: false
metadata:
  internal: true
---

# fleet-beads

With `config/backlog-backend` set to `br`, the backlog is the `br` tracker of each project, and there is no firstmate row to write.
Adding a task therefore means `br create` in the project's checkout, never `tasks-axi add` and never `bin/fm-tasks-axi.sh add`.
[`bin/fm-br-backlog.sh`](../../../bin/fm-br-backlog.sh) owns what happens to the bead after it exists; this skill owns how it comes to exist.

The bead norm is the `writing-beads` skill in the llm-workflow repository (`skills/writing-beads/SKILL.md` and its `references/anatomy.md`).
This skill restates only what creating and checking a bead needs; read that source for the rationale, the worked example, and the anti-patterns before writing the first bead of a batch.

## Which project a bead belongs to

A bead id belongs to the project whose prefix is the longest prefix of that id listed in `config/br-projects`, and the adapter runs `br` in the path that line names.
When registering a project whose checkout has a `.beads` tracker, add its `<prefix> <absolute path>` line to `config/br-projects` in the same step, or none of its beads can be dispatched.
The prefix is the tracker's `issue_prefix` (`br config get issue_prefix` in the checkout).

## Writing a bead

Write the body to a file first, then run, with the project checkout as the working directory:

```bash
br create "<imperative title>" --description-file <file> -p <n> -t task -l <labels>
```

`--description-file` takes the file verbatim, which is the only way a multi-paragraph body survives shell quoting.
Never use `-f`/`--file`: it is a bulk importer that keeps only the first paragraph under each heading and silently truncates the body.
Never use `--slug`: the id stays the `<prefix>-<hash>` that `br create` generates.

The body carries these sections, as markdown headings in the description:

| section | what it holds |
| --- | --- |
| `## Outcome` | what is true after the bead lands, one concrete paragraph |
| `## Context` | why it is needed, what was measured, what was already tried and rejected |
| `## Acceptance criteria` | checkboxes, each checkable by a command or an observation, ending with a `Done when:` line; spell the heading in full |
| `## Tests` | which kinds of test the bead owes (unit, e2e, property, fuzz, golden) and over what |
| `## Blast radius` | an `**Edits:**` line listing the paths the work writes, an optional `**Reads only:**` line, and a sentence on where the work stops |
| `## Recovery path` | only when the bead migrates, deploys, or rewrites state: what undoes it |

A `task`, `bug`, or `feature` carries all four labels, passed comma-separated to `-l`:

| label | meaning |
| --- | --- |
| `size:S` | up to 2 edited code files, one module |
| `size:M` | 3 to 5 edited code files, one module, new tests |
| `size:L` | more than two modules, or 6 or more edited files of one kind, or a schema change |
| `size:XL` | should have been split; the gate says so |
| `difficulty:mechanical` | approach fully decided; a script could do it; any lane |
| `difficulty:reasoning` | new logic, design choices, tests to design; the default lane |
| `difficulty:critical` | a wrong result is silent or expensive: money, data migration, attribution, security |
| `verify:local` | the test plan names existing files and the fixture carrying the format exists |
| `verify:gate` | the radius touches a surface only the full gate proves |
| `verify:external` | no capture of the contract exists on the machine |
| `spec:closed` | every criterion fixes the number or representation it asks for |
| `spec:open` | some criterion leaves a number or representation open |

The `size:` file counts are of the `**Edits:**` list.
A `question`, `epic`, `chore`, or `docs` bead carries none of the four.

## Decisions and dependencies

A bead that needs a decision the captain has to take becomes a `question` bead assigned to the captain's `br` user with `--assignee`, carrying `## Options` and `## What decides it` sections.
Use `--assignee`, never `--owner`: only the assignee keeps the bead out of `br ready --unassigned`.

A bead blocked on other work gets an edge, never a sentence in its body:

```bash
br dep add <bead> <depends-on>   # <bead> waits for <depends-on>
br dep cycles                    # must print no cycle
```

Put the edge on the leaf bead that needs the other work, not on an epic, because an epic with a `blocks` edge hides every one of its children.

## Before dispatch

Both checks run in the project checkout and both must pass before the bead is dispatched:

- `br lint <id>` checks the sections the bead's type requires.
- `bead-gate.py <id>` from the `writing-beads` skill's `scripts/` directory scores the body; it passes at 700 of 1000.

A bead that fails either is rewritten with `br update <id> --description-file <file>` and checked again, not dispatched.

## Who runs which verb

While `config/backlog-backend` is `br`, the adapter owns these verbs: `show`, `list`, `ready`, `start`, `done`, `reopen`, `update`, `hold`, and `unhold`.
Firstmate's lifecycle scripts run them through the backlog runner, so the captain runs none of them by hand, neither as `bin/fm-tasks-axi.sh <verb>` nor as the `br` mutation behind it (a claim, a close, a reopen, a defer or undefer, a `notes` rewrite); a hand-run one races the lifecycle that owns it.

The `br` verbs the captain does run are `br ready`, `br show`, `br list`, `br dep add`, `br dep cycles`, `br create`, and `br comment`, plus the two checks above.
The first three only read the tracker, and the rest create beads or add to them without moving one through the lifecycle.
