# EARS Specs: Inbox Phase Ownership and Relevance

- [x] **INBOX-PHASE-RELEVANCE-001** — Every phase-owned Inbox request SHALL
  record its responsible phase and its originating work when the request is
  produced, SHALL classify legacy requests from existing run, issue, and
  request-producer evidence, and SHALL keep requests with unresolved ownership
  visible with an explicit classification gap rather than hiding them or
  granting them execution authority.
  *Tests:* `spec/services/inbox/phase_ownership_spec.rb`
  *Code:* `Inbox::PhaseOwnership`, `InboxRequestOwnership`

- [x] **INBOX-PHASE-RELEVANCE-002** — A phase-owned request SHALL appear in the
  default actionable Inbox only when its phase is enabled for the project, or
  an active continuation grant covers that phase and work, or it is needed to
  complete an explicitly started manual action that remains outstanding.
  *Tests:* `spec/services/inbox/phase_relevance_spec.rb`
  *Code:* `Inbox::PhaseRelevance`

- [x] **INBOX-PHASE-RELEVANCE-003** — A request excluded by phase relevance
  SHALL remain accessible in a **Disabled phases** view and on work details
  with its stop reason and recovery action, and hiding it SHALL NOT resolve
  the request, clear its questions, remove GitHub comments, alter issue
  readiness, or grant automatic continuation.
  *Tests:* `spec/services/inbox/phase_relevance_spec.rb`,
  `spec/requests/inbox_spec.rb`
  *Code:* `Inbox::Queue`, `InboxController`

- [x] **INBOX-PHASE-RELEVANCE-004** — Re-enabling a phase SHALL reconcile its
  outstanding requests before restoring relevant ones, and SHALL NOT restore
  requests that are satisfied, closed, or superseded.
  *Tests:* `spec/services/inbox/phase_relevance_spec.rb`,
  `spec/services/inbox/removals_spec.rb`
  *Code:* `Automation::PhaseSettings::Update`,
  `Inbox::Removals::RestoreOnPhaseEnablement`, `Inbox::PhaseRelevance`

- [x] **INBOX-PHASE-RELEVANCE-005** — Inbox lists, counts, navigation badges,
  availability indicators, search filters, chat admission, and direct-link
  access SHALL share one phase-relevance policy, preserve account isolation,
  and preserve existing authorization checks.
  *Tests:* `spec/services/inbox/count_spec.rb`,
  `spec/requests/api/v1/inbox_spec.rb`
  *Code:* `Inbox::Count`, `Inbox::Availability`, `Inbox::Queue`

- [x] **INBOX-PHASE-RELEVANCE-006** — Every Inbox item SHALL offer **Remove
  from Inbox**, which SHALL hide that request for the acting user only, SHALL
  NOT resolve the request, change automation authorization, cancel work, or
  delete questions and history, SHALL leave other users' visibility unchanged,
  and SHALL remain inspectable through a **Removed** filter, related-item
  history, and the API.
  *Tests:* `spec/services/inbox/removals_spec.rb`, `spec/requests/inbox_spec.rb`
  *Code:* `InboxRemoval`, `Inbox::Removals::Remove`, `InboxController`

- [x] **INBOX-PHASE-RELEVANCE-007** — A removed request SHALL stay suppressed
  until its project's responsible phase transitions from disabled to enabled,
  in which case only still-actionable requests are restored, or until manual
  work on the related item produces a fresh Inbox-worthy occurrence; polling,
  unchanged saves, viewing, routine synchronization, automated retries,
  follow-ups, and classification alone SHALL NOT restore it.
  *Tests:* `spec/services/inbox/removals_spec.rb`
  *Code:* `Inbox::Removals::RestoreOnPhaseEnablement`, `Inbox::RequestIdentity`

- [x] **INBOX-PHASE-RELEVANCE-008** — Personal removal SHALL be persisted
  against a stable request identity and occurrence with the user and the
  removal event, so rebuilding the derived queue cannot resurrect it, a
  removal made after an occurrence SHALL survive delayed events from that
  occurrence, and returning an item SHALL clear suppression only for the new
  occurrence.
  *Tests:* `spec/services/inbox/removals_spec.rb`
  *Code:* `InboxRemoval`, `Inbox::RequestIdentity`

- [x] **INBOX-PHASE-RELEVANCE-009** — Personally removed items SHALL be
  excluded consistently from default lists, counts, badges, and availability,
  while authorized direct-link inspection and manual work SHALL remain
  available.
  *Tests:* `spec/services/inbox/count_spec.rb`, `spec/requests/api/v1/inbox_spec.rb`
  *Code:* `Inbox::Count`, `Inbox::Queue`

- [x] **INBOX-PHASE-RELEVANCE-010** — Personal removal SHALL affect
  presentation only: it SHALL NOT grant execution permission nor remove
  enforcement for platform requests, phase-less requests SHALL be able to
  return on fresh manual-work conditions, and phase enablement SHALL apply only
  to phase-owned requests.
  *Tests:* `spec/services/inbox/removals_spec.rb`
  *Code:* `Inbox::Removals::RestoreOnPhaseEnablement`, `Inbox::PhaseRelevance`
