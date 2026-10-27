---
parent: PAID
prefix: CHAT-TURN-STALL
---

# Low-Level Design: Chat Turn Stall Detection and Recovery

> Companion to the high-level design (`docs/high-level-design.md`). This segment
> covers the durable turn lifecycle for interactive chat, server-side detection
> of turns that stopped without a terminal outcome, the in-transcript notice
> that tells the user what happened, and the bounded recovery paths that let
> the user (or the platform, for one narrow failure class) continue the work
> without replaying side effects.

## Purpose

A chat turn could end with a persisted user message and partial tool activity
but no terminal assistant response, no error, and no actionable recovery state.
The browser controller held that state only in memory
(`app/javascript/controllers/chat_controller.js` tracked `streaming` and
`disconnectedMidTurn`), and the transcript held tool status and pending
confirmation state (`app/models/chat_message.rb`) but nothing that concluded
"this turn stopped". The result violated the HLD tenet *No silent stops*: the
user could not tell whether to wait, retry, or repeat a request that may
already have had an effect.

This segment adds the missing durable conclusion. A turn is a first-class
record; a sweep classifies turns that stopped without a terminal outcome; the
transcript carries an actionable notice; and recovery resumes from the last
durable checkpoint instead of replaying the turn.

## The turn

A **turn** is the unit of work between one persisted user message and the
terminal assistant response that answers it. `chat_turns` is the durable
record:

| Column | Meaning |
| --- | --- |
| `chat_session_id` | The session the turn belongs to. |
| `user_message_id` | The user message that opened the turn. |
| `status` | `pending`, `streaming`, `completed`, `failed`, `stalled`, `abandoned`. |
| `awaiting_confirmation` | The turn is paused on a write-tool confirmation. |
| `stall_classification` | Why the turn was classified as stalled (see below). |
| `failure_class` | The last failure observed on the turn, if any. |
| `recovery_attempts` | How many recovery attempts the turn has consumed. |
| `recovery_status` | `none`, `in_progress`, `succeeded`, `failed`. |
| `recovery_key` | Idempotency key of the in-flight recovery attempt. |
| `checkpoint_message_id` | The last durable message the turn produced. |
| `started_at`, `last_activity_at` | Turn start and the last durable activity. |
| `detected_at`, `stalled_at` | When the stall was detected and recorded. |
| `completed_at`, `abandoned_at` | Terminal timestamps. |
| `lock_version` | Optimistic-locking revision token for recovery requests. |

`ChatMessage` keeps its own lifecycle; the turn is a sibling record, not a
replacement. The turn answers "did this exchange reach a conclusion?", while
the messages answer "what was said?".

### Status transitions

```
                 open                first assistant/tool row
   (none) ──────────────► pending ────────────────────────────► streaming
                              │                                    │
                              │ awaiting write-tool confirmation  │
                              ▼                                    │
                     pending (awaiting_confirmation)              │
                                                                   │
   terminal ◄──────────── completed | failed | stalled | abandoned ◄┘
```

- **pending** — the user message is persisted; the loop has not produced any
  assistant or tool row yet.
- **streaming** — at least one assistant or tool row exists for the turn.
- **completed** — a terminal assistant response was persisted.
- **failed** — the loop raised; the turn has an error, not a stall.
- **stalled** — the sweep found no durable activity past the threshold and no
  terminal outcome.
- **abandoned** — a stalled turn that nobody recovered inside the
  abandonment window.

A turn is never reported as successful on the strength of partial evidence:
only a persisted terminal assistant response moves a turn to `completed`.

## Where the lifecycle is written

`ChatSessions::SendMessage` opens the turn right after it persists the user
message. The turn's `last_activity_at` advances through the
`on_message_persisted` callback that already exists on the agent loop, so
every durable row the loop writes (assistant text, tool call, tool result)
counts as activity without a second instrumentation surface. The turn reaches
`completed` when the loop returns a terminal assistant message, `failed` when
the loop raises, and it is flagged `awaiting_confirmation` when the loop
pauses for a write-tool confirmation.

`ChatSessions::ResolveToolCall` continues the session's active turn: it clears
`awaiting_confirmation` and lets the same callback bump activity. A
confirmation resolution is not a new turn — the user message that started the
exchange is still the one being answered.

