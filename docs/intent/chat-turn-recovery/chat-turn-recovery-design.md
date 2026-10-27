---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the durable lifecycle of an interactive chat turn: how a turn
> that never reached a terminal outcome is detected, how that state is
> explained in the transcript, and how it is recovered without replaying
> side-effecting work (#4680).

## Purpose

A chat turn can end with a persisted user message and partial tool activity
but no terminal assistant response, error, or actionable recovery state. The
browser controller tracks transient streaming state and mid-turn disconnects,
and chat messages persist tool status/confirmation metadata, but nothing on the
server concludes that a turn has stalled. The user is left unsure whether to
wait, retry, or repeat a request that may already have had side effects.

That is a "no silent stops" violation: the HLD tenet requires the system to
surface *that* it stopped, *why* it stopped, and *what clears it*. A stalled
turn legible only in the database is a defect, not a quiet success.

This design adds a durable turn record, a server-side detector, an in-transcript
notice, and a bounded recovery path. It deliberately does **not** fabricate a
completed assistant response, does **not** automatically replay arbitrary tool
calls, and does **not** require full Temporal-backed chat orchestration.

## The durable turn

`chat_turns` is the unit of record. One turn is opened per user message and
spans everything that follows it — tool calls, a confirmation pause, the
assistant's answer — until it reaches a terminal state.

| Column | Meaning |
| --- | --- |
| `chat_session_id` | The conversation the turn belongs to. |
| `user_message_id` | The user message that opened the turn. Unique per session, so a turn is one user message's worth of work. |
| `status` | `pending`, `streaming`, `completed`, `failed`, `stalled`, `abandoned`. |
| `failure_classification` | Why the turn stopped, when it stopped abnormally. |
| `recovery_state` | `none`, `in_progress`, `succeeded`, `failed`. |
| `recovery_attempts` | How many recovery attempts have been claimed. |
| `revision` | Bumped on every write; a resume request carries the revision it saw. |
| `started_at`, `last_activity_at`, `finished_at`, `stalled_at`, `abandoned_at` | Timing. |
| `metadata` | Turn-scoped facts: completed tool names, side-effecting completion, awaiting-confirmation flag, stream id. |

A turn is `pending` when it is open but has not yet produced durable output
(or is waiting on the user), `streaming` once it has produced durable output,
and terminal in `completed` (terminal assistant message), `failed` (classified
error), `stalled` (detected without a terminal outcome), or `abandoned` (the
turn will not be resumed).

`chat_turn_events` is the append-only audit trail: one row per stall
classification, recovery attempt, recovery outcome, user action, duplicate
prevention, and abandonment. It carries the event type, outcome, acting user,
whether side-effecting tools had completed, and free-form metadata, so stall
rate, recovery success, abandoned-turn rate, and duplicate-prevention counts
are queryable without log scraping.

### Why a turn record rather than transcript inference

The transcript alone cannot distinguish "the model is still thinking" from "the
process died". Both look like a user message with nothing after it. A turn
record carries the *intent* of the process (open, working, stopped) alongside
the evidence, so a turn that was never closed is detectable without guessing
from message shapes. It also gives recovery a handle to claim, so two recovery
requests cannot both proceed.

## Opening and closing a turn

`ChatSessions::Turns::Open` is called by `ChatSessions::SendMessage` before
the agent loop runs and by `ChatSessions::ResolveToolCall` when a confirmation
is resolved. It reuses an existing turn when the user message already has one
(a restarted job, a recovery, a confirmation continuation) so a turn is never
split in two by a restart.

Durable activity is recorded through the existing `on_message_persisted`
callback: every message the loop writes advances the turn to `streaming` and
stamps `last_activity_at`. The turn closes as `completed` only when a terminal
assistant message exists; a turn that ends in a classified error closes as
`failed` with its classification. A turn that pauses for a write-tool
confirmation stays open — the confirmation is part of the turn, not the end of
it — and the resolve path reopens the same turn.

## Detection

`ChatSessions::DetectStalledTurns` (run by `ChatSessions::DetectStalledTurnsJob`
on a five-minute cron) selects open turns whose `last_activity_at` is older
than the configured threshold and classifies each one. The threshold is
per-tenant (`chat_stall_timeout_seconds`, default five minutes) so a slow
workspace can widen it without turning off detection everywhere.

A candidate is **not** a stall when any of these hold:

- **Awaiting confirmation.** A pending write-tool confirmation means the turn
  is waiting for a human, not stuck. The turn keeps its `pending` status; if
  the confirmation is never resolved it becomes `abandoned` after the
  abandonment window, which is a different (and truthful) outcome.
- **Provider rate limit.** The session is paused by
  `ChatSessions::MarkRateLimited`, and the existing rate-limit resume path
  owns the retry. The turn is closed as `failed` with a `rate_limited`
  classification rather than being reported as a stall.
- **Budget exhaustion.** A token-limit rejection is a terminal, explained
  outcome (`ChatSessions::CheckTokenLimit` persists a notice); it is not a
  stall.
- **Long-running operation.** A tool call declared long-running
  (`Tools::Registry.long_running?`) that has not produced a result yet may
  legitimately still be running.

Everything else is a stall. The classification records what is known:
`provider_timeout` and `infrastructure_error` are classified infrastructure
failures; `client_disconnect` and `model_stop` are ambiguous (the work may
have had side effects before the interruption); `unknown` is the fallback.

A stalled turn is never rewritten as successful. It keeps its partial
transcript, gains an `abandoned`/`stalled` terminal status, and gains an
in-transcript notice.

## The in-transcript notice

`ChatSessions::Turns::StallNotice` persists a system `ChatMessage` carrying
metadata (`stalled_turn`, `chat_turn_id`, `turn_revision`, the classification,
the completed tool names, whether side-effecting tools completed, and the ids
of any pending confirmations). `ChatMessage#stalled_turn_notice?` marks it as a
transcript notice, and `app/views/chat_messages/_stalled_turn_notice.html.erb`
renders it as a persistent, non-collapsed card — the same treatment as the
token-limit and provider-error notices, because a stalled turn is exactly the
kind of state a collapsed "system prompt" bubble would hide.

The notice states what completed (the tool calls that produced results), what
remains unknown (whether the interrupted step had side effects), why the turn
needs attention, and offers the recovery action. Links point at the pending
confirmation cards so the user can act on the tool that is waiting.

## Recovery

`ChatSessions::Turns::Recover` decides whether a recovery may proceed and
enqueues `ChatSessions::RecoverStalledTurnJob`. It claims the turn under a row
lock so that concurrent or repeated requests are deduplicated: a second
request sees `recovery_state = "in_progress"` (or a turn that is no longer
stalled) and is recorded as a duplicate-prevention event instead of starting a
second attempt. The resume request also carries the turn revision it was
rendered against; a stale revision is rejected, so an old notice in a stale
browser tab cannot resume a turn that has already moved on.

### The replay-safety contract

Automatic recovery is opt-in *per failure classification*, not a blanket retry
policy. A recovery may run automatically only when all of the following hold:

1. The failure classification is an infrastructure classification
   (`provider_timeout`, `infrastructure_error`).
2. No side-effecting (write) tool call completed during the turn.
3. Every tool that did run is declared replay-safe
   (`Tools::Registry.replay_safe?`); tools default to *not* replay-safe, so a
   new tool opts in deliberately.
4. The tenant's automatic-recovery toggle is on and the attempt budget is not
   exhausted.

Otherwise the recovery requires an explicit user confirmation: the notice
offers a distinct "resume and repeat actions" action, and the server refuses
an unconfirmed request for a turn it cannot recover automatically. The
confirmation requirement is enforced server-side, not by the button the user
happens to click.

### Resuming from the last durable checkpoint

Recovery does not replay the turn. It reuses the persisted user message and
the transcript that already exists, so the model continues from the last
durable checkpoint: tool calls that already produced results are part of the
rebuilt conversation and are not dispatched again. On top of that, the
recovery run disables the session's auto-approve toggle for the resumed turn,
so any write tool the model asks for again — including one that ran before the
stall — requires an explicit human approval instead of being replayed
automatically.

## Decisions & Alternatives

| Decision | Rationale | Alternatives considered |
| --- | --- | --- |
| Durable `chat_turns` row instead of inferring stalls from the transcript | The transcript cannot distinguish "still working" from "process died"; the turn record also gives recovery a claimable handle for deduplication. | Inferring from message shapes (rejected: ambiguous and racy); full Temporal-backed chat orchestration (deferred: a much larger change than this slice needs). |
| Turn spans the confirmation pause | A confirmation is part of the user's turn, not the end of it; splitting there would make the continuation look like a turn with no user message. | Closing the turn at the pause and opening a continuation turn (rejected: the continuation has no user message of its own and the transcript boundary becomes ambiguous). |
| Automatic recovery limited to infrastructure classifications with a replay-safe tool contract | A blanket retry would repeat side effects. Opting in per classification keeps the automatic path narrow and auditable. | Retry every stalled turn (rejected: repeats side effects); never retry automatically (rejected: gives up on the common transient case). |
| Recovery disables auto-approve for the resumed turn | Guarantees that a write tool the model requests again cannot be replayed without a human click. | Rely on the model's judgment not to repeat the call (rejected: not a guarantee). |
| In-transcript notice instead of an inbox notification | The user is looking at the transcript when the turn stalls; the notice must be visible there. The existing notification severity taxonomy governs the operator inbox, which this slice does not populate. | Operator inbox notification only (rejected: the stalled turn would be invisible to the person who was chatting); a chat notification record (deferred: a later slice may raise one with a severity). |

## What this is not

- **Not a fabricated answer.** No assistant message is written for a stalled
  turn. The transcript keeps exactly the evidence that exists.
- **Not an automatic replay of tool calls.** Write tools that already ran are
  not dispatched again by recovery, and a resumed turn re-requests them only
  behind an explicit approval.
- **Not a replacement for the rate-limit resume path.** A rate-limited turn is
  closed as `failed` with a `rate_limited` classification; the existing
  `ChatSessions::AutoResumeRateLimitedSweepJob` owns the retry.
- **Not Temporal-backed chat orchestration.** The turn record is durable and
  queryable on its own; a future slice may move the loop itself under
  Temporal without changing the lifecycle vocabulary used here.
