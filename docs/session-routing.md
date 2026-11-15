# Routing work to the session that owns it

Written 2026-08-27 against Claude Code **2.1.248**. Claims below were checked against live
transcripts, job records and the shipped binary on one machine. Where something is inferred rather
than observed, it says so.

This documents a problem, a measurement, and a rule. **The rule is not shipped and should not be** —
see [Why the rule is not installed](#why-the-rule-is-not-installed). Read the precondition before
adopting anything here.

---

## The precondition, first

> **This is only true if your repository is effectively single-author.**
>
> The advice below tells you to ignore the PR author field. That is correct when every PR carries
> the same author, because a constant carries no information. **On a team repository the author
> field is the single best ownership signal you have, and this advice inverts.** If your PRs have
> different authors, stop reading — you do not have this problem.

## The problem

Run several Claude Code sessions at once and reviewer feedback lands on a PR that some *other*
session raised, hours ago, while still holding the whole authoring rationale in context. Getting the
review to that session beats re-deriving the reasoning anywhere else.

So: given a PR, which session owns it?

The obvious answer is the author field, and in a single-author repo it is a constant. That is not a
heuristic that fails sometimes — it is one that cannot work. Observed failure: two sessions
independently picked up the same PR off the author field; one posted a comment on a PR it did not
own, while the real owner sat idle and reachable.

The failure mode is the dangerous kind. Nothing errors. A plausible session name comes back, a
plausible action follows, and the review simply never reaches the session that had the context.

## What actually identifies the owner

Two files already on disk, which nothing joins:

| File | Gives you |
| --- | --- |
| `~/.claude/projects/*/*.jsonl` | `{"type":"pr-link", prNumber, prRepository, sessionId}` — written by Claude Code when a session links a PR |
| `~/.claude/jobs/*/state.json` | `{sessionId, name, nameSource, state, updatedAt}` — written per background session |

`pr-link` gives PR → sessionId. `state.json` gives sessionId → name. Join them and routing stops
being a name-guess.

`bin/session-route.sh` in this repo does the join.

### The catch that makes a naive join useless

**A `pr-link` record is written when a session *links* a PR, not when it raises one.** Reviewers,
monitors and the author all leave records on the same PR.

Measured on one machine, 263 PRs carrying `pr-link` records at the time of writing (the corpus grows
as you work, so your own numbers will differ — the contrast is the point, not the absolute):

| Join | Routable |
| --- | --- |
| naive (any linking session) | **0** of 70 attempted — nearly every PR resolved to several sessions |
| earliest link wins | **210** |

Time disambiguates because the raiser links first, usually by hours. Validated against a case with
known ground truth: on the PR that was mis-routed, the true owner linked at `2026-08-26T22:28Z` and
the session that wrongly commented linked 19 hours later. Earliest-wins picks the owner.

When the earliest linker has no job record, `session-route.sh` reports `NO_SESSION` rather than
falling back to a later toucher. A confident wrong session and a right one are indistinguishable at
the call site, so returning nothing is the safer failure.

## Session names are your addressing scheme

`SendMessage` addresses a session by **name**, so the name determines whether a session is reachable
at all.

**Observed:** of 134 background sessions on this machine, 130 were auto-named and 4 renamed by hand.
An auto-name is derived from the session's opening prompt:

| Opening prompt | Resulting name |
| --- | --- |
| `Lets review this .../services/pull/34007` | `services pr 34007 review` |
| `Lets re-reivew .../pull/1509 make sure my comments are addressed` | `pr 1509 review comments` |

So routing worked here largely by accident: the habit of opening a session with a PR URL or ticket
number put the identifier into the name, where a branch prefix like `ins543-` could match it. Open a
session with a vague prompt and it becomes unaddressable by ticket — alive, reachable, and
un-findable. `session-route.sh` tags those `weak-name`.

Three ways to fix it, in order of leverage:

1. **Lead the opening prompt with the identifier.** `INS-654: machine resolution union view` rather
   than `Can we look at the machine resolution union view?` Free, and upstream of everything else,
   because it is the field the auto-namer reads.
2. **`/rename` mid-session** — the retrofit for a session already running under a useless name.
3. **`--name` at launch** — only applies to sessions you start in a terminal yourself. Background
   sessions are launched by the daemon and never see a command line, so this does *not* help there.

Two sessions may share a name; Claude then needs a short identifier to disambiguate before it can
send. Distinct names are worth the small effort.

## Liveness is a separate question

`session-route.sh` resolves a *name*. It cannot tell you the session is reachable, because a shell
script cannot call `ListAgents`.

**Confirm with `ListAgents` before sending.** A session's peer visibility is scoped to the directory
it *launched* in — the key is fixed at session start and does not follow a later `cd` or a move into
a worktree. A session started under a different root is absent from your peer list while its job
record still looks perfectly healthy. Observed: authoring context for a review was unreachable for
exactly this reason and had to be escalated by hand.

## The rule that makes Claude check

**Observed:** on this machine no setting drives any of this. `crossSessionInbound` is unset in every
scope, and no hook mentions `ListAgents` or `SendMessage`. What makes Claude run the check is a
memory entry — `MEMORY.md` loads into every session, so a rule written there fires before the model
acts:

```
Before acting on a review for a PR this session did not raise, run ListAgents.
The PR author field cannot identify the owning session: every PR here has the
same author, so it carries no information. Match the ticket to the session
NAME, and prefer the branch prefix (ins543-) as the cheap signal.
```

**Inferred, not measured:** that the rule is *why* routing improved. The evidence is one failure
before the rule existed and one success after — an anecdote, not a measurement. A session's own
account of why it did something is the weakest kind of evidence, and worth discounting.

The argument that does not depend on that testimony: the check guards a silently-failing path.
Skipping it produces no error, so there is no feedback signal to teach the habit. Rules guarding
silent failures have to be written down or they do not survive a busy turn.

## Why the rule is not installed

This repository ships hooks and tools, not memories, and that is deliberate:

1. **The rule is false for most repositories.** See the precondition. Installing it on a team-repo
   machine would actively degrade routing there.
2. **There is no coherent install target.** The installer works per machine and touches no repo
   files; a memory store is keyed by a session's launch directory.
3. **It would manufacture the artifact this toolkit exists to warn about.** Memory files carry no
   author and no write date. A rule installed by a stranger reads exactly like one you established
   yourself months ago and have been relying on since. `memory-verify.sh` is read-only by contract
   for the same reason.

So: write it yourself, in your own store, where it carries your date and your intent — and where
`memory-verify.sh` can check it later.

## Related

- `bin/session-route.sh` — the PR → session lookup, and `tests/session-route.test.sh`
- [Cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging) — `ListAgents`,
  `SendMessage`, `crossSessionInbound`, and the project-root scoping rule
