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

## Background Work

- [x] **RAILS-CONTROL-PLANE-003** — The control plane SHALL use GoodJob as its
  lightweight Rails background executor with `async_server` as the default
  execution mode and a declared cron schedule for recurring maintenance and
  queue-processing work.
  *Tests:* `spec/config/good_job_configuration_spec.rb`.
  *Code:* `Paid::GoodJobConfig`, `config/initializers/good_job.rb`.

## Current View Stack

- [x] **RAILS-CONTROL-PLANE-004** — The control plane SHALL continue to ship
  ERB and Turbo-stream templates as the active view stack until a dedicated
  component-layer migration replaces them.
  *Code:* `app/views/projects/agent_runs/show.html.erb`, `app/views/projects/knowledge_recommendations/update.turbo_stream.erb`.

- [D] **RAILS-CONTROL-PLANE-005** — When a Phlex migration is approved, the
  control plane SHALL update this segment to replace the ERB-specific claim with
  the new shipped component-layer behavior.
