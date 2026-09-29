---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array from one `aub status --format json` snapshot, choosing the account by
  the reserve ranking rule after three orthogonal gates.
  Load when a dispatch rule or default resolves to more than one profile candidate.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

This skill is the single owner of the completion-aware profile-array selection procedure and of the account ranking rule.
`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning/tie safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
agent-usage-book (`aub`) remains data-only: it publishes each account's windows, burn rate, reset, and freshness, and never recommends, selects, or ranks a route.
Do not add a daemon, opaque composite score, routing wrapper, hard-coded model-specific policy, or producer-side route recommendation.
The [worker helper](../../../bin/fm-quota-choose.sh) and [typed resolver](../../../docs/configuration.md#typed-dispatch-resolution-env-typesafe_api_key) own their deterministic mapping boundaries, and [`bin/fm-quota-lib.sh`](../../../bin/fm-quota-lib.sh) implements the ranking rule below in code for both.

## Worker-side quota helper

The canonical shell helper for a worker that has already performed its model-selection reasoning and now needs to pick the first viable candidate is `bin/fm-quota-choose.sh`.
Pass it the intake's already-captured snapshot through stdin or `--snapshot`; it never takes another snapshot, so it selects from the same quota state as the intake.
Pass each candidate as `harness:model`, with earlier candidates preferred; it prints the candidate and the account the ranking rule picks for it.
The helper's header owns its account lookup and selection mechanics.
It does not replace the reasoning-class, runway-feasibility, or authentication gates below.
Firstmate can optionally arm `bin/fm-procevent-quota.sh` for a recurring mid-task check that wakes when a tracked account's window drops below its configured threshold or reaches 0%.
The opt-in [typed resolver](../../../docs/configuration.md#typed-dispatch-resolution-env-typesafe_api_key) has its own documented gates.
It never removes this skill's authority, and its `ambiguous`, `escalate`, and `error` outcomes return here.

## Read the aub snapshot

Start each intake by running `aub status --format json` once, and reuse that snapshot for every candidate; it is the only quota snapshot an intake takes.
Each entry of `accounts[]` is one account: `account`, `freshness` (`fresh`, `stale`, or `auth_required`, with a `reason`), `observation_age_nanos`, `limiting_window` (`scope`, `burn_rate`, `nominal_duration_nanos`), and `windows[]` with `scope`, `quota_used_ppm`, `resets_at_nanos`, `nominal_duration_nanos`, `burn_rate`, and a `model` on model-scoped windows.
Percent used is parts per million, so remaining is `100 - quota_used_ppm / 10000`.

A candidate is a profile on one account.
Its accounts are the profile's `account` when it names one, otherwise every [`config/accounts`](../../../docs/configuration.md#named-worker-accounts-configaccounts) account of its harness, otherwise the harness's one default account from `bin/fm-quota-lib.sh`; firstmate's account names match aub's account ids one to one.
For each candidate, preserve explicit `harness`, `model`, `provider`, and `account`; `harness-adapters` owns identity, and model/provider never infer harness.
Hand the chosen candidate to `fm-spawn.sh` as `--harness`, `--model`, `--effort`, and `--account <name>` when the chosen account is a `config/accounts` name.

## Three gates, then the ranking rule

Apply the three cheap orthogonal gates first.
The ranking rule orders only candidates that pass all three.
It cannot override a hard-gate failure, and it is never hidden inside a new composite score.

### 1. Eligibility

Outside those documented mappings, deterministic shell must not infer a provider family or credential store from a harness, model, or source name.
You establish the remaining relations yourself, in the open, from the candidate's own authoritative catalog (`harness-adapters` owns the per-harness discovery surface) plus the one intake snapshot.

Confirm the catalog lists the candidate's model and record the provider family it reports.
A model the catalog does not list is concrete contradictory evidence: block that candidate and quote the catalog result.
Apply quota at the granularity the account actually reports: an `account_wide` window bounds every model on that account, and a model-scoped window is an additional bound for that model alone.
Never sum windows across accounts or read one account's windows for another.

An account is **eligible** when its `freshness` is `fresh` and the remaining percent `r` of its limiting window is above 0.
A `stale` account is eligible only when no fresh one is, and an `auth_required` account never is.
A window with `resets_at_nanos` absent and `quota_used_ppm` 0 is an untriggered window and counts as fully available.
An account the snapshot does not list is disclosed uncertainty: keep the candidate eligible, state the unknown, and prefer known viable evidence when otherwise comparable.

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`auth_required` is aub's report that the account's own credential needs a login before it can be measured; name the account and its `reason` when reporting it.

Uncertainty and ineligibility are different findings:

- No model-level window, an account the snapshot does not list, or a surface aub does not measure at all is disclosed uncertainty.
  Keep the candidate eligible, state the unknown, and prefer known viable evidence when otherwise comparable.
- An expired credential is a short-lived session token the owning vendor renews on next use, not a sign-out.
- Only concrete contradictory evidence blocks: an authoritative catalog proving the model unsupported, or proof that the credential the candidate actually selects is unusable.
- Reserve login wording for that proven-unusable case, and name the harness, model, account, and evidence.

When a credential's local classification is the only thing standing between a candidate and a block, get ground truth before blocking.
`bin/fm-vendor-auth-probe.sh` is the only approved vendor-credential probe; its `--help` owns the registered probes and mechanics.
It takes no harness, model, or provider and returns a fact, not a route: only `authenticated` and `unauthenticated` are ground truth, while `indeterminate`, `timeout`, and `unavailable` establish nothing and must never be read as either outcome.
Never launch a vendor CLI yourself, and never probe a credential store the candidate does not use.
Grok prepaid `credits` are unrelated to paid-window headroom; never read them as exhaustion.

Malformed configuration is an actionable error, not a candidate to rank around.

### 2. Reasoning-class fit

Keep only candidates that meet the required reasoning class for this task (a simple bug fix versus very-difficult design).
Never use reserve or remaining quota to silently replace that class.
When every remaining candidate is tight, dispatch inside the strongest-reasoning class if one of those candidates can proceed, or stop and report that the strongest-class choice cannot proceed rather than downgrading it to spend or conserve quota.

### 3. Runway feasibility floor

A candidate whose limiting window will run out before the inspectable likely-completion horizon fails this gate, even when it has the highest reserve.
Read it from the same limiting window: at burn multiple `b`, the window is on course to exhaust before its reset when the reserve below is negative.
A window that reaches its reset with quota left passes this generic floor; never compare its reset with the completion horizon as though reset were an exhaustion deadline.
A nearly empty window burning fast must not route into a mid-task stall.
Unknown runway stays eligible with disclosed uncertainty and is never assumed to pass.
Do not invent a generic percentage floor, and honor an explicit captain floor for a candidate when one exists.

## Rank accounts

For each eligible candidate account, take its limiting window: the entry of `windows[]` whose `scope` and `nominal_duration_nanos` match `limiting_window`.
From it read the remaining percent `r`, the fraction of the window elapsed `e` (from `resets_at_nanos` and `nominal_duration_nanos` against the snapshot's `generated_at`, held between 0 and 1), and the burn multiple `b` (`burn_rate`, 0 when absent).
The account's **reserve** is `r - b × (1 - e) × 100`; an untriggered limiting window has reserve 100.
Rank eligible accounts by reserve, highest first; among equal reserves, the higher `r`, then the fresher observation (smaller `observation_age_nanos`).
Rank `stale` accounts only when no fresh account is eligible.
Show `r`, `e`, `b`, and the reserve in the rationale; do not hide them in a score.
After ranking, escalate to Firstmate instead of routing if no candidate can be ranked, or runway uncertainty prevents proving the feasibility floor for any candidate that could be selected.
Never resolve that terminal uncertainty by treating unknown as healthy or by choosing arbitrarily.

### Worked example

A rule resolves to one profile, `claude` with model `opus`, and `config/accounts` declares two Claude accounts, `primary` and `second`.
The snapshot reports both fresh.
`primary`'s limiting window is 60% elapsed with 40% remaining at burn 1.5, so its reserve is `40 - 1.5 × 0.4 × 100 = -20`: it is on course to run dry before its reset.
`second`'s limiting window is 10% elapsed with 95% remaining at burn 0.2, so its reserve is `95 - 0.2 × 0.9 × 100 = 77`.
Both are eligible, `second` ranks first, and the spawn is `fm-spawn.sh ... --harness claude --model opus --account second`.
Had `second` been `stale`, `primary` would be the only fresh eligible account and would be chosen despite its negative reserve, unless the runway gate blocks it for this task's horizon.

Genuine ties: stop and report every tied candidate for captain choice.
Do not select by array order, harness name, or another arbitrary identity ordering.
Report duplicate concrete profiles, the same harness, model, effort, and account, as a configuration error.

Account for every candidate visibly before selecting or escalating, naming its catalog evidence, account and freshness, applicable windows and authentication facts, remaining uncertainty, fit and reasoning class, reserve, and runway-versus-horizon result.
A blocked credential report must name `harness`, `model`, account, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
Never conclude with an unexplained "best quota" label.
