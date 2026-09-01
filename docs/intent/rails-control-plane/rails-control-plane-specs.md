# EARS Specs: Rails Control Plane

> Testable claims for the implemented Rails control plane. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r RAILS-CONTROL-PLANE-001`).

## Request and Realtime Lifecycle

- [x] **RAILS-CONTROL-PLANE-001** — When an authenticated Rails request runs,
  the control plane SHALL apply tenant context for the current user's account
  before application code executes and SHALL clear tenant context again after
  the request completes, including when the request raises.
  *Tests:* `spec/controllers/application_controller_spec.rb`.
  *Code:* `ApplicationController#with_current_attributes`.

- [x] **RAILS-CONTROL-PLANE-002** — When an authenticated Rails request reaches
  the control plane, the system SHALL stamp an encrypted cable-auth cookie and
  Action Cable connections SHALL accept only subscribers that can be resolved
  from Warden or that encrypted cookie.
  *Tests:* `spec/channels/application_cable/connection_spec.rb`.
  *Code:* `ApplicationController#stamp_cable_auth_cookie`, `ApplicationCable::Connection`.

- [x] **RAILS-CONTROL-PLANE-006** — When an authenticated request belongs to a
  suspended or deactivated account, the control plane SHALL fail closed at the
  controller layer by allowing suspended accounts read-only access, rejecting
  suspended write attempts, and revoking deactivated account access across
  HTML, JSON, and SSE request paths.
  *Tests:* `spec/requests/tenant_enforcement_spec.rb`.
  *Code:* `TenantEnforcement`, `ApplicationController`.

## Background Work

- [x] **RAILS-CONTROL-PLANE-003** — The control plane SHALL use GoodJob as its
  lightweight Rails background executor with `async_server` as the default
  execution mode and a declared cron schedule for recurring maintenance and
  queue-processing work.
  *Tests:* `spec/config/good_job_configuration_spec.rb`.
  *Code:* `Paid::GoodJobConfig`, `config/initializers/good_job.rb`.

- [x] **RAILS-CONTROL-PLANE-007** — When multiple hosts run the GoodJob cron
  scheduler, the system SHALL prevent duplicate scheduled jobs by stamping
  every cron enqueue with a `(cron_key, cron_at)` pair guarded by the unique
  index `index_good_jobs_on_cron_key_and_cron_at_cond`, so a second host firing
  the same tick enqueues nothing.
  *Tests:* `spec/config/good_job_cron_dedup_spec.rb`.
  *Code:* `config/initializers/good_job.rb`, `db/schema.rb`.

## Current View Stack

- [x] **RAILS-CONTROL-PLANE-004** — The control plane SHALL continue to ship
  ERB and Turbo-stream templates as the active view stack until a dedicated
  component-layer migration replaces them.
  *Code:* `app/views/projects/agent_runs/show.html.erb`, `app/views/projects/knowledge_recommendations/update.turbo_stream.erb`.

- [x] **RAILS-CONTROL-PLANE-008** — While the project show page renders its
  header — project name, status badge, action buttons, and external tracker
  link pills — the control plane SHALL keep the page inside the viewport width
  on mobile-size screens: the header containers SHALL wrap, and long project
  names and long external link URLs SHALL break within their flex containers
  rather than widening the document horizontally.
  *Tests:* `spec/system/projects/mobile_header_layout_spec.rb`.
  *Code:* `app/views/projects/show.html.erb` (project header).

- [D] **RAILS-CONTROL-PLANE-005** — When a Phlex migration is approved, the
  control plane SHALL update this segment to replace the ERB-specific claim with
  the new shipped component-layer behavior.
