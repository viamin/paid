---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Stall Detection and Recovery

> Companion to the high-level design (`docs/high-level-design.md`), "No
> silent stops" tenet. This segment covers issue #4680: a chat turn could
> previously end with a persisted user message and partial tool activity but
> no terminal assistant response, error, or recovery state — the browser's
> transient streaming lock and mid-turn disconnect handling
> (`app/javascript/controllers/chat_controller.js`) have no durable
> server-side counterpart, so a worker crash, a hung provider call, or a
> dropped deploy mid-turn left the user with no explanation and no safe way
> to continue.

## Scope: first slice

Per the issue's implementation note, this segment ships the first slice only:
durable turn state and server-side detection, an in-transcript notice, and a
narrowly-scoped bounded/idempotent recovery path. It does not attempt
per-tool idempotency declarations, Temporal-backed orchestration, or
automatic replay of turns that touched a write tool — those are explicitly
deferred (see "Non-goals" below and the Replay safety contract section).

## Durable turn lifecycle

`ChatTurn` (`app/models/chat_turn.rb`) is a new, durable row for the span
from one persisted user `ChatMessage` to a terminal outcome. A turn is
created the first time `ChatSessions::SendMessage` persists the triggering
user message (`ChatTurn.start!`), keyed 1:1 to that message
(`user_message_id` is uniquely indexed).

```
pending --> streaming --> completed
                       \-> failed
                       \-> stalled --(claim_recovery!)--> streaming
                                   \-> abandoned (bound exhausted)
```

- **pending** — the turn exists but the agent loop has not yet persisted
  anything (a tiny window; this is also the state a crash immediately after
  user-message persistence would leave behind).
- **streaming** — the agent loop is actively persisting messages, or is
  deliberately paused awaiting a write-tool confirmation (see "Exemptions").
- **completed** — a final assistant message was persisted.
- **failed** — a classified, already-explained error ended the turn (see
  "Failure classification"). The existing per-error-type system notices
  (`token_limit_error?`, `rate_limit_paused?`, `provider_error_notice?`)
  already explain these to the user; they are not "silent" and are out of
  this segment's detection scope.
- **stalled** — `ChatTurns::StallDetectorJob` found no durable checkpoint
  update for longer than the configured threshold while the turn was
  `pending`/`streaming`, and no exemption applied.
- **abandoned** — recovery attempts (automatic + manual, combined) reached
  `ChatTurn::MAX_RECOVERY_ATTEMPTS`; the turn stays visibly unresolved and the
  transcript stops offering Resume, directing the user to send a new message.

A turn is never represented as `completed` by anything other than a real,
persisted final assistant message — a stalled or failed turn is always
distinguishable from a successful one in the transcript and in the database.

## Checkpointing (durable, not streaming-chunk-based)

`ChatSessions::SendMessage` and `ChatSessions::ResolveToolCall` each wrap
their `on_message_persisted` callback (already threaded through
`ChatSessions::AgentLoop`/`FallbackLoop` for every persisted message — user,
assistant, tool call, tool result) to also call `ChatTurn#record_activity!`.
This bumps `last_activity_at` only on a **durable** persisted row, never on a
raw streaming chunk (`on_chunk`) — a long legitimate generation that is still
producing chunks but has not persisted anything for the full threshold *is*
flagged, matching the issue's requirement to checkpoint on durable activity.
`record_activity!` also flips `write_tool_dispatched` to `true` the first
time a message represents a write-tool call (`Tools::Registry.write_tool?`),
regardless of whether the call later pauses for confirmation or auto-approves
— this is the replay-safety signal recovery reads (see below).

This wrapping is the entire integration surface: `AgentLoop` and
`FallbackLoop` are unmodified. `ChatTurns::Resume` (used by recovery) uses the
same wrapping technique.

An at-least-once delivery retry for `ChatSessions::ProcessMessageJob` cannot
bypass this contract: when it finds a turn for the same stream/user message
that has moved beyond `pending`, `ChatSessions::SendMessage` raises
`ChatTurn::RecoveryRequiredError` instead of rerunning the agent loop. A
crash before any post-user-message activity leaves the turn `pending` and is
safe to resume; all later retries use the claimed recovery path.

## Detection

`ChatTurns::StallDetectorJob` (cron, every 5 minutes, GoodJob-concurrency-
capped to one in flight — mirrors `StaleRunDetectorJob` and the existing
`ChatSessions::IdleReaperJob`/`AutoResumeRateLimitedSweepJob`) scans
`ChatTurn.stale(before:)` — active (`pending`/`streaming`) turns whose
`last_activity_at` is older than `CHAT_TURN_STALL_THRESHOLD_SECONDS`
(default 180s). For each candidate, under a row lock (re-checked after
acquiring it, so a turn that completed between the scope query and the lock
is skipped):

### Exemptions (AC2 — not falsely marked stalled)

- **Pending confirmation** — `ChatTurn#awaiting_confirmation?` checks
  `chat_session.messages.pending_tool_confirmations.exists?`. A write tool
  awaiting a human's Approve/Deny is `AgentLoop`'s deliberate pause state
  (RDR-028), not a hang — mirrors `AgentRun.awaiting_human_clarification`'s
  exemption from `StaleRunDetectorJob`.
- **Already resolved** — re-checking `last_activity_at` under the lock
  catches a turn that completed/failed in the gap between the scope read and
  the lock.
