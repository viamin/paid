# RDR-045 Audit Report — 2026-08-04

## Summary

RDR-045 is no longer accurately described as "not implemented". Between July 9 and July 18, 2026, the repo shipped substantial preview and verification foundations under epic [#2844](https://github.com/viamin/paid/issues/2844) and child issues [#2845](https://github.com/viamin/paid/issues/2845) through [#2855](https://github.com/viamin/paid/issues/2855). As of Tuesday, August 4, 2026, all of those issues are closed on GitHub, but the work is only partially end-to-end.

The closed epic currently hides two different truths:

1. Important preview, trace, tunnel, Phoenix, and verification-browser infrastructure did ship.
2. The user-facing live-preview and agent self-verification flows are still incomplete and need reopened follow-up issues.

## GitHub State

- Epic [#2844](https://github.com/viamin/paid/issues/2844) is closed.
- Child issues [#2845](https://github.com/viamin/paid/issues/2845), [#2846](https://github.com/viamin/paid/issues/2846), [#2847](https://github.com/viamin/paid/issues/2847), [#2848](https://github.com/viamin/paid/issues/2848), [#2849](https://github.com/viamin/paid/issues/2849), [#2850](https://github.com/viamin/paid/issues/2850), [#2851](https://github.com/viamin/paid/issues/2851), [#2852](https://github.com/viamin/paid/issues/2852), [#2853](https://github.com/viamin/paid/issues/2853), [#2854](https://github.com/viamin/paid/issues/2854), and [#2855](https://github.com/viamin/paid/issues/2855) are all closed.
- Gap-reconciliation issue [#3166](https://github.com/viamin/paid/issues/3166) is open.

## What Shipped

### Phoenix / framework support

- `Screenshots::DetectFramework` now detects Phoenix and discovers Phoenix routes.
- `Screenshots::FrameworkPatterns` includes Phoenix patterns.
- screenshot and route-collection specs cover Phoenix repositories.
- `ContainerCapture` recognizes Phoenix projects.

### Playwright traces and derived media

- `Screenshots::ContainerCapture` records `.trace.zip` artifacts.
- trace upload/export helpers exist in `Screenshots::Storage`, `Screenshots::Publish`, and `Screenshots::TraceArtifactExporter`.
- GIF/video derivation exists via `Screenshots::TraceToGif`.
- `Previews::TraceViewer` and the `projects/_trace_viewer` UI partial exist.

### Preview/tunnel/proxy foundations

- `PreviewSession` and supporting reservation/provision-state tables exist.
- `Previews::Provision`, `Previews::TunnelManager`, `Previews::TunnelPortPool`, and `Previews::Expire` exist with specs.
- `PreviewsProxy` exists with request/middleware coverage for cookies, redirects, CSP/X-Frame-Options rewriting, and WebSocket upgrades.
- `bin/preview-tunnel-server`, `Procfile.dev`, and deploy wiring for the preview tunnel server exist.
- project and preview views/policies/routes exist.

### Agent verification foundations

- `Project#verification_enabled?` and Playwright MCP definition attachment exist.
- `AgentRuns::Verification` and `Activities::ProvisionBrowserContainerActivity` provision the browser sidecar and MCP wiring.
- the agent execution workflow schedules browser-container provisioning when verification is enabled.

## What Is Still Missing or Stubbed

### 1. Project preview actions are not wired to real provisioning

`ProjectsController#start_preview` and `#restart_preview` create a `PreviewSession`, mark it `ready`, and never call `Previews::Provision`. That produces a DB-visible session without a live container, tunnel, or app startup.

Evidence:

- `app/controllers/projects_controller.rb`
- `session.mark_ready!(tunnel_port: nil)`

### 2. Preview serving is split between real proxy code and controller-side fallback

The intended proxy path exists in `PreviewsProxy`, but `PreviewsController` still contains simulated preview markup and controller-side HTTP proxy logic for `/previews/:token`. The architecture is partly there, but the root-path experience is not yet cleanly unified on the tunnel-backed middleware path.

### 3. UI still reflects simulated/stubbed behavior

The project page, preview page, and request specs still allow simulated-preview flows and do not yet reflect a real asynchronous lifecycle from queued/provisioning to ready/failed/stopped backed by real resources.

### 4. Trace viewing needs end-to-end confirmation, not just producer/consumer pieces

Trace recording, upload helpers, and the viewer UI all exist, but the remaining question is whether real agent-run traces are durably uploaded and discoverable through the exact key contract the viewer expects in all intended scenarios.

### 5. Agent self-verification is not end-to-end

The browser sidecar and MCP definition are provisioned, but that is not yet the same as an agent starting the changed app, using Playwright meaningfully, and persisting a verification outcome/artifact onto the run.

## Reopened Follow-Up Issues

The remaining work has been re-opened into focused issues on August 4, 2026:

- [#3192](https://github.com/viamin/paid/issues/3192) — Wire project preview actions to real `PreviewSession` provisioning and teardown
- [#3193](https://github.com/viamin/paid/issues/3193) — Complete preview proxy routing and tunnel-backed root-path handling
- [#3194](https://github.com/viamin/paid/issues/3194) — Finish live preview UI lifecycle and access flows around real preview sessions
- [#3195](https://github.com/viamin/paid/issues/3195) — Close the loop from recorded Playwright traces to durable viewer artifacts
- [#3196](https://github.com/viamin/paid/issues/3196) — Implement end-to-end agent self-verification beyond browser sidecar provisioning
- [#3197](https://github.com/viamin/paid/issues/3197) — Re-open preview/runtime detection follow-up after RDR-046 lands

## Conclusion

RDR-045 should now be treated as **partially implemented**:

- July 2026 shipped the foundational components.
- August 2026 re-opened the still-missing end-to-end preview and verification work.

The repo docs should stop saying "not implemented" and should instead distinguish shipped foundations from the reopened gaps tracked by [#3166](https://github.com/viamin/paid/issues/3166) and [#3192](https://github.com/viamin/paid/issues/3192) through [#3197](https://github.com/viamin/paid/issues/3197).
