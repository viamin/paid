# EARS Specs: Mobile API

> Testable claims for the `/api/v1` mobile API (native iOS inbox and chat).
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r MOBILE-API-001`).
>
> Identifiers are reserved ahead of the implementation issues #4238–#4241
> (design segment #4237); the *Tests:* and *Code:* surfaces below are the
> ones those issues will add. Where a claim's contract is unchanged from
> interactive chat, the normative spec remains the `CHAT-API-*` claim cited;
> the mobile specs below cover the mobile surface only.

## PAT authentication

- [ ] **MOBILE-API-001** — When a user creates a personal access token
  through the web settings UI, the system SHALL generate a
  `paid_pat_`-prefixed secret, return its plaintext exactly once in the
  creation response, and persist only a SHA-256 digest of the secret on a
  uniquely indexed `token_digest` column. The plaintext SHALL NOT be
  stored, logged, or recoverable after the creation response.
  *Tests:* `spec/models/personal_access_token_spec.rb`,
  `spec/requests/personal_access_tokens_spec.rb`.
  *Code:* `PersonalAccessToken`, `PersonalAccessTokensController`.

- [ ] **MOBILE-API-002** — When a request presents a bearer token that is
  missing, malformed, unknown, revoked, or expired, the system SHALL reject
  it with `401` and the unified error envelope carrying code `unauthorized`,
  with one generic message that does not disclose which failure case
  occurred.
  *Tests:* `spec/requests/api/v1/authentication_spec.rb`.
  *Code:* `Api::V1::BaseController#authenticate_bearer!`.

- [ ] **MOBILE-API-003** — When a request authenticates successfully, the
  system SHALL stamp the token's `last_used_at` at most once every five
  minutes per token, so polling traffic does not produce a write per
  request; the stamp SHALL feed the revocation UI only and SHALL NOT gate
  authorization.
  *Tests:* `spec/models/personal_access_token_spec.rb`.
  *Code:* `PersonalAccessToken#touch_last_used!` (throttled).

- [ ] **MOBILE-API-004** — When a token exceeds its per-token request
  budget, the system SHALL respond `429` with error code `rate_limited`, a
  `Retry-After` header, and SHALL count an SSE stream once at stream start
  rather than once per event. The budget SHALL be keyed by token id, not by
  IP address.
  *Tests:* `spec/requests/api/v1/rate_limit_spec.rb`.
  *Code:* `Api::V1::BaseController` rate limiting.

- [ ] **MOBILE-API-005** — When any `/api/v1` request arrives — including
  SSE requests negotiated with `Accept: text/event-stream` — the system
  SHALL authenticate it from the `Authorization: Bearer` header, establish
  `Current.user` and `TenantContext` from the token's user and account
  before dispatch, and enforce the same Pundit policies and policy scopes
  the web controllers enforce. The namespace SHALL NOT accept tokens via
  query parameters, cookies, or any non-header channel, and SHALL NOT
  require a Devise session.
  *Tests:* `spec/requests/api/v1/authentication_spec.rb`,
  `spec/requests/api/v1/chat_messages_spec.rb`.
  *Code:* `Api::V1::BaseController`.

## Inbox endpoints

- [x] **MOBILE-API-006** — When a client calls `GET /api/v1/inbox`, the
  system SHALL return inbox entries from `Inbox::Queue` for the
  authenticated user, honoring the `kind`, `sort` (`oldest` default,
  `newest`), and `project_id` filter parameters with the same URL contract
  the web inbox restores (INBOX-FOUNDATION-009). Each entry SHALL carry the
  common envelope fields (`id`, `kind`, `waiting_since`, `project`, title,
  summary, `action_url`) plus its kind-specific payload, and the OpenAPI
  schema SHALL express the entry as `oneOf` across one branch per
  `Inbox::Queue::KINDS` kind.
  *Tests:* `spec/requests/api/v1/inbox_spec.rb`,
  `spec/serializers/api/v1/inbox_entry_serializer_spec.rb`.
  *Code:* `Api::V1::InboxController#index`, `Api::V1::InboxEntrySerializer`.

