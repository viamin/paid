# EARS Specs: Runner Quota Tracking and Quota-Aware Routing

> Testable claims for proactive runner quota snapshots, `/runners` quota
> display, and quota-aware runner ordering. Status markers: `[x]` implemented ·
> `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r RUNNER-QUOTA-001`).

- [x] **RUNNER-QUOTA-001** — When a runner quota refresh sees an unsupported
  provider quota API, no provider data, or a refresh failure, the system SHALL
  overwrite any previously stored optimistic quota snapshot for that runner
  with an unavailable snapshot so routing falls back to reactive runner health
  instead of using stale quota data.
  *Code:* `app/services/runners/refresh_quota_snapshots.rb`,
  `app/models/runner_state.rb`.
  *Test:* `spec/services/runners/refresh_quota_snapshots_spec.rb`.

- [x] **RUNNER-QUOTA-002** — When a runner has a fresh proactive quota
  snapshot, the `/runners` page SHALL show remaining quota percentage,
  remaining/limit values, unit, and refresh/reset timing; when quota polling is
  unsupported or unavailable, the page SHALL show explicit reactive-fallback
  messaging instead of a stale percentage.
  *Code:* `app/controllers/runners_controller.rb`,
  `app/views/runners/index.html.erb`.
  *Test:* `spec/requests/runners_spec.rb`.

- [x] **RUNNER-QUOTA-003** — When the primary runner's fresh quota headroom is
  below the low-headroom threshold and a fallback runner has fresh headroom at
  or above the preferred threshold, runner ordering SHALL promote that fallback
  before execution starts.
  *Code:* `app/temporal/activities/run_agent_activity.rb`,
  `app/services/runners/quota_score.rb`.
  *Test:* `spec/temporal/activities/run_agent_activity_spec.rb`,
  `spec/services/runners/quota_score_spec.rb`.

- [x] **RUNNER-QUOTA-004** — When a runner quota snapshot is stale, unsupported,
  or otherwise unavailable, quota-aware ordering SHALL ignore that snapshot and
  preserve the existing reactive runner order.
  *Code:* `app/models/runner_state.rb`,
  `app/temporal/activities/run_agent_activity.rb`,
  `app/services/runners/quota_score.rb`.
  *Test:* `spec/services/runners/quota_score_spec.rb`,
  `spec/temporal/activities/run_agent_activity_spec.rb`.
