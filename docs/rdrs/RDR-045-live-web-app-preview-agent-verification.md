# RDR-045: Live Web App Preview and Interactive Agent Verification

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-07-08
- **Status**: Draft
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related RDRs**: [RDR-004](RDR-004-container-isolation.md) (Container Isolation), [RDR-006](RDR-006-secrets-proxy.md) (Secrets Proxy), [RDR-019](RDR-019-remote-container-execution.md) (Remote Container Execution), [RDR-020](RDR-020-service-container-architecture.md) (Service Container Architecture), [RDR-028](RDR-028-interactive-chat.md) (Interactive Chat)
- **Related Tests**: `spec/services/screenshots/`, `spec/services/containers/`

## Implementation Status

Draft. Not implemented. The existing screenshot infrastructure (`Screenshots::ContainerCapture`) starts web apps in containers, connects a headless browser via CDP, and captures static screenshots — but tears everything down immediately. No live preview, no interactive agent verification, no tunneling, and no Playwright trace recording exist. Phoenix/Elixir is not detected by the framework detector.

## Problem Statement

Paid agents make code changes and create PRs, but neither the agent nor the human reviewer can interact with the running application to verify those changes. Today:

1. **Agents verify through tests and static screenshots only.** They cannot start the app, click through flows, fill forms, or observe runtime behavior interactively. They rely on the test suite and `Screenshots::ContainerCapture` (which captures static PNGs and tears down the container immediately).

2. **Human reviewers cannot preview changes live.** They review diffs and screenshots, then merge and test locally. There is no way to interact with the app running on a branch before merging, or on main after merging, without cloning and running it themselves.

3. **Screenshots are static and non-interactive.** The current PR comment shows before/after PNGs. A reviewer cannot see how a form submission flows, how a page transition animates, or how a multi-step interaction behaves.

4. **Phoenix/Elixir projects are unsupported.** The framework detector in `Screenshots::DetectFramework` and the app startup logic in `ContainerCapture#application_start_command` do not recognize `mix.exs`, so Phoenix LiveView projects (e.g., `color_matching`) cannot be started or captured.

Requirements:

- Agents must be able to start a web app in a container and interact with it via Playwright (scripts or playwright-mcp) to self-verify changes before pushing
- Human reviewers must be able to interact with the running app via an iframe embedded in the Paid UI, accessible before merge (PR branch) and after merge (main branch)
- Must work when Rails runs in a devcontainer (local Docker) and in remote/cloud deployments (remote Docker daemon)
- Must support WebSocket-dependent frameworks (Phoenix LiveView, Rails Action Cable / Hotwire)
- Must not require changes to the forwarded web apps (iframe headers, CORS, etc.)
- Must use local/seeded data, never production data
- Phoenix/Elixir detection must be added to framework detection and knowledge base route collection

## Context

### Background

Paid already has substantial infrastructure for running web apps in containers. `Screenshots::ContainerCapture` (`app/services/screenshots/container_capture.rb`) provisions a Docker container, checks out a PR branch, provisions service dependencies (Postgres, Redis), starts the web app (auto-detecting Rails, Django, Next.js, Vite, or generic Node.js), launches a `browserless/chromium` container with a CDP endpoint, runs a Playwright capture script, and tears everything down.

This proves the core capability: Paid can start an arbitrary web app in an isolated container, provision its dependencies, connect a browser, and interact with it over the Docker network. The delta between "screenshots" and "live preview" is:

- **Keep the app running** instead of tearing it down after capture
- **Expose the app's HTTP port** to a human reviewer's browser (currently no path exists)
- **Let the agent drive the browser interactively** via playwright-mcp, not just a one-shot capture script
- **Record Playwright traces** for enhanced PR comments and demo content

### Technical Environment