- [x] **MOBILE-API-007** — When a client calls `GET /api/v1/inbox/count`,
  the system SHALL return the `Inbox::Count` value for the authenticated
  user, reusing its existing per-user cache so the mobile badge and the web
  nav badge derive from one computation.
  *Tests:* `spec/requests/api/v1/inbox_spec.rb`.
  *Code:* `Api::V1::InboxController#count`.

- [x] **MOBILE-API-008** — When a client requests
  `GET /api/v1/inbox/entries/:entry_id`, the system SHALL resolve the entry by
  re-running `Inbox::Queue` scoped to the kind parsed from the entry id
  prefix and matching the id — queue re-resolution, not a parallel
  per-lane lookup — so resolution doubles as the authorization check the
  web's `authoritative_entry` precedent sets. An id absent from the
  caller's current queue SHALL return `404` with error code `not_found`.
  *Tests:* `spec/services/inbox/find_entry_spec.rb`,
  `spec/requests/api/v1/inbox_spec.rb`.
  *Code:* `Inbox::FindEntry`, `Api::V1::InboxController#show`.

- [x] **MOBILE-API-009** — When a client posts
  `POST /api/v1/inbox/entries/:entry_id/chat`, the system SHALL require the
  bearer token to carry the `chat` scope (distinct from the `inbox` scope
  the read endpoints require) before delegating to
  `Inbox::OpenInteractiveChat` (same `InteractiveChatAccess` gate and
  per-user per-entry chat resolution as the web action), and return the
  resulting session's `chat_session_id`, without returning a web URL. A
  token scoped to `inbox` only SHALL receive `403` without creating or
  resuming a chat session.
  *Tests:* `spec/requests/api/v1/inbox_spec.rb`.
  *Code:* `Api::V1::InboxController#chat`.

- [x] **MOBILE-API-010** — When a client sends `GET /api/v1/inbox` or
  `GET /api/v1/inbox/count` with an `If-None-Match` header matching the
  current strong ETag, the system SHALL respond `304` with an empty body
  without building the inbox queue. The ETag SHALL be a digest of the
  caller's user id, the normalized filter parameters, and the account's
  current `Dashboard::CacheVersion` `:inbox` value; success responses
  SHALL carry `Cache-Control: private, max-age=0`.
  *Tests:* `spec/requests/api/v1/inbox_spec.rb`.
  *Code:* `Api::V1::InboxController` ETag helpers.

## Chat endpoints

- [ ] **MOBILE-API-011** — When a client manages chat sessions through
  `/api/v1/chat_sessions` (list, create, show, update, close, archive,
  unarchive, reopen), the system SHALL reuse the web controllers' scoping
  and service delegation and SHALL return session payloads mirroring
  `session_json`. Mobile v1 session creation SHALL be inline-only: the
  namespace SHALL NOT accept a container-capability request, keeping
  workspace/container chat a web surface.
  *Tests:* `spec/requests/api/v1/chat_sessions_spec.rb`.
  *Code:* `Api::V1::ChatSessionsController`.

- [ ] **MOBILE-API-012** — When a client lists
  `GET /api/v1/chat_sessions/:chat_session_id/messages`, the system SHALL
  paginate with a keyset cursor — `before` (exclusive message-id cursor)
  and `limit` (default 50, max 100) — returning the page oldest-first and
  a `next_before` cursor when older messages remain, and SHALL NOT offer
  offset pagination. Provenance: only the `before` cursor and the
  oldest-first ordering are reused from the web index (which hardcodes a
  50-message page and returns a bare array with no cursor metadata); the
  configurable `limit` and the `next_before` field are new mobile-surface
  response shaping that `Api::V1::ChatMessagesController#index` must add,
  not a port of existing web behavior.
  *Tests:* `spec/requests/api/v1/chat_messages_spec.rb`.
  *Code:* `Api::V1::ChatMessagesController#index`.

- [ ] **MOBILE-API-013** — When a client sends a chat message through
  `POST /api/v1/chat_sessions/:chat_session_id/messages`, the system SHALL
  negotiate the response exactly as `ChatMessagesController` does (the
  normative claims remain CHAT-API-002 for send/pause behavior): JSON by
  default, SSE when the request's `Accept` header includes
  `text/event-stream`; JSON responses SHALL mirror `assistant_response_payload`
  (a `message_json`-shaped object or `{ "status": "paused" }`); SSE streams
  SHALL emit the existing CHAT-API event catalog verbatim with no new event
  names or payload reshaping.
  *Tests:* `spec/requests/api/v1/chat_messages_spec.rb`.
  *Code:* `Api::V1::ChatMessagesController#create`.

