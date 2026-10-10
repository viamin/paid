---
parent: PAID
prefix: MOBILE-API
---

# Low-Level Design: Mobile API

> Companion to the high-level design (`docs/high-level-design.md`,
> Architecture § native client API layer). Design segment for issue #4237;
> implementation lands in issues #4238–#4241.

## Purpose

Paid ships an iOS companion app with native **inbox** and **chat**
experiences; every other surface stays web-only. The server side adds a
versioned mobile API (`/api/v1`) that exposes those two experiences through
thin controllers over the services the web UI already uses, authenticates
with personal access tokens (PATs) instead of browser sessions, and treats
one OpenAPI document as the contract source of truth shared by the server,
the CI contract checks, and the independently developed iOS client (separate
repo; client codegen via `swift-openapi-generator` plus a hand-written SSE
consumer).

This segment owns the *mobile surface*: the auth boundary, the endpoint
contracts, the error envelope, and the polling posture. It deliberately owns
no new inbox or chat behavior — that behavior belongs to the ancestor
segments and is reused, not reimplemented.

## Scope Boundary

### In scope

- PAT model, hashing at rest, revocation, `last_used_at`, per-token rate
  limits, and bearer resolution for the `/api/v1` namespace (including SSE
  requests)
- Inbox endpoints: entries list (kind/sort/project filters), count, entry
  detail, open-chat; the polymorphic entry envelope; `ETag`/`If-None-Match` →
  `304` for cheap polling
- Chat endpoints: sessions CRUD + archive/unarchive/reopen; messages cursor
  pagination; send (JSON + SSE via `Accept`); tool-call resolve
  (approve/deny)
- Error taxonomy for the API namespace (unified error envelope, status
  mapping)
- Rate limiting and abuse posture for polling clients
- `docs/api/openapi.yaml` as the contract source of truth, `committee`
  validation, Pact provider verification from the same schema, and
  Schemathesis fuzzing in CI

### Non-goals

- **No notification surface.** The mobile inbox surfaces inbox entries only;
  there is no bell, no notification list, no notification-rule state through
  `/api/v1`. Notifications remain a web surface (see
  `docs/intent/notification-severity/`).
- **No push.** No APNs, no web-push, no background delivery. Refresh is
  client-driven polling made cheap by `ETag`/`304`.
- **No web-dashboard parity.** `/api/v1` exposes only what the native inbox
  and chat experiences render. Agent-run management, project configuration,
  dashboards, and every other web surface are out of scope and may be added
  in later versions only through a deliberate schema addition.
- **No change to web JSON shapes.** Today's ad-hoc `{ error: ... }` bodies on
  web endpoints stay as they are; the unified error envelope is a property of
  the `/api/v1` namespace only.
- **No workspace/container chat on mobile v1.** Mobile chat sessions are
  inline-only (`container_capability: "none"`). Container capability
  requests, clone manifests, and workspace recovery remain web surfaces
  (RDR-037 segments).

## Existing Foundations (reuse, not reimplementation)

| Capability | Reused component | Owner segment |
|---|---|---|
| Inbox entries | `Inbox::Queue` (typed entries, `kind`/`sort`/`project` filters, authorized visibility) | `inbox-foundation`, `operator-inbox` |
| Inbox count | `Inbox::Count` (indexed candidate queries, 90 s per-user cache keyed off `Dashboard::CacheVersion` `:inbox`) | `operator-inbox` |
| Inbox → chat | `Inbox::OpenInteractiveChat` (per-user per-entry chat resolution, `InteractiveChatAccess` gate) | `operator-inbox`, `question-exploration` |
| Chat loop | `ChatSessions::SendMessage`, `ChatSessions::ResolveToolCall`, `ChatSessions::AgentLoop` | `api-mode-chat` |
| Chat payloads | `ChatMessagesController#message_json`, `ChatSessionsController#session_json`, `assistant_response_payload` (`{ status: "paused" }`) | `api-mode-chat` |
| SSE catalog | `message_start`, `message_chunk`, `message_created`, `message_tool_call`, `message_tool_confirmation`, `message_tool_result`, `message_tool_resolved`, `message_complete`, `error` | `api-mode-chat` (CHAT-API-002/004) |
| Authorization | Pundit policies (`ChatSessionPolicy`, `ChatMessagePolicy`, `InteractiveChatAccess`) | `tenant-access-control` lineage |
| Tenant context | `TenantContext` / RLS, established per request the way `ApplicationController#with_current_attributes` does | `rails-control-plane`, `tenant-access-control` |