- **Container provisioning**: `Containers::Provision` creates Docker containers on `paid_agent` (restricted, no internet) or `paid_internal` (direct egress) networks. Each container gets resource limits, network isolation, and git checkout.
- **Service containers**: `Containers::ServiceProvisioner` provisions PostgreSQL, Redis, Selenium/Chromium as shared containers on the agent's network with well-known env vars (`DATABASE_URL`, `REDIS_URL`, `SELENIUM_URL`). Per-run isolated databases prevent cross-contamination.
- **Browser container**: `ContainerCapture` provisions `ghcr.io/browserless/chromium` with alias `paid-screenshot-browser` and CDP endpoint at `ws://paid-screenshot-browser:3000`. Playwright connects via `chromium.connectOverCDP()`.
- **MCP provisioning**: `Containers::McpProvisioner` supports `npx`-based stdio MCP servers (run inside the agent container) and `docker_image` sidecar containers. playwright-mcp would be an `npx` server.
- **Network reachability**: Rails is reachable from containers as `paid-proxy` (restricted) or `web` (unrestricted) locally, and via `PAID_PROXY_EXTERNAL_URL` for remote Docker (`app/services/containers/proxy_url.rb`). Critically, traffic flows container → Rails (outbound from container). Rails → container (the reverse direction) is available locally via Docker DNS but **not available for remote Docker** — this is the core networking constraint.
- **Framework detection**: `Screenshots::DetectFramework` (`app/services/screenshots/detect_framework.rb`, 816 lines) auto-detects framework, routes, services, and auth from repo contents. Supports Rails, Django, Next.js, Vite, generic — but **not Phoenix/Elixir**.
- **Screenshot config**: `.paid/screenshots.yml` in the repo configures driver, base_url, viewport, routes, auth, seed, services, and UI patterns. Parsed by `Screenshots::ConfigParser`.
- **Playwright**: Available as `playwright@1.61.1` in the Paid app's `package.json`. The agent Docker image has Node.js 22.13 but does not pre-install Playwright.
- **Existing devcontainer**: Paid runs in a devcontainer with Docker socket mounting (sibling containers). The devcontainer has the `paid-proxy` alias on the `paid_agent` network and exposes port 3000 to the host.

## Research Findings

### Investigation Process

1. Read the full `Screenshots::ContainerCapture` flow (661 lines) to understand how apps are started, browsers connected, and screenshots captured.
2. Examined `Containers::ServiceProvisioner`, `Containers::McpProvisioner`, `Containers::ProxyUrl`, and `Containers::Provision` to understand container networking and service injection.
3. Checked `Screenshots::DetectFramework` and `ContainerCapture#application_start_command` for Phoenix/Elixir support — confirmed it is absent.
4. Verified there is no existing reverse proxy, port publishing, or tunneling mechanism for exposing container apps to human browsers.
5. Analyzed networking constraints for both local devcontainer and remote Docker deployments.
6. Evaluated tunneling tools (rathole, frp) and reverse proxy approaches for bridging container ports to the Rails host.
7. Reviewed the MCP provisioning system to confirm playwright-mcp integration is feasible.

### Key Discoveries

**Discovery 1 — ContainerCapture already starts apps and connects browsers.** The full flow (provision container → checkout branch → provision services → detect framework → start app → readiness probe → start Chrome container → run Playwright) is operational. The only difference between screenshots and live preview is: keep the app running and expose it, rather than capturing and tearing down.

**Discovery 2 — No reverse path exists for remote Docker.** Rails can reach containers via Docker DNS when running locally (devcontainer with socket-mounted Docker). For remote Docker (RDR-019), containers are on the remote host's network and Rails cannot reach them directly. The secrets proxy works because traffic flows container → Rails (outbound). A live preview needs Rails → container (reverse), which requires a tunnel.

**Discovery 3 — Tunnel client connects outbound, which always works.** Preview containers can already reach Rails via `paid-proxy` (restricted) or `web`/`PAID_PROXY_EXTERNAL_URL` (remote). A tunnel client in the preview container establishing an outbound connection to a tunnel server alongside Rails works in both local and remote deployments. This is the same direction as the secrets proxy.

**Discovery 4 — iframe blocking headers can be stripped by the proxy.** Rails sets `X-Frame-Options: SAMEORIGIN` by default; Django sets `DENY`. Since the Rails reverse proxy sits between the browser and the app, it can strip `X-Frame-Options` and rewrite `Content-Security-Policy: frame-ancestors` transparently. The forwarded apps require zero changes. This is a significant advantage over direct port forwarding.

**Discovery 5 — ContainerCapture does not support seed data.** Line 186 explicitly raises an error: `"container screenshot capture does not yet support seed data"`. Live preview with "local data" requires seed support.

**Discovery 6 — Phoenix/Elixir is entirely undetected.** Neither `DetectFramework`, `FrameworkPatterns`, `ContainerCapture#application_start_command`, nor the knowledge base route collector recognizes `mix.exs`, Phoenix router macros, or LiveView patterns.

**Discovery 7 — playwright-mcp is an npx MCP server.** The `McpProvisioner` already handles `npx`-based stdio servers. playwright-mcp (`@executeautomation/playwright-mcp-server` or similar) would be provisioned as an npx server inside the agent container, with a CDP URL pointing to the browser container. No new MCP infrastructure is needed.

**Discovery 8 — Playwright traces produce multiple valuable outputs.** A single Playwright trace recording yields: interactive trace viewer (scrub through DOM snapshots, network, console), animated GIFs (for PR comments), and video (for demos). This upgrades the screenshot system from static PNGs to rich, animated content with minimal additional code (`trace: 'on'` in Playwright config).