- [ ] **MOBILE-API-014** — When a client resolves a pending tool call
  through `POST /api/v1/chat_sessions/:chat_session_id/messages/:message_id/resolve`
  with `decision` `approve` or `deny`, the system SHALL delegate to
  `ChatSessions::ResolveToolCall` under the same authorization the web
  `resolve` action applies (CHAT-API-004 remains normative for the
  atomic-claim and resume semantics) and SHALL honor the same JSON/SSE
  `Accept` negotiation as MOBILE-API-013.
  *Tests:* `spec/requests/api/v1/chat_messages_spec.rb`.
  *Code:* `Api::V1::ChatMessagesController#resolve`.

## Error taxonomy

- [ ] **MOBILE-API-015** — When any `/api/v1` endpoint fails, the system
  SHALL respond with the unified envelope
  `{ "error": { "code": …, "message": …, "details": … } }` and the status
  mapping defined in the LLD (`400 invalid_request`, `401 unauthorized`,
  `403 forbidden`, `404 not_found`, `409 conflict`,
  `422 validation_failed`, `429 rate_limited`, `500 internal_error`,
  `502 provider_error`, `503 provider_unavailable`), never an ad-hoc
  top-level `{ "error": "string" }` body. SSE streams SHALL keep the
  in-stream `error` event per CHAT-API-002; web endpoint error shapes
  SHALL remain unchanged.
  *Tests:* `spec/requests/api/v1/error_envelope_spec.rb`.
  *Code:* `Api::V1::BaseController` rescue-from mapping.

## Contract infrastructure

- [ ] **MOBILE-API-016** — The `/api/v1` namespace SHALL be described by
  `docs/api/openapi.yaml` as the contract source of truth, with `committee`
  validating requests and responses against it — strict in the test
  environment so request specs assert conformance, warn-and-log elsewhere.
  The schema SHALL express the polymorphic inbox envelope as `oneOf` per
  entry kind with `kind` discriminators.
  *Tests:* `spec/requests/api/v1/*` (behind committee middleware).
  *Code:* `config/initializers/committee.rb`, `docs/api/openapi.yaml`.

- [ ] **MOBILE-API-017** — CI SHALL verify the mobile consumer Pact against
  the running app with provider responses validated against the same
  `openapi.yaml`, so Pact verification and schema validation cannot drift
  apart.
  *Tests:* `spec/pact/providers/*` (CI job).
  *Code:* `.github/workflows` Pact job.

- [ ] **MOBILE-API-018** — CI SHALL run Schemathesis fuzzing against the
  running app from `openapi.yaml`: full property-based fuzzing on read
  endpoints and request-conformance checks on mutation endpoints without
  executing real chat sends.
  *Tests:* CI Schemathesis job.
  *Code:* `.github/workflows` Schemathesis job.

- [ ] **MOBILE-API-019** — The OpenAPI document SHALL carry the SSE event
  catalog as an `x-sse-events` schema extension on the send and resolve
  operations, enumerating each event name from the CHAT-API catalog
  (`message_start`, `message_chunk`, `message_created`,
  `message_tool_call`, `message_tool_confirmation`, `message_tool_result`,
  `message_tool_resolved`, `message_complete`, `error`) with its payload
  schema, so client codegen and server tests share one machine-checkable
  catalog owned by `api-mode-chat`.
  *Tests:* `spec/lib/api/v1/openapi_sse_catalog_spec.rb`.
  *Code:* `docs/api/openapi.yaml`.

## Non-goals (pinned)

- [ ] **MOBILE-API-020** — The `/api/v1` namespace SHALL NOT expose
  notification, push, or APNs resources, and SHALL NOT grow surfaces beyond
  inbox and chat without a deliberate schema addition to `openapi.yaml`:
  there is no bell/notification surface, and refresh remains client polling
  under MOBILE-API-010.
  *Tests:* `spec/requests/api/v1/routing_spec.rb`.
  *Code:* `config/routes.rb` (`namespace :api` → `namespace :v1` scope).