- **Known long-running operation (extension point)** — a tool that
  legitimately runs past the default threshold can extend its turn by writing
  an ISO-8601 `expected_long_running_until` timestamp into
  `chat_turn.metadata`; the detector skips the turn until that timestamp.
  No current tool populates it, so this is an explicit durable contract for a
  future long-running tool rather than a broad timeout exemption.
- **Provider rate limits and token-budget exhaustion** already have their
  own durable, already-notified pause states
  (`chat_sessions.rate_limited_until` / `ChatSessions::AutoResumeRateLimitedSweepJob`,
  and the `budget_exhausted` failure classification) — a turn that hit either
  ends up `failed`, not `pending`/`streaming`, so it is never a stall
  candidate in the first place. This avoids two mechanisms competing to
  "recover" the same state.

### On a genuine stall

1. `ChatTurn#mark_stalled!` — transition to `stalled`, record
   `chat_turn.stall_detected_at`, write a `chat_turn.stall_detected`
   lifecycle event.
2. `attempt_automatic_recovery` — see "Recovery" below.
3. Persist an in-transcript notice (`ChatTurns::PersistStallNotice` /
   `StalledTurnNoticeMessage`) and broadcast it over the session's
   `ActionCable` stream so a connected browser sees it immediately; a
   reconnecting/reloading browser sees it because the transcript renders
   every persisted `ChatMessage`, same as every other durable notice.

## Replay safety contract and recovery

Recovery always resumes from the last durable checkpoint
(`ChatTurns::Resume` re-runs `ChatSessions::AgentLoop`/`FallbackLoop` against
the conversation already persisted for `chat_turn.user_message` — it does
not resend the user's message or replay the turn from scratch). Any tool call
and result already persisted stays in the rebuilt conversation and is not
re-dispatched; the model sees it as already done.

The residual risk recovery cannot resolve from persisted data alone is a
crash in the narrow window between dispatching a tool and persisting its
result — no row exists yet to prove either outcome. The first-slice contract
is deliberately conservative about this:

- **Automatic (unconfirmed) recovery** — `ChatTurn#eligible_for_automatic_recovery?`
  requires the explicit `metadata["recovery_classification"] ==
  "infrastructure_failure"` checkpoint as well as
  `write_tool_dispatched == false` (no write tool touched this turn at all,
  so there is nothing a replay could duplicate) and
  `recovery_attempts < ChatTurn::MAX_AUTOMATIC_RECOVERY_ATTEMPTS` (1). This is
  required infrastructure classification and replay-safety checkpoint: an
  ambiguous silent stop is never retried automatically. **No current tool
  opts in** to broader automatic replay safety, so any turn that touched a
  write tool always falls through to the manual path below. A future tool that
  wants to participate in automatic recovery for turns it touched must declare
  an explicit idempotency contract (not yet built) before that turn's
  `write_tool_dispatched` signal is relaxed.
- **Manual (confirmed) recovery** — every other stalled turn (ambiguous model
  stop, or any write tool touched) only recovers behind an explicit human
  Resume click (`ChatChannel#recover_stalled_turn`), satisfying AC5's
  "ambiguous/model-stop recovery requires confirmation."

Both paths funnel through `ChatTurn#claim_recovery!`, a compare-and-swap
(`UPDATE ... WHERE status = 'stalled'`) that flips the turn to `streaming`
and bumps `recovery_attempts` — only the caller whose `UPDATE` actually
matches wins; a concurrent second sweep tick or a concurrent manual click
loses the race and sees `rows == 0` (AC6, mirrors
`ChatSessions::ResolveToolCall#claim_resolution!`). The bound
(`ChatTurn::MAX_RECOVERY_ATTEMPTS`, shared across automatic and manual
attempts) prevents an unbounded retry loop; a recovery claim at the bound
atomically moves the turn to `abandoned` and the notice stops offering Resume.

Authorization: `ChatChannel#recover_stalled_turn` reuses
`ChatMessagePolicy#create?` (the same authority required to send a message
in the session) and scopes the lookup through `@chat_session.chat_turns`, so
a stalled turn can only be resumed by someone who could already act in that
session.

## Observability

`ChatTurnLifecycleEvent` (append-only, `readonly?` once persisted, written
through the fail-open `ChatTurns::Lifecycle.record` — mirrors
`ExecutionAuditEvents::Lifecycle`) records `chat_turn.stall_detected`,
`chat_turn.recovery_attempted`, `chat_turn.recovery_duplicate_prevented`,
`chat_turn.completed`, `chat_turn.failed`, and `chat_turn.abandoned`, each
with `chat_turn_id`, `chat_session_id`,
`actor_id` (when human-initiated), `occurred_at`, and event-specific
`metadata` (e.g. `write_tool_dispatched`, `recovery_attempts`,
`triggered_by`). Stall rate, recovery success/outcome, and duplicate-
prevention (`claim_recovery!` returning `false`) are all queryable by
`event_name` and the denormalized `chat_session_id`/`chat_turn_id`.

## Non-goals (deferred)

- Automatic replay for a turn that touched any write tool — requires a
  per-tool idempotency declaration this segment does not build.
- Temporal-backed chat orchestration — evaluated as a later option, not a
  prerequisite (per the issue).
- HTTP/SSE parity for the Resume action — only the primary `ChatChannel` path
  ships in this slice; the SSE/JSON `ChatMessagesController` paths are
  unchanged.
