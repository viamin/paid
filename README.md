# Paid - Platform for AI Development

Paid is a Rails 8 application that orchestrates AI agents to build software. Users add GitHub projects, and Paid watches for labeled issues, plans implementations, and runs agents in isolated Docker containers to create pull requests.

Phase 4 (AI-Native Evolution) is complete as of 2026-05-14. The app now logs orchestration decisions for analysis, evolves orchestration strategies and coordination policies through experiments, optimizes end-to-end configuration bundles, and applies measured orchestration scaling laws in addition to the Phase 3 and 3.5 platform work.

## Philosophy

Paid stores every decision point as data—prompts, model preferences, workflow patterns—rather than hardcoding assumptions. This allows the system to evolve through measurement and A/B testing rather than relying on intuition alone. See [VISION.md](docs/VISION.md) for our full philosophy.

## Key Features

- **GitHub Integration**: Add projects via PAT, watch for labeled issues
- **Temporal Workflows**: Durable, observable orchestration of agent activities
- **Container Isolation**: Agents run in sandboxed Docker containers. Proxy-mode runs use the restricted `paid_agent` network with no default internet access; subscription-auth and direct-outbound provider runs use `paid_internal` so provider CLIs can reach upstream APIs directly.
- **Multiple Agents and Providers**: Support for Claude Code, Codex, Cursor, Gemini, OpenCode, Kilocode, Pi, and Copilot when the runtime is both supported by `agent-harness` and installed in `paid-agent`
  - Gap: broader runtime parity is tracked by provider metadata and smoke-test refactors ([#798](https://github.com/viamin/paid/issues/798), [#796](https://github.com/viamin/paid/issues/796)) plus agent-image install delegation work ([#789](https://github.com/viamin/paid/issues/789)-[#795](https://github.com/viamin/paid/issues/795)).
- **Secrets Proxy**: Git credentials, default platform LLM keys, and stored provider API-key auth for proxy-compatible agent CLIs are proxied through authenticated endpoints
  - Caveat: subscription auth intentionally copies CLI login state into the agent runtime, and direct-outbound OpenCode/KiloCode API-key providers still place provider credentials in runtime config because they can target non-proxied upstream APIs. Knowledge-side direct key usage is tracked by [#1043](https://github.com/viamin/paid/issues/1043) and [#1044](https://github.com/viamin/paid/issues/1044).
- **Human-in-the-Loop**: All changes go through PRs; humans approve merges (can be automated if desired)
- **Full Automation or Manual Control**: Auto-pick next issue or trigger runs manually from the UI
- **Prompt Management**: Version prompts as data, diff versions, and manage A/B tests before promoting prompt changes
  - Gap: live agent-run A/B assignment is not wired into execution yet; tracked by [#1267](https://github.com/viamin/paid/issues/1267).
- **Knowledge Base**: Index repos into PostgreSQL + Qdrant for hybrid exact/semantic search and richer prompt context
  - Gap: some goal and prompt paths still need knowledge injection or container-accessible search; tracked by [#1265](https://github.com/viamin/paid/issues/1265) and [#1272](https://github.com/viamin/paid/issues/1272).
- **Live Dashboards**: Track active runs, performance, quality, cost, and knowledge-collection health from the UI
- **MCP Server Support**: Configure MCP (Model Context Protocol) servers per project so agents can use external tools during execution. Both npx-based and docker-image sidecar servers are supported. Paid also exposes its own operations as MCP tools for the chat interface.
- **Interactive Chat**: Conversational interface with real-time streaming (SSE), project context injection, cost tracking, and container workspace sessions
- **Screenshot Visual Regression**: Automatically capture and display rendered screenshots in PR comments when UI changes are detected
- **Self-Healing Exception Handling**: Centralized exception pipeline that fingerprints, classifies, deduplicates, and auto-files GitHub issues for P1/P2 errors
- **Notification Subscriptions**: Subscribe to individual issue and PR merge events with real-time Turbo Stream delivery
- **Provider and Integration Management**: Test provider auth from the UI and manage GitHub, Linear, provider API keys, and generic integration credentials (GitLab, Jira, Azure DevOps, signing) for account admins
- **Service Containers**: Attach approved supporting services like Postgres, Redis, or Selenium to project runs when agents need dependencies beyond the app code. Service containers are attached to the same Docker network selected for the agent run across proxy-mode, subscription-auth, and direct-outbound provider runs. Shared-database isolation fallout is tracked separately by [#1280](https://github.com/viamin/paid/issues/1280).

## How It Works

1. User adds a GitHub project with a Personal Access Token
2. Paid polls the repo for open issues and PRs, then evaluates the project's configured `label_mappings` (and automation labels) to decide whether an item should trigger agent work
3. An `AgentExecutionWorkflow` starts in Temporal, orchestrating:
   - Prompt resolution, provider selection, and project policy checks
   - Knowledge-base retrieval and style-guide injection when available
   - Docker container provisioning on the network selected for the provider auth mode
   - MCP server provisioning (npx or docker sidecar) when configured for the project
   - Repository clone and branch creation inside the container
   - Agent execution (e.g., Claude Code) with the issue as prompt
   - Branch push, PR creation (with optional screenshot attachments for UI changes), issue update, and optional review follow-up
4. User reviews and merges the PR

## GitHub Labels

Paid uses GitHub labels to trigger workflows and communicate status. Some labels are system-managed (Paid adds/removes them automatically), while others are user-configurable per project.

### Labels Paid Adds

| Label | Applied To | When | Purpose |
| ----- | ---------- | ---- | ------- |
| `paid-generated` | PRs, Issues | Agent creates a PR or issue | Identifies agent-generated content; enables PR follow-up scanning |
| `paid-ready` | PRs | Draft review passes and PR is ready for owner review | Signals the PR is ready for human review |
| `paid-escalated` | PRs | Draft review round limit exceeded | Signals owner intervention is needed |

### Labels Paid Responds To

These are **configurable per project** via `label_mappings` in project settings. There is no global default: if no `label_mappings` are configured for a project, Paid will not trigger agent work from issue labels.

| Mapping | Example label | Behavior |
| ------- | ------------- | -------- |
| Build label | `paid-build` | Triggers agent execution on a new issue (creates a PR) |
| Plan label | `paid-plan` | Starts planning phase on a new issue (no immediate agent run) |

Issues with unsatisfied [dependencies](#issue-dependencies) are not triggered even if the label is present. They are re-evaluated each poll cycle until all dependencies are closed.

**PR action labels** can also be configured per project (`pr_action_labels`). When an action label is detected on a `paid-generated` PR, Paid triggers a follow-up agent run and removes the label.

### Labels That Affect Auto-Pick

When auto-pick is enabled for a project, Paid automatically selects the next eligible issue to work on. Issues with any of these labels are skipped:

| Label | Effect |
| ----- | ------ |
| `planning` | Skipped by auto-pick |
| `research` | Skipped by auto-pick |
| `waiting` | Skipped by auto-pick |

### Issue Dependencies

Paid parses issue bodies for dependency declarations and builds a dependency tree. Issues with open (unsatisfied) dependencies are not picked up by auto-pick or label-triggered workflows.

Supported formats in issue bodies:

```markdown
## Dependencies

- #101
- #102

Depends on #101, #102
Blocked by #103
```

## Quick Start

### Option 1: Docker Compose (recommended)

```bash
# Clone and configure
git clone <repo-url> && cd paid
# Optional: copy .env.example for local reference or if you add `env_file: .env`
cp .env.example .env

# Start the full dev stack
docker compose up --build

# On first boot, wait for the web service to finish `bin/setup`
# before using the app. `bin/setup` already runs `bin/rails db:prepare`.
```

> **Note**: By default, the checked-in `docker-compose.yml` starts `postgres`, `redis`, `temporal`, `temporal-admin-tools`, `temporal-ui`, `qdrant`, `web`, and `worker` when you run `docker compose up --build`. The compose file wires `DATABASE_URL`, `REDIS_URL`, Temporal, and Qdrant for the app so development-only dashboards such as `rails_performance` work out of the box. The `agent-test` service is profile-gated, so it only starts when its profile is explicitly enabled. Build `paid-agent:latest` with `./scripts/build-agent-image.sh`; that script extracts the Dockerfile build args from `Gemfile.lock` and `agent-harness`. `ANTHROPIC_API_KEY` is passed through today; if you want proxy-based OpenAI or Google auth in Compose, add `OPENAI_API_KEY` and/or `GOOGLE_API_KEY` to the `web` service, and to `worker` as well if you want worker-side flows to see them.

**Database role note**: Compose creates the Rails `paid` role separately from the PostgreSQL admin role so tenant row-level security cannot be bypassed by a superuser connection. If you have an older `postgres-data` volume where `paid` was the bootstrap superuser, recreate that volume before running this branch.

### Option 2: Dev Container

Open in VS Code with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension, or use GitHub Codespaces. The `.devcontainer/` configuration provides a complete development environment.

The checked-in devcontainer also applies conservative `TEMPORAL_*`, `GOOD_JOB_*`, and `DB_POOL` defaults so `bin/dev` stays stable under normal development load.

#### Enable Commit Signing in Dev Container

If commit signing is not configured automatically, run:

```bash
bash .devcontainer/enable-commit-signing.sh
```

This script will:

1. Authenticate GitHub CLI if needed (`gh auth login -h github.com`)
2. Request the required `admin:ssh_signing_key` scope
3. Create/register a container-local SSH signing key
4. Configure repo-local git signing settings

If you prefer to run commands manually:

```bash
gh auth login -h github.com
gh auth refresh -h github.com -s admin:ssh_signing_key
bash .devcontainer/setup-signing-key.sh
```

### Option 3: Local Development

```bash
# Prerequisites: Ruby 3.4+, Bundler 4.0.14, PostgreSQL 16+, Redis 7+, Node.js 22.x (see .tool-versions for the exact pinned version), Yarn 1.22.22, Docker Engine
# Also start PostgreSQL, Redis, Temporal, and Qdrant locally before running setup.
bin/setup               # Install deps, prepare DB
bin/dev                 # Start Rails, JS/CSS watchers, GoodJob, and the split Temporal poll/agent workers
```

`bin/setup` now does more than install Ruby and JS dependencies: it configures git hooks, prepares the database, checks Qdrant connectivity, builds the `paid-agent:latest` Docker image, and cleans up stale dev state. If Docker is unavailable, setup is incomplete.

### Access Points

| Service | URL | Description |
| ------- | --- | ----------- |
| Rails app | <http://localhost:3000> | Main application |
| Temporal UI | <http://localhost:8080> | Workflow monitoring |
| PostgreSQL | localhost:5432 | Database (app user: paid, password: paid; admin user: paid_admin) |
| Temporal gRPC | localhost:7233 | Temporal server |
| Qdrant | <http://localhost:6333> | Vector store for semantic knowledge search |

### First-Time Setup

1. Sign up at <http://localhost:3000>
2. Add a GitHub token (Settings > GitHub Tokens) with `repo` scope
3. Add a project (Projects > New) by entering the GitHub repo URL
4. Configure build/plan label mappings in project settings (e.g., `paid-build`), then label a GitHub issue to trigger an agent run, or use the "Trigger Run" button in the UI

## Environment Variables

### Required

| Variable | Description | Default |
| -------- | ----------- | ------- |
| `DATABASE_URL` | PostgreSQL connection string | `postgres://paid:paid@localhost:5432/paid_development` |
| `ANTHROPIC_API_KEY` | Anthropic API key for agent execution | _(none)_ |

### Optional

| Variable | Description | Default |
| -------- | ----------- | ------- |
| `RAILS_ENV` | Rails environment | `development` |
| `TEMPORAL_HOST` | Temporal server address | `localhost:7233` |
| `TEMPORAL_ADDRESS` | Temporal address (alternative to TEMPORAL_HOST) | _(falls back to TEMPORAL_HOST)_ |
| `TEMPORAL_NAMESPACE` | Temporal namespace | `default` |
| `TEMPORAL_WORKER_MODE` | Which worker set `bin/temporal_worker` boots (`poll`, `agent`, or `both`) | `both` |
| `TEMPORAL_POLL_TASK_QUEUE` | Temporal poll workflow task queue | `paid-poll-tasks` |
| `TEMPORAL_AGENT_TASK_QUEUE` | Temporal agent execution task queue | `paid-agent-tasks` |
| `TEMPORAL_UI_URL` | Temporal UI base URL for monitoring links | `http://localhost:8080` |
| `REDIS_URL` | Redis endpoint used by development features such as `rails_performance` | `redis://localhost:6379/0` |
| `OPENAI_API_KEY` | OpenAI API key (for agents that use OpenAI) | _(none)_ |
| `GOOGLE_API_KEY` | Google API key for Gemini proxy requests | _(none)_ |
| `QDRANT_URL` | Qdrant REST endpoint for knowledge search | `http://localhost:6333` |
| `QDRANT_API_KEY` | Qdrant API key — **required in production** (set via Rails credentials `qdrant.api_key` or this env var; credentials take precedence) | _(none; raises in production if unset)_ |
| `AGENT_TIMEOUT` | Agent execution timeout in seconds | `3600` |
| `CLAUDE_CONFIG_DIR` | Host path to `~/.claude/` for Claude Code subscription auth | _(none)_ |
| `CODEX_CONFIG_DIR` | Host path to `~/.codex/` for Codex subscription auth | _(none)_ |
| `CODEX_HOME` | Alternate Codex config root if `CODEX_CONFIG_DIR` is not set | _(none)_ |
| `GEMINI_CONFIG_DIR` | Host path to `~/.gemini/` for Gemini subscription auth | _(none)_ |
| `PAID_PROXY_PORT` | Port the secrets proxy listens on (used by agent containers) | `3000` |
| `PAID_DATABASE_PASSWORD` | Production database password | _(none)_ |

## Provider Auth Setup

By default, provider tests and real agent runs use the same containerized auth path. For Codex and Gemini, when a Paid-managed proxy key is configured on the `web` service, Test Agent can instead use the agent-harness auth path for faster validation. Each provider can usually be configured in one of two ways:

1. Paid-managed proxy auth using an API key on the `web` service.
2. Stored provider API-key auth using an API key saved in Paid. For Claude, Codex, Gemini, and Cursor agent runs, Paid keeps the stored key server-side and routes provider calls through the secrets proxy.
3. Subscription auth using local CLI login state that Paid copies into the agent container.

OpenCode and KiloCode direct-outbound API-key entries are the exception: Paid writes their runtime provider config inside the agent container because those tools can target upstream APIs that the secrets proxy does not cover.

### Claude

- Proxy auth: set `ANTHROPIC_API_KEY` on the `web` service.
- Subscription auth: run `claude login` on the host or devcontainer and make `~/.claude/.credentials.json` visible to Paid.
- If Claude credentials live outside the default location, set `CLAUDE_CONFIG_DIR` to the directory containing `.credentials.json`.

### Codex and OpenCode

- Proxy auth: set `OPENAI_API_KEY` on the `web` service.
- Subscription auth: sign in with the Codex CLI and make `~/.codex/auth.json` visible to Paid.
- If Codex credentials live outside the default location, set `CODEX_CONFIG_DIR` or `CODEX_HOME`.
- OpenCode uses the same OpenAI proxy key path and does not currently have a separate subscription-auth mount in Paid.

### Gemini

- Proxy auth: set `GOOGLE_API_KEY` on the `web` service.
- Subscription auth: run `gemini auth login` and make `~/.gemini/oauth_creds.json` visible to Paid.
- If Gemini credentials live outside the default location, set `GEMINI_CONFIG_DIR`.

### After Updating Auth

- Restart the `web` and `worker` services so new env vars and credential mounts are picked up.
- Re-run `Test Agent` from the Providers page.
- In Docker Compose, adding a variable to `.env` is not enough by itself unless the compose service actually passes it through.
- If a provider still fails, compare the error with the expected file/env setup above:
  - `API key not configured for google` means `GOOGLE_API_KEY` is missing on `web`.
  - `API key not configured for openai` means `OPENAI_API_KEY` is missing on `web` for Codex or OpenCode.
  - `No authentication token found` usually means the provider CLI login files are not mounted where Paid expects them.

## Docker Compose Services

| Service | Port | Description |
| ------- | ---- | ----------- |
| `web` | 3000 | Rails application server |
| `postgres` | 5432 | PostgreSQL database |
| `redis` | 6379 | Redis for development-only metrics and dashboards |
| `temporal` | 7233 | Temporal server (gRPC) |
| `temporal-ui` | 8080 | Temporal web interface |
| `qdrant` | 6333 | Vector database for semantic knowledge search |
| `temporal-admin-tools` | - | CLI tools for Temporal administration |
| `worker` | - | Temporal worker process (executes workflows) |
| `agent-image` | - | Legacy setup profile; use `./scripts/build-agent-image.sh` for supported agent image builds |
| `agent-test` | - | Agent container for testing the image (`test` profile only) |

### Networks

- **paid_internal**: Infrastructure services (Rails, Temporal, Postgres) and agent runs that require direct provider egress, including subscription-auth and direct-outbound provider modes.
- **paid_agent**: Restricted network for proxy-mode agent containers (`internal: true`, no default internet access). Allowed egress is enforced via iptables.

### Temporal CLI Access

```bash
docker compose exec temporal-admin-tools bash
temporal operator namespace list
```

## Development Commands

```bash
# Setup
bin/setup                    # Install deps, prepare DB, start server
bin/setup --skip-server      # Setup without starting server
bin/setup --reset            # Setup with database reset
bin/update                   # Update supported pinned tool binaries (`--lockfiles` to also update Ruby/Yarn deps)

# Development
bin/dev                      # Start dev server with Overmind (Rails + JS + CSS + split Temporal poll/agent workers)
bin/rails server             # Start Rails server only
bin/rails console            # Rails console
bin/temporal_worker          # Run the Temporal worker directly (`TEMPORAL_WORKER_MODE=poll|agent|both`; default is `both`)
bin/dev-update --lightweight # Pull latest main without restarting the dev stack
bin/dev-update --full        # Pull latest main, rerun setup, and restart the dev stack

# Testing
bin/rspec                    # Run the full RSpec test suite

# Code Quality
bin/rubocop                  # Run RuboCop linter
bin/rubocop -a               # Auto-fix violations
bin/lint                     # Run all linters (RuboCop, ESLint, markdownlint, ShellCheck)
bin/lint --changed           # Lint changed files only
bin/lint --staged            # Lint staged files only
bin/lint -A                  # Run all linters with auto-fix

# Security
bin/audit                    # Run Brakeman, bundler-audit, and yarn audit
bin/brakeman                 # Static security analysis
bin/bundler-audit            # Gem vulnerability audit
yarn audit                   # JavaScript dependency audit

# CI helper
bin/ci                       # Runs setup, lint, and security audit
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Rails App (3000)                        │
│   Controllers ─── Services ─── Models ─── Views (ERB/Hotwire)  │
│        │              │            │                            │
│   Auth (Devise)  GitHub Client  PostgreSQL + Qdrant            │
│   Authz (Pundit) Container Mgmt  Encrypted tokens              │
│   Prompts / A-B tests  Dashboards  Knowledge Search            │
└────────────┬───────────┬────────────────────────────────────────┘
             │           │
┌────────────▼───────────▼────────────────────────────────────────┐
│                    Temporal (7233)                               │
│   GitHubPollWorkflow ──► AgentExecutionWorkflow                 │
│   (long-running)         (per-issue lifecycle)                  │
│                          1. Create AgentRun                     │
│                          2. Resolve prompt/provider/context     │
│                          3. Provision Container                 │
│                          4. Clone Repo & Create Branch          │
│                          5. Run Agent                           │
│                          6. Push Branch                         │
│                          7. Create PR / follow-up               │
└────────────────────────────┬────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────┐
│        Docker Containers (paid_agent or paid_internal)           │
│   Agent CLI (Claude, Codex, Cursor, Gemini, ...)                 │
│   ── Proxy mode: Secrets Proxy ──► Provider APIs                │
│   ── Subscription/direct outbound: HTTPS to Provider APIs        │
│   ── Git Credential Proxy ──► GitHub                            │
│   ── Optional service containers (Postgres/Redis/Selenium)      │
│   ── No default internet access only on paid_agent              │
└─────────────────────────────────────────────────────────────────┘
```

## Documentation

| Document | Description |
| -------- | ----------- |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Development setup, code style, submitting PRs |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture and technology stack |
| [ROADMAP.md](docs/ROADMAP.md) | Phased implementation plan |
| [db/schema.rb](db/schema.rb) | Canonical database schema with PostgreSQL table and column comments |
| [AGENT_SYSTEM.md](docs/AGENT_SYSTEM.md) | Agent execution and Temporal workflows |
| [KNOWLEDGE_BASE.md](docs/KNOWLEDGE_BASE.md) | Knowledge collection, embeddings, and hybrid search |
| [SECURITY.md](docs/SECURITY.md) | Security model and container isolation |
| [DEBUGGING_CONTAINERS.md](docs/DEBUGGING_CONTAINERS.md) | Container debugging and operational troubleshooting |
| [LLM_STYLE_GUIDE.md](docs/LLM_STYLE_GUIDE.md) | Concise AI-assistant implementation guidance |
| [STYLE_GUIDE.md](docs/STYLE_GUIDE.md) | Coding standards for developing Paid |
| [RDRs](docs/rdrs/README.md) | Recommendation Decision Records |
| [VISION.md](docs/VISION.md) | Philosophy, principles, and goals |
| [PROMPT_EVOLUTION.md](docs/PROMPT_EVOLUTION.md) | Prompt versioning and A/B testing |
| [OBSERVABILITY.md](docs/OBSERVABILITY.md) | Metrics, logging, dashboards, and alerting |

## Inspiration

Paid is inspired by [aidp](https://github.com/viamin/aidp), a CLI tool for AI-driven development. Key concepts borrowed include watch mode, provider abstraction, git worktrees, and style guide compression.

## Status

Phase 4 (AI-Native Evolution) is complete as of 2026-05-14. Phase 5 (Account Administration) is complete as of 2026-05-20, and Phase 6 (Enterprise Trust & Governance) is next. Paid now includes orchestration decision logging, learned strategy evolution, end-to-end bundle optimization, self-improving coordination policies, orchestration scaling-law analysis, and both operator-facing plus customer-facing account administration on top of the completed Phase 1-3.5 platform capabilities. See [ROADMAP.md](docs/ROADMAP.md) for the current implementation phases.

## License

TBD
