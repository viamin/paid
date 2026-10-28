---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

Interactive chat has a durable transcript but historically no durable conclusion
for a user turn. A browser disconnect or a process loss could therefore leave a
user message and partial tool evidence with no answer or explanation.

`ChatTurn` is the durable owner of one user-initiated model turn. It stores the
user-message checkpoint, lifecycle state, activity timestamps, failure
classification, and recovery-request audit fields. Messages created by the loop
carry the turn id, preserving partial evidence without treating it as a result.
The message-to-turn reference is introduced online with a concurrent index;
legacy transcript rows remain valid without a turn reference.

## Lifecycle and detection

New turns move from `pending` to `streaming`, then to `completed`, `failed`, or
`awaiting_confirmation`. A confirmation pause is intentional and is never a
stall. A sweep marks only `pending` or `streaming` turns stale after the
configurable inactivity window. The sweep uses a row lock and rechecks the
state, so a concurrent completion wins and only one stalled notice is created.

## Recovery safety

Stalling never fabricates an assistant response or replays a tool. The durable
notice describes the preserved transcript and links to pending confirmations.
The user can explicitly request a recovery review, recorded once under a row
lock. This is intentionally not automatic replay: ambiguous model stops and
side-effecting tool evidence require a human decision. Bounded automatic
recovery remains reserved for a later opt-in infrastructure classification with
an idempotent checkpoint contract.

## Observability

The turn row records detection time, classification, recovery count, and user
recovery request. The transcript notice records the turn id and counts of
completed tool evidence and pending confirmations, making stalled and
duplicate-prevented recovery attempts queryable without parsing prose.

## Decisions & Alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Persist a turn record rather than infer from message ordering | Infer unfinished turns from the transcript | A lifecycle row supplies concurrency control, timestamps, and audit fields without guessing at interleaved messages. |
| Require explicit recovery review in the first slice | Replay the last provider request automatically | Tool calls can have side effects and a provider stop is ambiguous; an audit record is useful without risking duplicate effects. |