The mobile controllers are thin adapters: they negotiate the wire format and
delegate to these components unchanged. Where the mobile contract mirrors a
CHAT-API-* claim, the mobile spec references that claim instead of restating
it — `api-mode-chat` is the ancestor; this segment extends it, never
replaces it.

## Auth Boundary: Personal Access Tokens

### Token model

A `PersonalAccessToken` ActiveRecord model (table `personal_access_tokens`):

- `id`: UUID external identifier (repo convention: UUIDs for external-facing
  IDs, bigints internally — the token resource is external-facing).
- `user_id` / `account_id`: the bearer's subject and tenant. Lookups during
  bearer resolution run under `TenantContext.with_system_access` because
  they happen *before* a tenant context exists (the same reason Devise
  controllers do).
- `name`: required, unique per user, for the revocation UI.
- `token_digest`: SHA-256 digest of the full secret, unique index. This is
  the only persisted form of the secret.
- `scopes`: `["inbox", "chat"]` by default; the initial release ships both
  and validates scope at controller level so later narrowing does not need a
  new table.
- `last_used_at`, `revoked_at`, `expires_at` (optional expiry).
- Logidze enabled (access-control table per repo policy: "who created and
  revoked what, when" matters here; usage volume is one throttled timestamp
  write, not a hot operational table).

Issuance happens through the web settings UI (a form + "reveal once"
response). The plaintext token is `paid_pat_` + 32 bytes of
urlsafe-base64 randomness, returned exactly once in the creation response
and never stored, logged, or re-derivable. Presentation of the token
digest's plaintext is the only moment it exists server-side in clear.

### Hashing at rest

- Store `Digest::SHA256.base64digest(plaintext)`. A plain (unkeyed) digest
  is chosen over AES encryption (`GithubToken#encrypts`) because API bearer
  lookup must be deterministic and indexed — the server never needs to
  recover the plaintext after issuance, only to match it. This is the same
  posture GitHub itself uses for `ghp_…` tokens.
- Lookup: `find_by(token_digest: digest(bearer_value))` on the unique index
  — one indexed query per request, no token enumeration surface.

### Revocation, expiry, and failure posture

- `revoke!` stamps `revoked_at`; the web UI lists tokens with `last_used_at`
  and a revoke action. Revocation and expiry are the only soft states.
- A missing, malformed, unknown, revoked, or expired bearer yields `401`
  with the unified error envelope (`unauthorized`) and the same generic
  message for all four cases — the API does not disclose *why* a token
  failed, so revocation and brute force are indistinguishable to a caller.

### `last_used_at`

- Stamped on authenticated requests at most once every 5 minutes per token
  (write-skipped when the column is fresh), so a polling client does not
  turn every request into a write. The timestamp feeds the revocation UI and
  token-hygiene reporting only; it never gates authorization.

### Per-token rate limits

- Every authenticated `/api/v1` request counts against a per-token budget
  (default 600 requests / 5 minutes, configurable via tenant settings later).
  SSE requests count once at stream start, not per event. Exceeding the
  budget yields `429` with the unified envelope (`rate_limited`) and a
  `Retry-After` header.
- The limiter is keyed by token id (not IP) so one account's mobile clients
  cannot be knocked offline by a shared NAT, and revoking a token kills its
  quota pressure too.

## Bearer Resolution on the API Namespace

`Api::V1::BaseController < ActionController::API`:

- No Devise, no cookies, no CSRF — the namespace is token-authenticated
  only. Web sessions continue to work unchanged for the HTML UI.
- `before_action :authenticate_bearer!` parses `Authorization: Bearer
  paid_pat_…`, resolves the digest under system access, rejects inactive
  tokens, stamps the throttled `last_used_at`, sets `Current.user`, and
  applies `TenantContext` from the token's account — mirroring
  `ApplicationController#with_current_attributes` minus the session cookie
  path.
- **SSE requests authenticate the same way.** The iOS SSE consumer is
  hand-written (URLSession), so `Accept: text/event-stream` requests carry
  the standard `Authorization` header; the server adds no query-param or
  cookie fallback, because tokens must never appear in URLs (they leak into
  access logs and proxies).
