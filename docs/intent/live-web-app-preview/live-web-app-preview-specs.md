# EARS Specs: Live Web App Preview

> Testable claims for live preview and interactive verification. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r LIVE-PREVIEW-001`).

- [x] **LIVE-PREVIEW-001** — When preview provisioning is invoked for an agent
  run, the system SHALL boot the app container, provision service dependencies,
  manage preview tunnel state, and restore baseline service state during
  cleanup.
  *Code:* `app/services/previews/provision.rb`.
  *Test:* `spec/services/previews/provision_spec.rb`.

- [x] **LIVE-PREVIEW-002** — When project verification is enabled for an agent
  run, the system SHALL provision a browser sidecar, attach the playwright-mcp
  MCP definition, and publish the resulting browser connection into the run's
  MCP state.
  *Code:* `app/services/agent_runs/verification.rb`,
  `app/temporal/activities/provision_browser_container_activity.rb`.
  *Test:* `spec/services/agent_runs/verification_spec.rb`,
  `spec/temporal/activities/provision_browser_container_activity_spec.rb`.

- [ ] **LIVE-PREVIEW-003** — When a user starts or restarts a project preview,
  the system SHALL invoke real preview provisioning rather than marking a new
  `PreviewSession` ready without a live app, tunnel, or container.

- [x] **LIVE-PREVIEW-004** — When a preview is served at `/previews/:token`,
  the system SHALL route the root-path experience through the tunnel-backed
  proxy path instead of mixing real proxying with controller-side simulated
  preview fallback.
  *Code:* `app/middleware/previews_proxy.rb`,
  `app/controllers/previews_controller.rb`.
  *Test:* `spec/middleware/previews_proxy_spec.rb`,
  `spec/requests/previews_spec.rb`, `spec/requests/projects_spec.rb`.

- [ ] **LIVE-PREVIEW-005** — When an agent performs interactive verification,
  the system SHALL persist a verification outcome and related artifacts beyond
  browser-sidecar provisioning so review flows can see what the agent actually
  verified.

- [ ] **LIVE-PREVIEW-006** — When a Playwright trace is recorded for a real
  agent run, the system SHALL publish it through the same durable key contract
  that the trace viewer UI expects.
