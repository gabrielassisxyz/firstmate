---
name: kernl
description: >-
  Agent-only procedure for kernl, the operator's vault and task tool, reached by the `kernl` CLI against a running server.
  Load before recording a decision, before looking up an earlier decision or note, before filing or reading a kernl task or project, and before triaging a capture in the kernl inbox.
  Owns which verb answers which question, the note write-and-link procedure, and the two rules about links and timed-out writes that each cost a session.
user-invocable: false
metadata:
  internal: true
---

# kernl

kernl holds the operator's durable record: vault notes, tasks, projects, the knowledge graph, and a capture inbox.
A decision recorded there is found by asking kernl, never by grepping a repository or guessing a vault path.
Reach a note with `kernl note read`, `kernl search`, or `kernl graph search`; every verb calls the running server, which `kernl health` confirms.

`kernl <verb> --help` and `kernl robot-docs` are the sources of truth; when they disagree with the table below, they win and the table is stale.
`kernl capabilities` prints the same contract as JSON.

## Which verb answers which question

| verb | question it answers | example |
| --- | --- | --- |
| `triage` | what needs attention right now | `kernl triage --json` |
| `note` | what does this note say; write or change a note | `kernl note read "Working style.md" --json` |
| `search` | which notes are about this topic | `kernl search --json --limit 3 "working style"` |
| `plan` | alias of `search`, kept for compatibility | `kernl plan --json --limit 2 "working style"` |
| `graph` | which nodes match, and what links to what | `kernl graph search "working style" --limit 3 --json` |
| `task` | which tasks are open on the board | `kernl task list --json` |
| `project` | which projects exist | `kernl project list --json` |
| `capture` | put a quick thought into the inbox | `kernl capture "call the accountant tomorrow"` |
| `inbox` | which captures wait to be processed | `kernl inbox list --json` |
| `memory` | what the assistant remembers: claims and telos | `kernl memory topics --json` |
| `bookmark` | which links were saved | `kernl bookmark list --json` |
| `approval` | which gates wait on a human | `kernl approval list --json` |
| `session` | what a quiet agent session would be nudged with | `kernl session nudge-prompts <session-id> --json` |
| `health` | is the server up and answering | `kernl health` |
| `doctor` | are the environment, binaries, and config sound | `kernl doctor --json` |
| `capabilities` | the machine-readable CLI contract | `kernl capabilities` |
| `robot-docs` | the agent handbook, generated from metadata | `kernl robot-docs` |

Every mutating verb acts on the operator's live data.
Destructive verbs (`note delete`, `task delete`, `project delete`, `inbox reopen`, `approval resolve`, and the others `kernl robot-docs` lists) exit 2 and print a preview without `--yes`; exit 2 there means nothing happened.

## Two rules that each cost a session

### Link with the titles the server offers, and read `accepted[]` for what it is

`kernl note write <path> --json` returns `suggestions[]`, the notes the server judged relevant as link targets.
Any `[[...]]` link whose target resolves to an existing note title, path stem, or node id becomes a `links_to` edge once the server reconciles the file, whether it was offered or not; a link that resolves to nothing is kept as a dangling link until a matching note appears.
`accepted[]` and `rejected[]` only split the previous write's offer by whether the new text links each offered note, so a link to a note that was never offered appears in neither list.
Prefer offered titles, because they are the server's relevance pick and the only links `accepted[]` can confirm, and check any other link with `kernl graph edges <note-id> --resolve --json`.
The rule prevents two mistakes: reading an empty `accepted[]` as "no edge was made", and linking a guessed title that resolves to nothing, so the note reads as linked while the graph holds no edge.

### A write that times out may still have landed

On a timeout or error from `kernl note write`, run `kernl note read <path>` before writing again.
A second blind write overwrites whatever the first one saved, and the first one often did save.
The rule prevents losing a landed write, including the frontmatter id the server injected into it.

## Writing a note

1. Write the body to a local file and run `kernl note write <path> --file <local-file> --json`.
2. Read the `suggestions[]` titles; a new note also gets an `id:` injected into its frontmatter, so `kernl note read <path>` and keep that id in the next write; never copy an id from another or a deleted note, because a write carrying a deleted note's id is saved but gets no graph node.
3. Add `[[Title]]` links in the text, using offered titles only, at the sentence where the relation is stated.
4. Run the same `kernl note write` again with the linked text.
5. Confirm each offered title you linked appears in `accepted[]`; `rejected[]` lists offered notes the text did not link, which is not an error.
6. Confirm every edge, offered or not, with `kernl graph edges <note-id> --resolve --json`.

When no offered title fits, write without links and pass `--no-links-reason <text>` rather than inventing one.

## Note conventions

- A note body is markdown with YAML frontmatter.
- `author: da` marks a note the assistant wrote; any other value, or none, means a person wrote it.
- `origin` names the pipeline a note came from (`prep`, `ingest`, `capture`) and never stands in for `author`.
- A note made from a capture keeps the operator's words untouched, so it carries an `origin` and no `author`.
- Note content is written in English; a capture stays in the language it was captured in.
- A note whose `permission` is not `edit`, and that the assistant did not author, is the operator's: ask before changing it.
