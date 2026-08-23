# RDR-045 Audit Report — 2026-08-23

## Summary

RDR-045 is implemented. The August 4, 2026 audit left the RDR partially implemented because five end-to-end gaps were still open behind the July foundation work. The current closeout audit re-checked the shipped code and tests against the RDR's requirements and validation scenarios and found those gaps closed in the repository.

Closeout issue: [#3596](https://github.com/viamin/paid/issues/3596)

Prior reconciliation: [audit-report-2026-08-04-rdr-045.md](audit-report-2026-08-04-rdr-045.md)

## Conclusion

Status: **Implemented**

No remaining acceptance-criterion gaps were identified in this audit.

## Shipped Evidence

### 1. Live preview sessions are provisioned for real, not as DB-only placeholders

- `app/controllers/projects_controller.rb:457` queues a preview session in `pending`, tears down any replaced non-terminal sessions, and enqueues `PreviewSessions::ProvisionJob`.
- `app/jobs/preview_sessions/provision_job.rb:21` loads the session, transitions `pending -> provisioning`, creates the synthetic preview run, and invokes `Previews::Provision`.
- `app/services/previews/provision.rb:127` provisions the container, checks out the branch, provisions services, loads seed data when allowed, starts the app, starts the tunnel, and only then marks the session `ready`.
- `spec/requests/projects_spec.rb:1294` proves `POST /projects/:id/start_preview` enqueues the provision job and leaves the session in `pending`.
- `spec/jobs/preview_sessions/provision_job_spec.rb:69` proves the job invokes `Previews::Provision` and completes the synthetic preview run.

### 2. Preview serving is unified on the tunnel-backed proxy path

- `app/controllers/previews_controller.rb:36` resolves token-based preview access, rejects non-proxiable sessions, and redirects the exact `/previews/:token` root to the canonical trailing-slash proxy path.
- `app/middleware/previews_proxy.rb:9` is the actual reverse proxy for `/previews/:token/*`, including authorization, tunnel-port resolution, HTTP forwarding, and WebSocket upgrades.
- `spec/requests/previews_spec.rb:195` proves the exact token path redirects into the middleware-served proxy root.
- `spec/middleware/previews_proxy_spec.rb:160` proves `X-Frame-Options` rewriting.
- `spec/middleware/previews_proxy_spec.rb:169` proves CSP `frame-ancestors` rewriting.
- `spec/middleware/previews_proxy_spec.rb:193` and `:203` prove redirect `Location` rewriting for relative and absolute upstream redirects.

### 3. The preview UI reflects the real lifecycle

- `app/models/preview_session.rb:6` defines the real lifecycle states: `pending`, `provisioning`, `starting`, `ready`, `stopped`, and `failed`.
- `app/models/preview_session.rb:20` broadcasts preview refreshes so the project UI can reflect lifecycle changes.
- `spec/requests/previews_spec.rb:119` proves provisioning sessions render lifecycle UI without an iframe.
- `spec/requests/previews_spec.rb:131` proves failed sessions surface their startup error.
- `spec/requests/previews_spec.rb:143` proves stopped sessions render restart guidance rather than live-preview content.
- `spec/requests/projects_spec.rb:1344` proves stopping an active preview tears down the real infrastructure rather than only updating the row.

### 4. Trace recording, derived media, and trace viewing are wired end-to-end

- `app/services/screenshots/container_capture.rb:260` uploads Playwright trace artifacts and includes them in the artifact manifest.
- `app/services/screenshots/trace_artifact_exporter.rb:66` derives animated GIFs from recorded traces and emits artifact metadata for them.
- `app/services/screenshots/pr_comment.rb:247` prefers animated GIF output in screenshot comment rendering when a `gif_url` is present.
- `app/services/previews/trace_viewer.rb:53` uses the shared screenshot storage key contract for trace lookup and builds the embeddable trace-viewer URL.
- `app/helpers/application_helper.rb:341` only exposes trace-viewer embed data when the run is finished and the trace object exists under that shared key contract.
- `spec/services/screenshots/container_capture_spec.rb:263` proves the trace upload contract uses the shared trace object key.
- `spec/services/screenshots/trace_artifact_exporter_spec.rb:150` proves GIF and video artifacts are exported and uploaded from the trace.
- `spec/services/screenshots/pr_comment_spec.rb:390` proves PR comment rendering uses animated GIF screenshots.
- `spec/services/previews/trace_viewer_spec.rb:78` proves the viewer embed URL resolves the stored trace artifact.
- `spec/helpers/application_helper_trace_viewer_spec.rb:31` proves the viewer helper uses the same PR/commit key contract the producer writes.
- `spec/views/projects/trace_viewer_partial_spec.rb:9` proves the UI renders the trace-viewer iframe when an embed URL exists.

### 5. Agent self-verification is end-to-end, not just browser-sidecar provisioning

- `app/services/agent_runs/verification.rb:56` provisions the browser sidecar, attaches the `playwright-mcp` MCP definition, refreshes the run MCP snapshot, and materializes the stdio server entry for the agent.
- `app/temporal/workflows/agent_execution_workflow.rb:190` schedules browser-container provisioning before the main agent execution when verification is enabled.
- `app/temporal/activities/run_agent_activity.rb:347` records verification output during post-run bookkeeping before auto-commit.
- `app/services/agent_runs/verification_result_recorder.rb:25` reads the agent-written verification result file, normalizes it, persists it to `agent_run.verification_result`, captures app log tail, and preserves artifact metadata.
- `spec/services/agent_runs/verification_spec.rb:33` proves browser-container provisioning and MCP wiring.
- `spec/temporal/activities/run_agent_activity_spec.rb:2728` proves an agent-recorded verification result is persisted before commit bookkeeping.
- `spec/temporal/activities/run_agent_activity_spec.rb:2749` proves the same result is still persisted when the runner exits non-zero.

### 6. Phoenix detection and startup are shipped across preview and knowledge flows

- `app/services/screenshots/detect_framework.rb:174` detects Phoenix projects via `mix.exs`.
- `app/services/previews/provision.rb:357` starts Phoenix previews with `PORT=3000 MIX_ENV=dev mix phx.server`.
- `app/services/knowledge/collectors/routes_collector.rb:172` recognizes Phoenix router files for route collection.
- `spec/services/screenshots/detect_framework_spec.rb:42` proves Phoenix detection and router parsing.
- `spec/services/previews/provision_spec.rb:513` proves Phoenix previews boot through `mix phx.server` with preview-specific config injection.
- `spec/services/knowledge/collectors/routes_collector_spec.rb:770` proves Phoenix routes are collected without Rails-specific commands.

### 7. Remote-host tunneling, concurrent previews, TTL cleanup, and access/security constraints are covered

- `app/services/previews/tunnel_manager.rb:164` derives the client remote destination from `Containers::ProxyUrl.resolve`, which is the remote-safe callback path used for local and remote Docker.
- `app/services/previews/tunnel_manager.rb:68` allocates stable tunnel ports and reuses released ports through `PreviewTunnelPortReservation`.
- `app/services/previews/tunnel_manager.rb:139` renders Noise-encrypted server config; `:164` renders Noise-encrypted client config.
- `app/models/preview_session.rb:11` gives preview sessions random 32-byte tokens and TTL-backed expiration.
- `spec/services/previews/tunnel_manager_spec.rb:53` proves stable port allocation and reuse; `:66` proves exhaustion handling; `:74` proves stale-reservation reclamation.
- `spec/services/previews/tunnel_manager_spec.rb:137` proves client config derives the remote destination from the proxy URL and points the tunnel at the preview app port.
- `spec/jobs/preview_sessions/expire_job_spec.rb:9` proves TTL expiry stops expired sessions.
- `spec/jobs/preview_sessions/expire_job_spec.rb:36` proves expiry tears down the tunnel reservation and preview container before stopping the session.
- `spec/requests/previews_spec.rb:246` and `:254` prove preview access requires authenticated, authorized project/account membership.

## Remaining Gaps

None found in this closeout audit.