`ChatChannel#unsubscribed` records a `client_disconnect` signal on the
active turn. The browser's transient `disconnectedMidTurn` flag is not durable
evidence; the channel unsubscribe is.

## Detection

`ChatSessions::Turns::DetectStalled` runs from
`ChatSessions::Turns::DetectStalledJob` (GoodJob cron, every five minutes).
It selects turns in `pending`/`streaming` whose `last_activity_at` is older
than the account's stall threshold, and excludes the turns that are legitimately
still working:

| Exclusion | Reason |
| --- | --- |
| `awaiting_confirmation` | The turn is waiting for a human to approve a write tool. |
| Session `rate_limited_until` in the future | The turn is parked on a provider quota window that clears on its own. |
| Archived or closed session | The transcript is read-only; nothing is running. |
| A known long-running tool in flight | The operation is legitimately slow, not stalled. |

Long-running operations are declared by the tool, not by the detector:
`Tools::BaseTool.long_running?` defaults to `false`, and a tool opts in when
its normal execution time exceeds the stall threshold. The detector reads the
in-flight tool name from the turn's `metadata` and skips the turn when that
tool is declared long-running.

### Classification

A stalled turn is classified from durable evidence only — never from a guess
about what the worker was doing:

| Classification | Evidence | Automatic recovery |
| --- | --- | --- |
| `infrastructure_failure` | A transient infrastructure/provider failure was recorded on the turn. | Allowed, when the account opted in. |
| `provider_timeout` | A provider timeout was recorded on the turn. | Not allowed. |
| `budget_exhausted` | The turn exhausted the session token budget. | Not allowed. |
| `client_disconnect` | The client unsubscribed while the turn was in flight. | Not allowed. |
| `model_stop` | No failure and no disconnect were recorded: the model or worker stopped ambiguously. | Not allowed. |

`model_stop` is the ambiguous case: the durable record cannot say whether the
model produced an answer that was never persisted, or whether the worker
simply vanished. Recovery in that case is a human decision.

## The notice

A stalled turn persists one system chat message with
`metadata["stalled_turn_notice"] == true`. The message is a transcript notice,
not a collapsed system prompt: the transcript renders it through
`app/views/chat_messages/_stalled_turn_notice.html.erb`, which states what
completed, what is unknown, and why the turn needs attention, and offers the
recovery actions. The partial evidence stays in the transcript — the notice
never replaces or hides the tool rows the turn produced.

The notice also carries the recovery metadata the view needs: the turn id, the
classification, the list of completed tool actions, the id of any pending
confirmation to jump to, whether recovery requires an explicit confirmation,
and the turn's `lock_version` revision token.

## Recovery

`ChatSessions::Turns::Recover` is the single entry point for both the
platform-driven and the user-driven recovery. It takes a `chat_session`, a
`chat_turn`, an `actor`, an `action` (`resume` or `retry`), and a `confirmed`
flag.

### The replay-safety contract

Automatic recovery is allowed only when all of the following hold:

1. The account's `chat_turn_auto_recovery_classifications` opt-in list
   contains the turn's classification. Automatic recovery is opt-in *per
   failure classification*, never a blanket retry policy; the default list is
   empty, so no account gets automatic recovery until it asks for it.
2. The turn has consumed fewer than `MAX_AUTOMATIC_RECOVERY_ATTEMPTS`
   attempts.
3. No side-effecting tool is in flight without a persisted result. A tool
   that was dispatched but produced no result may already have had its effect;
   replaying it is only allowed when the tool declares itself replay-safe.

The third condition is the idempotency requirement. `Tools::BaseTool.replay_safe?`
defaults to `!write_operation?`: read-only tools are safe to re-run, and write
tools must opt in explicitly before the platform may replay them. A tool that
does not declare replay-safety forces the recovery through human confirmation.

### Actions

- **resume** continues the agent loop over the persisted transcript. The
  checkpoint is the last durable message the turn produced; completed tool
  results are already in the transcript, so a resume never re-dispatches
  them. This is the default action and the one automatic recovery uses.
- **retry** discards the partial rows the stalled turn produced and re-runs
  the loop from the user message. It is only offered when the user asks for
  it, and it always requires explicit confirmation when the turn completed a
  side-effecting tool.

