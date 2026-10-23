# EARS Specs: Human-led Delivery Telemetry

- [x] **DELIVERY-TELEMETRY-001** — When a project has a completed linked
  feature delivery, the system SHALL report its create-feature start,
  approval, release, final implementation merge, cycle duration, and human
  touch counts without writing telemetry records.

- [x] **DELIVERY-TELEMETRY-002** — When a project has resolved approval
  decisions or evaluated criteria, the system SHALL report blocker-code
  time-to-clear and vague-criteria rate, and SHALL report stale approval
  snapshots by comparing immutable approved PR heads with current design PR
  heads.

- [x] **DELIVERY-TELEMETRY-003** — When a merged linked PR's latest
  conformance verdict is `within_scope` and a later `merged` design amendment
  supersedes that verdict's approved revision, the system SHALL count it as
  escaped drift in project and reviewer-model aggregates without manual
  adjudication, using the amendment's `merged_at` as the landing time.

- [x] **DELIVERY-TELEMETRY-004** — When an enforcement activation time is
  supplied, the system SHALL compare pre-activation and post-activation
  delivery time using PR creation to merged-or-closed time for the same
  project.

- [x] **DELIVERY-TELEMETRY-005** — When reporting escaped drift, the system
  SHALL disclose whether the project's `approved_intent_amendments` flow is
  enabled so a zero rate is not presented as an observed measurement when
  amendments cannot be recorded.