- Pundit stays the authorization layer: the same
  `ChatSessionPolicy`/`ChatMessagePolicy`/`InteractiveChatAccess` decisions,
  with `verify_authorized`/`verify_policy_scoped` after-actions, so the
  mobile surface cannot drift from web permissions.
- `allow_browser` filtering and other `ActionController::Base` browser
  affordances do not apply; the base controller is `ActionController::API`.

## API Surface

Routes live inside the existing `namespace :api` block as `namespace :v1`,
yielding `/api/v1/...` paths and `Api::V1::*` controllers.

### Inbox endpoints

| Method & path | Delegates to | Notes |
|---|---|---|
| `GET /api/v1/inbox` | `Inbox::Queue` | Filters `kind`, `sort` (`oldest` default / `newest`), `project_id` — the same URL contract the web inbox restores (INBOX-FOUNDATION-009). Pages with `limit` (default 50, max 100) and opaque `cursor`/`next_cursor` entry ids. |
| `GET /api/v1/inbox/count` | `Inbox::Count` | Already cached 90 s per user; the badge is the cheapest poll target. |
| `GET /api/v1/inbox/entries/:entry_id` | `Inbox::FindEntry` (new, thin) | Entry detail. Stale/absent id → `404` envelope (the API analog of the web stale-member redirect). |
| `POST /api/v1/inbox/entries/:entry_id/chat` | `Inbox::OpenInteractiveChat` | Returns `{ "chat_session_id": … }`; the client routes itself natively instead of consuming a URL. |

**Polymorphic entry envelope.** Every entry carries the common fields
(`id`, `kind`, `waiting_since`, `project` `{ id, owner, repo, name }`,
`title`, `summary`, `action_url`) plus a kind-specific payload, expressed in
the schema as `oneOf` per entry kind over the full
`Inbox::Queue::KINDS` set (twelve kinds today). The kind-specific payload
mirrors what the web detail pane renders per kind (`questions` for
`clarifying_questions`, `tasks` for `plan_review`, blocker summary for
`merge_approval`, remediation guidance for `action_required`, escalation
reason/counters for `escalated_pr`, and so on). The envelope is the wire
projection of the `Inbox::Queue::Entry` struct — when a new kind registers
in the queue, the schema adds one `oneOf` branch; no controller rewrite.

**Inbox list pagination.** `GET /api/v1/inbox` returns at most `limit`
entries (50 by default, 100 at most) and supplies the last returned entry's
opaque id as `next_cursor` only when another page exists. A following request
passes that id as `cursor` to continue after it in the queue's deterministic
sort order. The list projection must not resolve data that is intentionally
lazy for a selected entry: in particular, a `manual_review` list row includes
its questions but not the GitHub comment URL. `GET /api/v1/inbox/entries/:id`
is the detail projection and may resolve that URL for its one selected entry.

**Entry detail lookup — design note (decision).** `Inbox::Queue` builds
entries in memory with string ids (`"kind:numeric_id"`), so there is no
table to `find`. Two options existed:

1. Queue re-resolution — rebuild the (kind-scoped) queue and match the id.
2. A direct entry lookup service that re-derives one lane row by its numeric
   id.

This design chooses **queue re-resolution**, wrapped in a thin
`Inbox::FindEntry` service: parse the kind prefix from the entry id, call
`Inbox::Queue.call(user:, kind:)` narrowed to that lane, and match the id.
Rationale: re-resolution *is the authorization check* — it proves the entry
is currently in the caller's authorized queue (`INBOX-FOUNDATION-006`
visibility), exactly the precedent set by the web's
`Inbox::OpenInteractiveChat#authoritative_entry`. A direct lookup service
would duplicate each lane's membership rules in a second code path and
drift from them. Kind-scoping bounds the cost to one lane instead of the
full queue. A `404` (not `410`) is returned for stale ids because the
queue has no tombstones — "no longer actionable" and "never existed" are
indistinguishable by design.

### Chat endpoints

