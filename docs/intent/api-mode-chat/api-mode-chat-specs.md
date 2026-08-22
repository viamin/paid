# EARS Specs: API-Mode Interactive Chat

> Testable claims for the shipped API-mode portion of interactive chat. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **CHAT-API-001** — When a user creates or opens an API-mode chat session,
  the system SHALL persist and expose an active inline chat session with a
  system prompt and session/message routes, defaulting to
  `container_capability: none`; the legacy `mode=api` input SHALL resolve to
  the same inline behavior, while legacy `mode=workspace` remains only a
  compatibility shim into the RDR-037 capability model.
  *Tests:* `spec/requests/chat_sessions_spec.rb`,
  `spec/services/chat_sessions/create_spec.rb`.
  *Code:* `ChatSessionsController#create_params`,
  `ChatSessionsController#container_capability_for_legacy_mode`,
  `ChatSessions::Create#call`,
  `ChatSessions::Create#persist_system_message`.

- [x] **CHAT-API-002** — When an API-mode chat turn is sent through JSON, SSE,
  or ActionCable, the system SHALL persist the user/assistant conversation,
  stream start/chunk/tool/completion events, and return a paused status instead
  of an error when the loop stops for a write-tool confirmation.
  *Tests:* `spec/requests/chat_messages_spec.rb`,
  `spec/channels/chat_channel_spec.rb`,
  `spec/jobs/chat_sessions/process_message_job_spec.rb`,
  `spec/services/chat_sessions/send_message_spec.rb`.
  *Code:* `ChatMessagesController#create`,
  `ChatMessagesController#stream_sse_response`,
  `ChatMessagesController#assistant_response_payload`,
  `ChatChannel#send_message`,
  `ChatSessions::ProcessMessageJob#perform`,
  `ChatSessions::SendMessage#call`.

- [x] **CHAT-API-003** — When the API-mode chat loop receives tool calls, the
  system SHALL execute authorized read-only tools inline, advertise write tools
  without model-supplied confirmation, persist pending write-tool confirmation
  messages, and record token usage even for turns that pause before a final
  assistant message is emitted.
  *Tests:* `spec/services/chat_sessions/agent_loop_spec.rb`,
  `spec/mcp/tools/registry_spec.rb`,
  `spec/jobs/chat_sessions/process_message_job_spec.rb`.
  *Code:* `Tools::Registry.chat_definitions_for`,
  `ChatSessions::AgentLoop#run`,
  `ChatSessions::AgentLoop#process_tool_call`,
  `ChatSessions::AgentLoop#process_write_tool_calls`,
  `ChatSessions::AgentLoop#pause_for_confirmation`.

- [x] **CHAT-API-004** — When a pending API-mode write-tool confirmation is
  approved or denied, the system SHALL atomically claim the pending row, inject
  `confirmed: true` only on approval, persist the tool result, and resume the
  loop only after the last pending confirmation has been resolved.
  *Tests:* `spec/requests/chat_messages_spec.rb`,
  `spec/services/chat_sessions/resolve_tool_call_spec.rb`.
  *Code:* `ChatMessagesController#resolve`,
  `ChatMessagesController#stream_resolve_response`,
  `ChatSessions::ResolveToolCall#call`,
  `ChatSessions::ResolveToolCall#claim_resolution!`,
  `ChatSessions::ResolveToolCall#confirmed_arguments`,
  `ChatSessions::ResolveToolCall#resume_loop_unless_other_pending`.

- [x] **CHAT-API-005** — When API-mode chat usage is recorded, the system SHALL
  attribute token usage to the chat session and surface aggregated token and
  cost totals through the chat session APIs so operators can observe chat
  consumption without conflating it with agent-run totals.
  *Tests:* `spec/requests/chat_messages_spec.rb`,
  `spec/requests/chat_sessions_spec.rb`,
  `spec/services/chat_sessions/send_message_spec.rb`.
  *Code:* `TokenUsageTracker.track`,
  `TokenUsageTracker.record_per_request_usage`,
  `ChatSessionsController#session_scope_with_token_totals`,
  `ChatSessionsController#session_json`.

- [x] **CHAT-API-006** — When an API-mode chat runner raises a provider error
  such as a rate limit, the system SHALL retry the turn on a usable API-key
  backed replacement runner, preferring a runner newly selected on the chat
  session and then falling back through chat fallback-enabled runners; inline
  chat runner selectors SHALL only offer runners that can build an API chat
  client.
  *Tests:* `spec/services/chat_sessions/fallback_runners_spec.rb`,
  `spec/jobs/chat_sessions/process_message_job_spec.rb`,
  `spec/requests/chat_sessions_spec.rb`.
  *Code:* `ChatSessions::FallbackLoop#run_with_fallbacks`,
  `ChatSessions::FallbackRunners.for`,
  `ChatSessionsController#load_sidebar_data`.

- [x] **CHAT-API-007** — When a chat client is built for a z.ai direct-provider
  runner (`zai` or `zai_coding`), the system SHALL pass an output-token cap of
  16,384 to the OpenAI-compatible transport so GLM chat responses are not
  truncated into empty content by the transport's lower default; chat clients
  for other OpenAI-compatible providers SHALL keep the transport default.
  *Tests:* `spec/services/chat_sessions/build_llm_client_spec.rb`.
  *Code:* `ChatSessions::BuildLlmClient#openai_compatible_client`,
  `Runner::DIRECT_OUTBOUND_API_PROVIDERS`,
  `ChatSessions::BuildLlmClient::HttpClient#chat_kwargs`.