### Deduplication, revisions, and authorization

Concurrent or repeated recovery requests are deduplicated by a compare-and-swap
on the turn row: the recovery moves `recovery_status` from `none`/`failed` to
`in_progress` only if the row is still in the expected state. A caller that
loses the race records a `duplicate_prevented` event and is rejected instead
of running a second recovery. The client's idempotency key is stored on the
turn, so a retried request with the same key is recognised as a duplicate
rather than a new attempt.

Recovery requests carry the turn's `lock_version` revision token. A request
whose token no longer matches the turn is rejected as stale, so a click on an
out-of-date notice cannot resume a turn that has since moved on.

The actor must be allowed to act on the session: the controller authorizes the
session through `ChatSessionPolicy` before the service runs, and the service
refuses a recovery for a session the actor cannot see.

## Observability

`chat_turn_events` records the audit trail: the stall classification and
detection time, every recovery attempt with its outcome, the user action that
triggered a recovery, whether side-effecting tools had completed, and the
duplicate-prevention events. The table is indexed by turn, by event type, and
by account so stall rate, recovery success rate, abandoned-turn rate, and
duplicate-prevention counts are queryable without scanning message rows.

A stalled turn also publishes a `Notification` under the
`notification-severity` taxonomy: work has halted and nothing in the system
will clear it without the user, so the severity is `error` and the
notification is `blocking`.

## What this is not

- **Not a Temporal-backed chat orchestration.** The turn lifecycle is a
  durable record plus a sweep; full workflow orchestration remains a later
  implementation option.
- **Not a fabricated answer.** The notice never invents an assistant
  response, and a stalled turn is never reported as successful.
- **Not a blanket retry policy.** Automatic recovery requires an explicit
  per-classification opt-in and the replay-safety contract.
- **Not a change to the write-tool confirmation model.** A turn waiting on a
  confirmation is explicitly *not* a stall.

## Decisions & Alternatives

| Decision | Rationale | Alternatives considered |
| --- | --- | --- |
| A separate `chat_turns` table instead of columns on `chat_messages`. | A turn spans many messages, and the questions asked of it ("did this reach a conclusion?", "may it be replayed?") are turn-level. Columns on messages could not answer them without a scan. | Denormalized turn state on the user message row: rejected because the turn's activity and evidence are not derivable from one row. |
| A sweep over durable state instead of a heartbeat from the worker. | A heartbeat dies with the worker, which is exactly the case the segment must catch. The sweep sees the turn that nobody finished. | Worker heartbeat: rejected because a dead worker cannot report its own death. |
| Classification from durable evidence only. | The detector runs long after the worker is gone; anything it infers about intent would be a guess presented to the user as fact. | Ask an LLM to classify the transcript: rejected because the answer would be unverifiable and the taxonomy is structural, not semantic. |
| Recovery resumes the loop over the persisted transcript rather than re-sending the turn. | The persisted tool results are the checkpoint; re-sending would re-dispatch tools that already ran. | Re-run the whole turn: retained only as the explicit, confirmation-gated `retry` action. |
| Default automatic-recovery opt-in list is empty. | "Treat automatic recovery as opt-in per failure classification rather than a blanket retry policy." An account that has not opted in gets detection and a notice, not silent replays. | Default to `infrastructure_failure`: rejected because the blast radius of a mistaken replay is a repeated side effect. |
| Tool-level `replay_safe?` declaration. | Whether a tool may be replayed is a property of the tool, not of the turn that used it. | Classify tools centrally by name: rejected because it drifts as tools are added. |
| `lock_version` as the recovery revision token. | It is already maintained by Rails' optimistic locking and changes on every turn mutation, so a stale notice is detectable without a second counter. | A separate `revision` column: rejected as a duplicate of `lock_version`. |

## Open Questions & Future Decisions

- The abandonment window (how long a stalled turn stays recoverable before it
  is marked `abandoned`) is currently a constant; it is a candidate for a
  per-account setting once operators have data on recovery latency.
- Cross-session stall analytics (stall rate per account, per runner) are
  queryable from `chat_turn_events` but are not yet surfaced on a dashboard.
