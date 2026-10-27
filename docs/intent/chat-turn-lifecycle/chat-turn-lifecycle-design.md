---
parent: PAID
prefix: CHAT-TURN-LIFECYCLE
---

# Low-Level Design: Chat Turn Lifecycle

> Companion to the high-level design (`docs/high-level-design.md`). This segment
> covers the durable lifecycle of an interactive chat turn: how a turn that
> never reached a terminal conclusion is detected, explained to the user, and
> recovered without silently dropping work or repeating side effects.

## Purpose

A chat turn can end with a persisted user message and partial tool activity
but no terminal assistant response, no error, and no actionable recovery
state. The browser controller tracks transient streaming state and mid-turn
disconnects, and `ChatMessage` persists tool status and pending confirmation
metadata, but nothing durable concludes that the turn stopped.

That violates the HLD's "no silent stops" tenet: a user staring at a frozen
transcript cannot tell whether to wait, retry, or repeat a request that may
already have mutated something.

This segment introduces a durable turn record with an explicit lifecycle, a
server-side detector that classifies a stalled turn from durable evidence, an
in-transcript notice that explains what completed and what remains unknown, and
a bounded, deduplicated recovery path that resumes from the last durable
checkpoint instead of replaying the whole turn.

## Turn lifecycle

`chat_turns` is the durable record for one user-initiated turn.

| Status | Meaning | Terminal |
| --- | --- | --- |
| `pending` | The turn exists; the user message is persisted but the loop has not produced anything yet. | No |
| `streaming` | The agent loop is running (LLM call or tool dispatch in flight). | No |
| `awaiting_confirmation` | The loop paused on a write-tool confirmation that needs a human decision. | No |
| `completed` | A terminal assistant message was persisted. | Yes |
| `failed` | The turn ended in a classified error (provider, budget, transport). | Yes |
| `stalled` | The turn was detected as stalled: durable activity stopped with no terminal outcome. | No (recoverable) |
| `abandoned` | The user explicitly declined recovery, or the recovery budget was exhausted without a successful resume. | Yes |

`ChatTurn` records `last_activity_at` (advanced by every durable artifact the
turn produces), `classification` (why a turn stalled), `recovery_state`,
`recovery_attempts`, `side_effecting_tools_completed`, and
`checkpoint_message_id` (the last durable artifact the turn produced).

`chat_messages.chat_turn_id` links every transcript row to its turn, so the
transcript, the notice, and the audit trail all agree on which artifacts
belong to which turn.

## Detection

`ChatTurns::DetectStalls` sweeps turns that are `pending` or `streaming` and
whose `last_activity_at` is older than the configured stall threshold
(`TenantSetting#chat_turn_stall_threshold_seconds`, default 15 minutes). A
turn is a candidate only when it has no durable activity beyond the
threshold.

Classification is evidence-based, evaluated in order:

1. `pending_confirmation` — a write-tool confirmation is awaiting a human.
   Legitimate state, never a stall.
2. `long_running_operation` — the turn is inside a bounded operation that is
   known to be slow (a container-backed tool dispatch). Legitimate state until
   the operation's own bound elapses.
3. `budget_exhausted` — the turn was stopped by the chat token budget. The
   durable token-limit notice already explains it.
4. `provider_rate_limited` — the runner hit a provider rate limit. The
   rate-limit pause path already explains it and owns the auto-resume.
5. `client_disconnect` — the browser disconnected after the last durable
   artifact and the server produced nothing since. The user may already have
   retried by hand, so recovery is offered but never automatic.
6. `model_stop` — the model produced assistant content but the turn never
   reached a terminal conclusion. The stop is ambiguous, so recovery requires
   explicit confirmation.
7. `infrastructure_failure` — a dispatched tool call never produced a result,
   or nothing beyond the user message was persisted. The turn failed for
   infrastructure reasons and, subject to the replay-safety contract, may be
   recovered automatically.

A stalled turn is never represented as successful: the assistant response is
not fabricated, the transcript is preserved, and the turn stays `stalled`
until a recovery succeeds (`completed`), fails again, or is abandoned.

## Transcript notice

`ChatTurns::StallNotice` persists a system message with
`metadata["stall_notice"] = true`. The notice states what completed, what
remains unknown, why the turn needs attention, and offers the recovery
action. It links the pending tool confirmations (when any) so the user can
resolve them from the same place. `ChatMessage#transcript_notice?` includes
the stall notice so it renders as a persistent, non-collapsed notice rather
than a collapsible system-prompt bubble.

## Recovery

Recovery is bounded and deduplicated.

- **Automatic recovery** is opt-in per failure classification, not a blanket
  retry policy. `TenantSetting#chat_turn_auto_recovery_classifications`
  defaults to `["infrastructure_failure"]`.
- **Replay safety** is a contract, not a heuristic
  (`ChatTurns::ReplaySafety`). A turn may be replayed automatically only when
  no side-effecting tool completed inside it, every tool it dispatched is
  replay-safe (`Tools::Registry.replay_safe?`), and no confirmation is
  pending. Write tools are not replay-safe until they declare an idempotency
  contract, so a partially applied write can never be repeated silently.
- **Resume, not replay.** Recovery re-enters the agent loop over the
  persisted transcript. Tool calls that already produced a result are part of
  the conversation history, so the model continues from the last durable
  checkpoint instead of re-running them.
- **Explicit confirmation** is required for ambiguous model stops, for
  client disconnects, and for any turn where a side-effecting tool already
  ran.
- **Deduplication.** A recovery request is claimed with a compare-and-swap on
  `recovery_state`; a second concurrent or repeated request loses the race and
  is recorded as a duplicate-prevention event instead of starting a second
  recovery. The attempt count is bounded by `ChatTurn::MAX_RECOVERY_ATTEMPTS`.
- **Revision and authorization awareness.** A recovery request names the turn
  it applies to; a request for a turn that already reached a terminal status
  is rejected as stale, and the actor must be allowed to see the session.

## Observability

`chat_turn_events` is the append-only audit trail. It records the stall
classification and detection time, every recovery attempt, its outcome, the
user action, and whether side-effecting tools had completed. Duplicate
prevention, stall rate, recovery success rate, and abandoned-turn rate are
all queryable from this table.

## What this is not

- **Not a fabricated response.** A stalled turn never gains an assistant
  message it did not produce.
- **Not an arbitrary tool replay.** Write tools are excluded from automatic
  replay until they declare idempotency.
- **Not Temporal-backed chat orchestration.** Full workflow orchestration for
  chat turns remains a later option; this segment is a durable-state first
  slice that does not require it.