## Proposed Solution

### Approach

Build a unified **Preview Session** capability that serves two use cases through shared infrastructure:

1. **Agent verification**: The agent starts the web app in its own container, provisions a browser container on the same network, and uses playwright-mcp (or Playwright scripts) to interact with the app, verify behavior, and record traces.

2. **Human preview**: A dedicated preview container is provisioned with the target branch checked out, the app is started, and a tunnel (rathole) bridges the app's port to the Rails host. A Rails reverse proxy exposes the app at `/previews/:token/*`, stripping iframe-blocking headers, handling WebSocket passthrough, and embedding in the Paid UI.

3. **Playwright traces as permanent infrastructure**: All Playwright-driven interactions (agent verification, screenshot capture, human preview flows) record traces. Traces are uploaded to S3 (reusing `Screenshots::Storage`) and produce: interactive trace viewer embeds, animated GIFs for PR comments, and video for demos.

The same preview session can serve both the agent (during verification) and the human (during review), avoiding duplicate container provisioning.

### Design Principles

- **Reuse ContainerCapture's app-starting logic.** Framework detection, service provisioning, app startup, and readiness probing are already solved. Extract into a shared service rather than duplicating.
- **Tunnel always connects outbound.** The rathole client in the preview container connects to the rathole server alongside Rails. This is the same direction as the secrets proxy and works in both local and remote deployments. One code path, no special-casing.
- **The proxy strips headers, the tunnel bridges bytes.** Concerns are separated: rathole handles TCP-level tunneling (HTTP + WebSocket transparently), Rails handles presentation (iframe headers, auth, cookie domain). Neither layer needs to understand the other's protocol.
- **Forwarded apps require zero changes.** The Rails proxy strips `X-Frame-Options`, rewrites CSP `frame-ancestors`, and rewrites redirect `Location` headers. The app never knows it is being proxied.
- **Traces are not a throwaway v1.** Playwright traces are permanent infrastructure that upgrades the screenshot system and serves agent verification, human review, PR comments, and demo generation. They coexist with live preview, not replace it.
- **Phoenix is a first-class framework.** Detection, startup, UI patterns, and route collection all include Elixir/Phoenix from day one.

### Technical Design

#### Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           DOCKER HOST                                     │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │            Docker Network (paid_agent / paid_internal)               │ │
│  │                                                                      │ │
│  │  ┌────────────────┐  ┌────────────┐  ┌────────────┐                 │ │
│  │  │ Preview         │  │ Postgres   │  │ Browser    │                 │ │
│  │  │ Container       │  │ Container  │  │ Container  │                 │ │
│  │  │                 │  │            │  │ (browserless│                 │ │
│  │  │ ┌────────────┐ │  └────────────┘  │ /chromium) │                 │ │
│  │  │ │ Web App    │ │                  └────────────┘                 │ │
│  │  │ │ (Phoenix,  │ │                        ▲                         │ │
│  │  │ │  Rails,    │ │                        │ CDP                     │ │
│  │  │ │  etc.)     │ │                        │ (ws://)                 │ │
│  │  │ │ :4000      │ │                        │                         │ │
│  │  │ └────────────┘ │            ┌───────────┴──────────┐             │ │
│  │  │ ┌────────────┐ │            │ Agent Container      │             │ │
│  │  │ │ Rathole    │ │            │ (playwright-mcp)     │             │ │
│  │  │ │ Client     │─┼──────────► │                      │             │ │
│  │  │ └────────────┘ │  outbound  └──────────────────────┘             │ │
│  │  └────────────────┘    connection                                    │ │
│  │                                │                                     │ │
│  │                                ▼                                     │ │
│  │  ┌───────────────────────────────────────────────────────────────┐  │ │
│  │  │  Rails (devcontainer / production server)                     │  │ │
│  │  │                                                                │  │ │
│  │  │  ┌──────────────┐   ┌───────────────┐   ┌────────────────┐   │  │ │
│  │  │  │ Rathole      │   │ Rails Reverse │   │ Rails App      │   │  │ │
│  │  │  │ Server       │   │ Proxy         │   │ (UI + API)     │   │  │ │
│  │  │  │ :7000        │◄──│ /previews/    │◄──│ :3000          │   │  │ │
│  │  │  │              │   │ :token/*      │   │                │   │  │ │
│  │  │  │ Port pool:   │   │               │   │ Preview UI     │   │  │ │
│  │  │  │ 8200-8299    │   │ - strip XFO   │   │ (iframe embed) │   │  │ │
│  │  │  │              │   │ - rewrite CSP │   │                │   │  │ │
│  │  │  │              │   │ - rewrite     │   │                │   │  │ │
│  │  │  │              │   │   redirects   │   │                │   │  │ │
│  │  │  │              │   │ - auth tokens │   │                │   │  │ │
│  │  │  └──────────────┘   └───────────────┘   └────────────────┘   │  │ │
│  │  └───────────────────────────────────────────────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                              ▲                            │
└──────────────────────────────────────────────┼────────────────────────────┘
                                               │
                                        User Browser
                                   localhost:3000
                                   /previews/:token/
                                   (same-origin iframe)
```

#### Rathole Tunnel

**Tool choice: rathole** (Rust, ~5MB binary, Noise protocol encryption, high throughput). Selected over frp for its smaller footprint, memory safety, and simpler configuration. frp's HTTP vhost mode (multiple services on one port with subdomains) is not needed — each preview gets its own TCP tunnel on an allocated port.

**Server configuration** (runs alongside Rails inside the devcontainer/production server):

```toml
# rathole server.toml
[server]
bind_addr = "0.0.0.0:7000"
default_token = "paid-preview-<random-secret>"

# No service definitions — clients register dynamically.
# The server opens a listener on the specified remote_port
# for each connecting client.
```

**Client configuration** (runs inside the preview container):

```toml
# rathole client.toml
[client]
remote_addr = "paid-proxy:7000"     # local Docker
# remote_addr = "PAID_PROXY_EXTERNAL_URL:7000"  # remote Docker
default_token = "paid-preview-<same-secret>"

[client.services.preview-<token>]
local_addr = "127.0.0.1:4000"       # app port inside container
remote_port = <allocated-port>       # from port pool (8200-8299)
```

**Port allocation**: A managed port pool (8200-8299, 100 concurrent previews). Ports are allocated when a preview starts and released on cleanup. Stored in the `PreviewSession` record.

**Security**: Rathole's Noise protocol encrypts the tunnel. The `default_token` prevents unauthorized tunnel connections. Rails validates preview tokens before proxying.

#### Rails Reverse Proxy

A Rack middleware (or `ActionController::Live`-based controller) that forwards requests from `/previews/:token/*` to `localhost:<allocated-port>/*`:

```
GET /previews/abc123/issues/42
    ↓
1. Validate token abc123 → PreviewSession (active? authorized?)
2. Resolve tunnel port (e.g., 8201)
3. Forward to localhost:8201/issues/42
4. Response headers:
   - DELETE X-Frame-Options
   - REWRITE Content-Security-Policy (remove frame-ancestors)
   - REWRITE Location (prepend /previews/abc123)
5. Return modified response
```

**WebSocket handling**: The tunnel operates at TCP level, so WebSocket data passes through transparently. The Rails proxy detects HTTP 101 Switching Protocols responses and switches to bidirectional byte piping (Rack socket hijack). This is bounded (~50-80 lines of Ruby) because the tunnel already handles the network bridging — Rails only needs to pipe bytes between the client socket and the localhost tunnel socket.

**Header transformations**:

| Header | Action | Reason |
|--------|--------|--------|
| `X-Frame-Options` | Delete | Allow iframe embedding |
| `Content-Security-Policy: frame-ancestors` | Rewrite to `*` or remove directive | Allow iframe embedding |
| `Location` | Rewrite absolute/relative URLs to `/previews/:token/...` | Keep traffic through proxy |
| `Set-Cookie` domain | Rewrite to proxy origin | Cookie scoping |
| `X-Forwarded-Host` | Set to proxy origin | App-aware reverse proxy convention |

#### Phoenix/Elixir Detection

Add to four locations:

**1. `ContainerCapture#application_start_command`** — add Phoenix startup:

```ruby
elsif File.exist?(File.join(@tmpdir, "mix.exs"))
  "MIX_ENV=dev mix phx.server"
```

Phoenix reads `PORT` from env or config. Set `PORT=<port>` in the capture env to control the listening port.

**2. `Screenshots::FrameworkPatterns`** — add Phoenix UI file patterns:

```ruby
elixir: %w[
  lib/*_web/live/**
  lib/*_web/controllers/**
  lib/*_web/components/**
  lib/*_web/templates/**
  assets/js/**
  assets/css/**
]
```

**3. `Screenshots::DetectFramework`** — add `mix.exs` detection and Phoenix router parsing:

- Detect `mix.exs` with `phoenix` or `phoenix_live_view` in deps
- Parse `lib/*_web/router.ex` for `live`, `get`, `post`, `resources` macros to extract routes
- Detect services from `config/dev.exs` (database, Redis)
- Detect auth from `plugs` configuration

**4. Knowledge base route collection** — add Phoenix router parsing to the route collector so Phoenix routes appear in the knowledge base alongside Rails routes.

#### Preview Session Lifecycle

```
┌─────────────────────────────────────────────────────────┐
│                   Preview Session States                  │
│                                                          │
│  provisioning → starting → ready → active → expiring    │
│                                          → stopped       │
│                                          → failed        │
└─────────────────────────────────────────────────────────┘
```

- **provisioning**: Container allocated, code checked out, services provisioned
- **starting**: App startup command running, readiness probe polling
- **ready**: App responds, tunnel connected, proxy available
- **active**: User or agent is interacting with the preview
- **expiring**: TTL approaching (configurable, default 30 min). UI shows warning.
- **stopped**: TTL expired or manually stopped. Container + tunnel cleaned up.
- **failed**: Startup error, container crash, or tunnel failure.

**Shared sessions**: When an agent run completes, the preview session can transition from agent-only (browser connected via CDP, no human proxy) to shared (human proxy enabled, iframe available). This avoids provisioning a second container for human review.

**Cleanup**: Reuses existing patterns from `ContainerCapture#cleanup!` — stop and remove Chrome container, release service containers (reference-counted), stop and remove preview container, release tunnel port. A `PreviewSessionCleanupJob` (GoodJob) handles TTL expiration.

#### Playwright Trace Infrastructure

All Playwright-driven sessions (agent verification, screenshot capture, human preview scripted flows) record traces:

**Recording**: Tracing is controlled via the `context.tracing` API, not a `newContext` option:

```javascript
const context = await browser.newContext({
  viewport: config.viewport,
  recordVideo: { dir: "tmp/videos/" }  // optional: capture .webm video
});
await context.tracing.start({
  screenshots: true,
  snapshots: true,
  sources: true
});
// ... run interactions ...
await context.tracing.stop({ path: "tmp/trace.zip" });
```

**Artifacts from a Playwright session**:

| Artifact | How produced | Format | Use Case |
|----------|-------------|--------|----------|
| Trace file | `context.tracing.stop({ path })` | `.zip` | Interactive viewer embedded in iframe |
| Video | `recordVideo` dir on `newContext` | `.webm` | Demo reels, documentation |
| Animated GIF | Post-processing from video or trace (e.g., ffmpeg, `playwright-gif`) | `.gif` | PR comments (upgrade from static PNGs) |
| Step screenshots | Trace viewer export or `page.screenshot()` per step | `.png` | Before/after comparisons with interaction context |

The trace `.zip` is the primary artifact — it contains DOM snapshots, network requests, console logs, and screenshots at each step. Video requires enabling `recordVideo` on the context separately. Animated GIFs are derived from video or trace files via post-processing tooling (ffmpeg or a conversion library), not produced by Playwright directly.

**PR comment upgrade**: `Screenshots::PrComment` currently posts static before/after PNGs. With traces, it posts animated GIFs showing the interaction flow (e.g., form fill → submit → result page transition). The static PNG fallback remains for projects without trace support.

**Trace viewer**: The Playwright Trace Viewer is a static web app (`npx playwright show-trace trace.zip`). It can be served from S3 and embedded in an iframe in the Paid UI, allowing reviewers to scrub through the agent's interaction, inspect network requests, DOM snapshots, and console output at each step.

#### Agent Verification via playwright-mcp

**MCP server provisioning**: playwright-mcp is provisioned as an `npx` stdio server via `Containers::McpProvisioner`:

```json
{
  "name": "playwright-browser",
  "install_type": "npx",
  "command": "@executeautomation/playwright-mcp-server",
  "env": {
    "CDP_URL": "ws://paid-screenshot-browser:3000"
  }
}
```

The agent gets tools like `browser_navigate`, `browser_click`, `browser_fill`, `browser_screenshot`, `browser_get_text`, `browser_assert_visible`.

**Verification flow**:

1. Agent makes code changes in its container
2. Agent starts the dev server (e.g., `bin/rails server -b 0.0.0.0 -p 3000` or `mix phx.server`)
3. A browser container is provisioned on the same network (or reuses an existing selenium/chromium service container)
4. playwright-mcp connects to the browser via CDP
5. Agent navigates to `http://localhost:3000` (or the appropriate port)
6. Agent interacts with the app, verifies behavior, records a trace
7. Trace is uploaded for human review

This flow does not require the tunnel or Rails proxy — the agent and browser are on the same Docker network and communicate directly. The tunnel is only needed when a human needs to access the same app.

## Alternatives Considered

### 1. Browser-as-Preview (noVNC / browserless live view)

**Mechanism**: Run a browser in a container that navigates to the app. Stream the browser's screen to the user via noVNC (VNC over WebSocket).

**Pros**: Sidesteps HTTP/WebSocket proxying and iframe/CORS issues entirely. Universal — works for any app. Agents and humans share the same browser session.

**Cons**: Heavy (~2GB RAM per browser). Latency for human interaction (remote desktop feel). No direct URL access — user can only interact with what the browser shows. Not a "real" preview — user sees a browser viewing the app, not the app itself. Copy/paste and downloads may not work through noVNC.

**Rejected**: The Rails reverse proxy provides a native web experience at a fraction of the resource cost. noVNC is a fallback for non-web apps, not the primary path.

### 2. Playwright Trace Replay Only (no live preview)

**Mechanism**: Agent records Playwright traces during verification. User views traces in the trace viewer. No live app exposure.

**Pros**: Simplest to build — no tunnel, no proxy, no port exposure. Agent curates what the user sees. Works in all deployments with zero additional infrastructure.

**Cons**: Not interactive — user can only scrub through the agent's recording. User cannot explore beyond what the agent tested. No live feedback.

**Rejected as sole approach**: Trace replay is valuable as permanent infrastructure (included in this RDR) but insufficient as the only preview mechanism. Reviewers need to explore freely, not just rewatch the agent's path. Live preview and traces are complementary.

### 3. Direct Docker Port Publishing

**Mechanism**: Publish the container's port to the host via `docker run -p HOST_PORT:CONTAINER_PORT`.

**Pros**: Simplest possible mechanism. No proxy, no tunnel.

**Cons**: Does not work for remote Docker (port published on remote host, not where the user's browser is). Port conflicts for concurrent previews. Cannot strip iframe-blocking headers (apps would need per-app config changes). No auth layer. No same-origin iframe.

**Rejected**: Fails the "both environments" requirement and requires app changes.

### 4. Cloudflare Tunnel per Preview

**Mechanism**: Run `cloudflared tunnel` inside each preview container to create a public URL.

**Pros**: Handles HTTP + WebSocket natively. Very simple to configure. Automatic HTTPS.

**Cons**: External cloud dependency. Requires internet access from the preview container (not available on `paid_agent` restricted network). Public URLs are a security concern. Adds a third-party service to the critical path.

**Rejected**: Violates network isolation model for restricted runs. External dependency is unacceptable for a self-hosted platform.

## Trade-offs and Consequences

### Positive

- **Agents can self-verify interactively**: Instead of relying solely on tests and static screenshots, agents can start the app, click through flows, and observe runtime behavior before pushing. This catches visual and interaction bugs that tests miss.
- **Human reviewers get live, interactive previews**: Reviewers can test changes in a running app before merging, without cloning or running anything locally. Dramatically reduces the review feedback loop.
- **Phoenix/Elixir projects become first-class**: Framework detection, app startup, UI pattern matching, and route collection all support Phoenix LiveView. Projects like `color_matching` work out of the box.
- **Screenshots upgrade to animated content**: PR comments show animated GIFs of interaction flows instead of static PNGs. Traces provide full debugging context (network, DOM, console) for reviewers who want depth.
- **Demo videos for free**: Trace recordings can be exported as videos for documentation, onboarding, and feature showcases.
- **One infrastructure, multiple use cases**: Agent verification, human preview, enhanced screenshots, and demo generation all share the same container, browser, and Playwright infrastructure.

### Negative

- **Additional resource consumption**: Each active preview consumes a container (~2GB RAM for app + services) plus a browser container (~1-2GB). Concurrent previews are bounded by the port pool (100) but actual capacity depends on Docker host resources.
- **Rathole is a new dependency**: A new binary must be present in the preview container image and the Rails host. Version management and compatibility testing add maintenance overhead.
- **Rails proxy adds load**: All preview HTTP/WebSocket traffic flows through the Rails process. Under heavy concurrent preview usage, this could compete with Rails's normal request handling.
- **WebSocket proxy implementation complexity**: Rack socket hijacking for WebSocket passthrough is bounded (~50-80 lines) but requires careful testing across Phoenix LiveView, Action Cable, and plain WebSocket scenarios.

### Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Rathole connectivity failures (NAT, firewalls) | Health check on tunnel before marking preview "ready"; automatic retry; fallback to direct Docker DNS for local deployments |
| WebSocket proxy edge cases (non-standard protocols, compression) | Comprehensive integration tests against Phoenix LiveView and Action Cable; fallback to trace-only mode if live preview fails |
| Port pool exhaustion under high concurrency | Configurable pool size; queue previews when pool is full; TTL-based cleanup frees ports; monitoring/alerting on pool utilization |
| Preview container escapes isolation | Same hardened container image and network restrictions as agent containers (RDR-004); preview containers use the same `paid_agent`/`paid_internal` networks |
| Seed data in previews (mass assignment, sensitive data) | Seed data comes from repo-defined seeds only (`.paid/screenshots.yml`); no production data; per-run isolated databases (RDR-020) |
| iframe clickjacking via stripped headers | Preview URLs are token-authenticated and scoped to authorized users; tokens are random and expire; not a concern for authenticated preview sessions |

## Implementation Plan

### Prerequisites

- [ ] Rathole binary available in the preview container image (`docker/agent/Dockerfile`) and the Rails host
- [ ] Port pool configured (env var `PREVIEW_PORT_RANGE`, default `8200-8299`)
- [ ] Rathole server process managed alongside Rails (Procfile.dev entry or systemd unit)
- [ ] `rack-proxy` or custom Rack middleware for the reverse proxy
- [ ] Playwright available in the agent container for playwright-mcp

### Phase 1: Phoenix Detection + Playwright Traces

**Goal**: Make Phoenix projects work with the existing screenshot system, and upgrade screenshots to support trace recording.

#### Step 1: Add Phoenix/Elixir framework detection

Files modified:

- `app/services/screenshots/detect_framework.rb` — add `mix.exs` detection, Phoenix dep parsing, router.ex route extraction, dev.exs service detection
- `app/services/screenshots/framework_patterns.rb` — add Elixir UI file patterns
- `app/services/screenshots/container_capture.rb` — add `mix.exs` → `mix phx.server` in `application_start_command`

#### Step 2: Add Phoenix routes to knowledge base

Files modified:

- Knowledge base route collector — add `router.ex` parsing for `live`, `get`, `post`, `resources` macros

#### Step 3: Enable Playwright trace recording

Files modified:

- `app/services/screenshots/container_capture.rb` — add `trace: 'on'` to Playwright context config in `capture_runner_script`
- `app/services/screenshots/storage.rb` — add trace file upload alongside PNG upload
- `app/services/screenshots/pr_comment.rb` — add animated GIF generation from trace, post alongside or instead of static PNGs

#### Step 4: Add seed data support to ContainerCapture

Files modified:

- `app/services/screenshots/container_capture.rb` — remove the seed rejection at line 186; implement seed command execution using `Screenshots::SeedRunner`

### Phase 2: Agent Verification via playwright-mcp

**Goal**: Agents can start apps and verify changes interactively using playwright-mcp tools.

#### Step 5: Add playwright-mcp as a provisionable MCP server

Files created/modified:

- `app/services/containers/mcp_provisioner.rb` — no changes needed (npx servers already supported)
- Preview/verification MCP server definition — playwright-mcp with CDP URL env injection
- Agent container image (`docker/agent/Dockerfile`) — ensure Playwright browser binaries available or use browser container CDP

#### Step 6: Wire agent verification into the agent run flow

Files created/modified:

- `app/services/agent_runs/` — add verification step that starts the app, provisions a browser, and enables playwright-mcp
- Temporal activity — optional verification activity after code changes but before push

### Phase 3: Live Preview via Rathole + Rails Proxy

**Goal**: Human reviewers can interact with running web apps via iframe in the Paid UI.

#### Step 7: Install and configure rathole

Files created/modified:

- `docker/agent/Dockerfile` — add rathole binary
- `Procfile.dev` — add rathole server process
- `config/initializers/preview_tunnel.rb` — rathole server configuration, port pool initialization

#### Step 8: Create PreviewSession model and lifecycle

Files created/modified:

- `rails generate migration CreatePreviewSessions` — token, project_id, agent_run_id, branch_name, container_id, tunnel_port, status, expires_at
- `app/models/preview_session.rb` — lifecycle states, TTL, scope queries
- `app/jobs/preview_session_cleanup_job.rb` — TTL expiration, cleanup

#### Step 9: Implement preview provisioning service

Files created/modified:

- `app/services/previews/provision.rb` — extract shared app-starting logic from ContainerCapture; provision container, services, start app, start rathole client, wait for tunnel health
- `app/services/previews/tunnel_manager.rb` — port allocation, rathole client config generation, health checks

#### Step 10: Implement Rails reverse proxy

Files created/modified:

- `app/middleware/previews_proxy.rb` — Rack middleware: validate token, resolve tunnel port, forward HTTP, strip/rewrite headers, handle WebSocket upgrade via socket hijack
- `config/application.rb` — register middleware
- `app/controllers/previews_controller.rb` — UI endpoint: show iframe, preview metadata, lifecycle controls

#### Step 11: Add preview UI

Files created/modified:

- `app/views/projects/_preview.html.erb` — iframe embed, preview controls (start/stop/restart), TTL indicator
- `app/views/projects/show.html.erb` — preview tab/section
- `app/controllers/projects_controller.rb` — preview actions (start, stop, status)

### Phase 4: Trace Viewer + Demo Generation

**Goal**: Full trace viewer integration and demo video export.

#### Step 12: Trace viewer integration

Files created/modified:

- `app/services/previews/trace_viewer.rb` — serve trace viewer from S3, embed in iframe
- `app/views/projects/_trace_viewer.html.erb` — trace viewer iframe with scrubbing controls

#### Step 13: Demo video export

Files created/modified:

- `app/services/screenshots/trace_to_video.rb` — convert Playwright trace to `.webm` video
- `app/services/screenshots/trace_to_gif.rb` — convert Playwright trace to animated `.gif`

### Dependencies

- **rathole** — Rust binary, distributed as static binary (no runtime dependencies). Added to the agent Docker image and the Rails host.
- **rack-proxy** (or custom middleware) — Ruby gem for HTTP proxying. Alternatively, implement a thin middleware with `Net::HTTP` + Rack socket hijack.
- **Playwright** — already in `package.json` (`playwright@1.61.1`). Browser binaries may need to be installed in the agent container or accessed via CDP to the browser container.
- **playwright-mcp** — npm package, provisioned as an npx MCP server.

## Validation

### Test Scenarios

- **Phoenix LiveView preview**: Start a Phoenix app (e.g., `color_matching`) in a preview container, verify LiveView WebSocket connections work through the Rails proxy, verify iframe embedding without app changes
- **Rails Hotwire preview**: Start a Rails app with Turbo/Action Cable, verify WebSocket and SSE work through the proxy
- **Agent verification flow**: Agent starts app, uses playwright-mcp to navigate/click/fill/screenshot, records trace, trace is uploaded and viewable
- **Remote Docker preview**: Preview works when Docker daemon is on a remote host (rathole tunnel connects via `PAID_PROXY_EXTERNAL_URL`)
- **Concurrent previews**: Multiple previews run simultaneously with different ports, no interference
- **TTL cleanup**: Preview expires after configured TTL, container + tunnel + port are cleaned up
- **Animated GIF PR comment**: Trace from agent verification produces an animated GIF posted to the PR comment, replacing or augmenting static screenshots
- **Framework detection**: `mix.exs` with Phoenix deps → correct startup command (`mix phx.server`), correct UI patterns, routes extracted from `router.ex`
- **Header stripping**: App sends `X-Frame-Options: DENY` → proxy strips it → iframe renders successfully
- **Redirect rewriting**: App issues `Location: /issues/42` → proxy rewrites to `/previews/:token/issues/42` → browser stays within proxy

### Performance Validation

- Preview startup time: < 90 seconds (matching ContainerCapture's `STARTUP_TIMEOUT_SECONDS`)
- Tunnel latency overhead: < 50ms per request (rathole benchmarks show sub-millisecond overhead)
- Concurrent preview capacity: 10+ simultaneous previews on a single Docker host with 32GB RAM
- Rails proxy overhead: < 10ms per request (localhost forwarding, no network hop)

### Security Validation

- Preview tokens are random (32+ chars) and expire automatically
- Preview containers use the same hardened image and network restrictions as agent containers
- Rathole tunnel is encrypted (Noise protocol)
- Seed data comes from repo-defined configuration only, never production data
- Preview access requires project membership authorization

## References

### Dependencies

- [rathole](https://github.com/rapiz1/rathole) — Rust-based reverse proxy tunnel
- [Playwright](https://playwright.dev/) — Browser automation and trace recording
- [Playwright Trace Viewer](https://playwright.dev/docs/trace-viewer) — Interactive trace inspection
- [browserless/chromium](https://github.com/browserless/chromium) — Headless Chrome container with CDP

### Related RDRs

- [RDR-004](RDR-004-container-isolation.md) — Container isolation strategy (preview containers inherit hardening)
- [RDR-006](RDR-006-secrets-proxy.md) — Secrets proxy (same outbound network direction as the tunnel)
- [RDR-019](RDR-019-remote-container-execution.md) — Remote container execution (tunnel solves the reverse-direction gap)
- [RDR-020](RDR-020-service-container-architecture.md) — Service containers (preview reuses service provisioning)
- [RDR-028](RDR-028-interactive-chat.md) — Interactive chat (playwright-mcp extends the MCP tool registry)