- [x] **CHAT-API-008** — When rendering the chat session show page
  (`GET /chat/:id` as HTML), the conversation panel's outer wrapper SHALL
  bound its height to the available viewport using `dvh` units, accounting
  for the panel's actual rendered offset from the top of the viewport
  (including layout chrome such as flash banners above `<main>`) so the inner
  `overflow-y-auto` region is the actual scroll container rather than the
  document. The bound SHALL be expressed as a **definite `height`**, not a
  `max-height`, and the wrapper SHALL NOT carry a `min-h-[70vh]` floor.
  A `max-height` leaves the wrapper's own height `auto` and therefore
  *indefinite*, so the percentage heights beneath it do not resolve: the
  shared conversation partial's `h-full` root collapses to its natural
  content height, overflows the `min-h-0 flex-1 overflow-hidden` wrapper,
  and the transcript is clipped mid-conversation with the message input
  unreachable and nothing scrollable. A definite `height` makes every
  descendant flex item definite, so `h-full` resolves and
  `[data-chat-target="container"]` becomes the real scroll region. The
  `70vh` floor is dropped because, against a definite height, `min-height`
  can only clamp the panel *taller* than the viewport it was just fitted
  to — re-creating the document-scroll failure it was meant to prevent —
  and the viewport-derived height already exceeds `70vh` on the desktop
  layout. The bound is required because the chat controller's
  `scrollToInput`, `scrollToTop`, and `handleScroll` (back-to-top visibility
  and auto-scroll tracking) only fire on `containerTarget.scrollTop`, which
  stays at 0 when the document scrolls instead of the intended container
  (#3459, follow-up to #3331; regression fixed in #3575).

  The offset SHALL be measured document-relative
  (`getBoundingClientRect().top + window.scrollY`), not viewport-relative. A
  viewport-relative reading understates the offset — clamping to `0` — whenever
  the page is already scrolled as the controller connects (a Turbo restoration
  visit, or a user who scrolls before JS boots), which sizes the panel a full
  viewport tall and hands the scroll role straight back to the document. The
  document offset is scroll-invariant, so the panel binds identically on every
  visit.
  *Tests:* `spec/requests/chat_sessions_spec.rb` ("height-bounds the chat
  panel …", "keeps the measured viewport height bound when the show page
  renders a flash banner", "uses a definite height rather than a max-height
  so the conversation's `h-full` root resolves", "gives the conversation's
  scroll wrapper a min-h-0 flex constraint (#3331)"),
  `spec/lib/chat_controller_node_harness_spec.rb`
  ("testUpdateViewportHeightIsScrollInvariant").
  *Code:* `app/views/chat_sessions/show.html.erb` (chat panel outer wrapper),
  `app/javascript/controllers/chat_controller.js#updateViewportHeight`.

- [x] **CHAT-API-009** — While the chat session show page's conversation
  panel is bound to the viewport (CHAT-API-008), the panel header SHALL stay
  compact enough to leave the transcript a usable share of the panel, without
  ever hiding a workspace control the user needs.

  The workspace capability panel — whose cloned-repo list grows without
  bound — SHALL sit behind a `<details>` disclosure. The disclosure SHALL
  render **open in the server response** for any session that has a workspace
  (`container_capability` other than `none`), and collapsed only for
  inline-only chats. A stopped workspace's sole recovery path is the "Reopen
  with workspace" button inside that panel, and a ready workspace's clone
  affordance and repo list live there too; folding them away leaves a stopped
  chat looking unrecoverable. Server-rendering the `open` state (rather than
  relying on a click) keeps those controls reachable before, and without,
  JavaScript. When a live `capability_changed` broadcast *reveals* one of
  those actions, the controller SHALL unfold the surrounding `<details>` with
  it, since un-hiding a control inside a collapsed disclosure reveals nothing;
  it SHALL NOT unfold the disclosure when it is hiding an action, or every
  unrelated broadcast would expand the header.

  The header SHALL carry a percentage `max-height` with its own
  `overflow-y-auto` so no combination of long titles, badges, or workspace
  state can starve the message list, plus `overflow-x-hidden` so that scroll
  container does not compute its x axis to `auto` and hang a horizontal
  scrollbar off the header. The cap SHALL relax while the disclosure is open
  (`has-[details[open]]`): clipping content the user just chose to expand is
  worse than a temporarily shorter transcript, and collapsing it again
  reclaims the space. Without the relaxed cap, opening Workspace on a 900px
  viewport hid ~84px of the panel below the header's clipped edge with no
  visible hint that the header scrolled.

  Without these bounds the header's runner/model controls, token bar, and
  workspace panel consume most of a viewport-bound panel and the transcript
  renders in a sliver too short to read (#3575).
  *Tests:* `spec/requests/chat_sessions_spec.rb` ("collapses the workspace
  disclosure for an inline-only chat", "renders the workspace disclosure open
  when the chat has a workspace", "bounds the chat panel header so the
  transcript keeps usable height", "relaxes the header cap while the workspace
  disclosure is open"), `spec/system/chat_workspace_reopen_spec.rb`,
  `spec/lib/chat_controller_node_harness_spec.rb`
  ("testStoppedCapabilityUnfoldsItsDisclosure",
  "testHiddenCapabilityActionLeavesDisclosureAlone").
  *Code:* `app/views/chat_sessions/show.html.erb` (panel header),
  `app/javascript/controllers/chat_controller.js#toggleCapabilityActions`,
  `app/views/chat_sessions/_popup.html.erb` (established pattern).