| Method & path | Delegates to | Notes |
|---|---|---|
| `GET /api/v1/chat_sessions` | `ChatSessionsController#index` semantics (`session_scope`, `archived` filter) | Payload mirrors `session_json`. |
| `POST /api/v1/chat_sessions` | `ChatSessions::Create` | Mobile v1 requests are inline-only; `container_capability` is not an accepted input. |
| `GET /api/v1/chat_sessions/:id` | `ChatSessionsController#show` semantics | |
| `PATCH /api/v1/chat_sessions/:id` | `ChatSessionsController#update` semantics (title etc.) | |
| `DELETE /api/v1/chat_sessions/:id` | `ChatSessions::Close` | |
| `PATCH …/:id/archive`, `…/unarchive`, `…/reopen` | existing member actions | |
| `GET /api/v1/chat_sessions/:chat_session_id/messages` | `ChatMessagesController#index` query semantics | Cursor pagination below — `limit` and `next_before` are new mobile shaping, not web reuse. |
| `POST /api/v1/chat_sessions/:chat_session_id/messages` | `ChatSessions::SendMessage` | JSON default; SSE when `Accept` includes `text/event-stream` (mirror `sse_requested?`). |
| `POST …/messages/:message_id/resolve` | `ChatSessions::ResolveToolCall` | `{ "decision": "approve" \| "deny" }`; same `Accept` negotiation. |

**Message payloads mirror `message_json`** (`id`, `external_id`, `role`,
`content`, `model`, `tool_call_id`, `tool_name`, `tool_arguments`,
`tool_result`, `tool_status`, `tokens_input`, `tokens_output`,
`created_at`) and the send/resolve responses mirror
`assistant_response_payload` — a message object, or `{ "status": "paused" }`
when the turn pauses for a write-tool confirmation. The SSE streams emit the
existing CHAT-API event catalog verbatim; this segment defines no new event
names and no payload reshaping. Authorization, archived-session rejection,
content limits, and rate-limit handling match `ChatMessagesController`'s
current behavior (`CHAT-API-002`/`004` remain the normative claims).

**Cursor pagination.** The cursor *semantics* reuse the web index: `before`
(exclusive message-id cursor), queried newest-first and returned
oldest-first, with no offset pagination — the transcript is append-mostly
and keyset pagination stays correct as new messages land. Two pieces are
**new response shaping** for `Api::V1::ChatMessagesController#index`, not
ports of web behavior: a configurable `limit` (default 50, max 100 — the
web index hardcodes `.limit(50)` and accepts no limit parameter) and a
`next_before` field when more pages remain (the web index returns a bare
JSON array with no cursor metadata; the HTML surface paginates Turbo
frames with a boolean `has_more` — `older_messages` on message id,
`sidebar_page` on `before_updated_at`/`before_id` — not a cursor field).
The implementation issues add this envelope to the mobile controller; the
web endpoints stay unchanged.

## Error Taxonomy

One envelope for every `/api/v1` response that is not a success:

```json
{ "error": { "code": "not_found", "message": "Entry is not in the inbox.", "details": {} } }
```

`details` is optional and machine-readable per code. Status mapping:

| Status | Code | Meaning |
|---|---|---|
| 400 | `invalid_request` | Malformed parameters the router/parsers reject. |
| 401 | `unauthorized` | Missing/invalid/revoked/expired bearer — one generic message, no reason disclosure. |
| 403 | `forbidden` | Pundit denial. |
| 404 | `not_found` | Unknown or stale resource id (incl. stale inbox entries). |
| 409 | `conflict` | State-transition races (e.g., resolving an already-resolved tool call). |
| 422 | `validation_failed` | Semantically invalid input (mirrors the web chat controllers' `422` token-limit shape, re-enveloped). |
| 429 | `rate_limited` | Per-token budget exceeded; `Retry-After` header set. |
| 500 | `internal_error` | Generic; never leaks internals. |
| 502 | `provider_error` | Upstream LLM provider failure (`AgentHarness::Error` paths). |
| 503 | `provider_unavailable` | Runner/client misconfiguration (`LlmClientConfigurationError`, `NotImplementedError` paths). |

SSE streams keep the in-stream `error` *event* per CHAT-API (a stream's
HTTP status is already committed by the time a mid-stream failure occurs);
the envelope above governs non-streaming responses. Web endpoints are not
migrated — their ad-hoc `{ error: "…" }` shapes remain web concerns.

## Polling Posture and Conditional Requests

- `GET /api/v1/inbox` and `GET /api/v1/inbox/count` emit a strong `ETag`
  computed as a SHA-256 digest of the caller's user id, the normalized
  filter parameters, and the current `Dashboard::CacheVersion` value for the
  account's `:inbox` scope — the same version integer the nav badge already
  bumps on queue-mutating events (`Issue` needs-input transitions,
  decision writes, phase changes). A request whose `If-None-Match` matches
  returns `304` with an empty body at the cost of one cache read, without
  building the queue.
- The account-scoped version plus per-user ETag inputs keep conditional
  responses correct across users with different visibility: two users may
  hold the same cache version, but their ETags differ because their user ids
  are digest inputs; a visibility change implies a queue-mutating event in
  practice, and worst case the next version bump (≤ badge TTL window)
  refreshes the tag.
- Responses carry `Cache-Control: private, max-age=0` so intermediaries do
  not serve one user's inbox to another; `304` is a bandwidth optimization,
  not a cache layer.
- Client guidance (documented in the OpenAPI description): poll `count`
  cheaply, poll the list with `If-None-Match`, honor `Retry-After`, and
  prefer SSE over re-polling during an active chat turn.

## OpenAPI as the Contract Source of Truth

- `docs/api/openapi.yaml` (OpenAPI 3.1) is the single normative description
  of `/api/v1`: paths, the polymorphic inbox envelope (`oneOf` with `kind`
  discriminators), chat payloads, the error envelope, and the versioning
  policy (additive changes within `v1`; breaking changes require a new
  path version).
- The SSE event catalog ships as a schema **extension**: an
  `x-sse-events` map on the send/resolve operations listing each event name
  with its payload schema (`message_start`, `message_chunk`,
  `message_created`, `message_tool_call`, `message_tool_confirmation`,
  `message_tool_result`, `message_tool_resolved`, `message_complete`,
  `error`), so the catalog is machine-checkable from the same file the iOS
  client generates from.
- `committee` validates requests and responses against the schema: strict
  (raise) in test, warn-and-log in development and production. Request
  specs in `spec/requests/api/v1/` run behind the middleware, so every
  endpoint's conformance is asserted on every test run.
- Pact provider verification runs in CI from the same schema file: the
  consumer contract (maintained by the iOS repo) is verified against
  provider states whose responses are validated by `committee` against
  `openapi.yaml`, so schema drift between the two mechanisms is impossible
  by construction.
- Schemathesis fuzzes the running app in CI against `openapi.yaml`:
  full property-based fuzzing on read endpoints, and request-conformance
  checks on mutation endpoints without executing real chat sends (state
  mutation fuzzing would otherwise spend provider tokens); negative-path
  coverage for mutations comes from committee validation and request specs.
- No rswag: the schema is hand-maintained YAML, not generated from specs —
  the contract leads, the implementation follows.

## Decisions

- **Thin controllers, reused services.** Every endpoint delegates to an
  existing service; the only new *service* is the thin `Inbox::FindEntry`
  wrapper (queue re-resolution, kind-scoped). New logic is not limited to
  that service: the mobile messages index adds controller-level response
  shaping the web index does not have — the configurable `limit` and
  `next_before` cursor envelope (see "Cursor pagination"). Scope the
  messages endpoint accordingly; it is wire-format negotiation, not a
  verbatim port.
- **Digest-hashed bearer tokens.** Deterministic indexed lookup, plaintext
  shown once, generic 401s — no enumeration, no recoverable secret at rest.
- **Re-resolution over direct lookup for entry detail.** Authorization is
  membership in the authorized queue; a second lookup path would drift.
- **Polling with ETag, no push.** The badge's cache version doubles as the
  ETag input, so 304s cost one cache read.
- **Schema-first, one file.** `openapi.yaml` feeds committee, Pact provider
  verification, Schemathesis, and the iOS codegen — four consumers, one
  source, no rswag generation.
- **SSE catalog reused, not forked.** Event names and payloads are
  normatively owned by `api-mode-chat` (CHAT-API-002/004); the mobile schema
  republishes them as `x-sse-events` for client codegen only.

## Testing

All surfaces below are the ones issues #4238–#4241 will add; identifiers in
[mobile-api-specs.md](mobile-api-specs.md) are reserved ahead of them.

- `spec/models/personal_access_token_spec.rb` — digest hashing, revocation,
  expiry, throttled `last_used_at`.
- `spec/requests/api/v1/*_spec.rb` — bearer resolution (incl. SSE requests),
  filters, envelopes, cursor pagination, error mapping, ETag/`304`, all
  running behind the committee middleware.
- `spec/services/inbox/find_entry_spec.rb` — kind-scoped re-resolution and
  stale-id 404s.
- `spec/services/api/v1/` rate-limit specs — per-token 429/`Retry-After`.
- CI: Pact provider verification job and Schemathesis job, both loading
  `docs/api/openapi.yaml`.
