# Paid - Platform for AI Development

Paid is a Rails 8 application that orchestrates AI agents to build software. Users add GitHub projects, and Paid watches for labeled issues, plans implementations, and runs agents in isolated Docker containers to create pull requests.

Phase 2 (Intelligence) is complete as of 2026-04-01. The app now includes prompt versioning and A/B tests, model selection, semantic code search, quality and cost dashboards, provider management, and service-container support in addition to the original issue-to-PR workflow.

## Philosophy

Paid stores every decision point as data—prompts, model preferences, workflow patterns—rather than hardcoding assumptions. This allows the system to evolve through measurement and A/B testing rather than relying on intuition alone. See [VISION.md](docs/VISION.md) for our full philosophy.

## Key Features

- **GitHub Integration**: Add projects via PAT, watch for labeled issues
- **Temporal Workflows**: Durable, observable orchestration of agent activities
- **Container Isolation**: Agents run in sandboxed Docker containers with no default internet access
- **Multiple Agents and Providers**: Support for Claude Code, Codex, Cursor, Gemini, Aider, OpenCode, Kilocode, Copilot, and other `agent-harness`-supported runtimes
- **Secrets Proxy**: API keys and git credentials never enter agent containers; proxied through authenticated endpoints
- **Human-in-the-Loop**: All changes go through PRs; humans approve merges (can be automated if desired)
- **Full Automation or Manual Control**: Auto-pick next issue or trigger runs manually from the UI
- **Prompt Management**: Version prompts as data, diff versions, and run A/B tests before promoting prompt changes
- **Knowledge Base**: Index repos into PostgreSQL + Qdrant for hybrid exact/semantic search and richer prompt context
- **Live Dashboards**: Track active runs, performance, quality, cost, and knowledge-collection health from the UI
- **Provider and Integration Management**: Test provider auth from the UI and manage GitHub, Linear, provider API keys, and generic integration credentials
- **Service Containers**: Attach approved supporting services like Postgres, Redis, or Selenium to project runs when agents need dependencies beyond the app code

## How It Works

1. User adds a GitHub project with a Personal Access Token
2. Paid polls the repo for issues matching the project's configured `label_mappings` (if no mappings are configured, all open issues are fetched)
3. An `AgentExecutionWorkflow` starts in Temporal, orchestrating:
   - Prompt resolution, provider selection, and project policy checks
   - Knowledge-base retrieval and style-guide injection when available
   - Docker container provisioning on a restricted network
   - Repository clone and branch creation inside the container
   - Agent execution (e.g., Claude Code) with the issue as prompt
   - Branch push, PR creation, issue update, and optional review follow-up
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

> **Note**: By default, the checked-in `docker-compose.yml` starts `postgres`, `temporal`, `temporal-admin-tools`, `temporal-ui`, `qdrant`, `web`, and `worker` when you run `docker compose up --build`. The `agent-image` and `agent-test` services are profile-gated, so they only start when their profiles are explicitly enabled. The compose file already wires `DATABASE_URL`, Temporal, and Qdrant for the app. `ANTHROPIC_API_KEY` is passed through today; if you want proxy-based OpenAI or Google auth in Compose, add `OPENAI_API_KEY` and/or `GOOGLE_API_KEY` to the `web` service, and to `worker` as well if you want worker-side flows to see them.

### Option 2: Dev Container

Open in VS Code with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension, or use GitHub Codespaces. The `.devcontainer/` configuration provides a complete development environment.

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
# Prerequisites: Ruby 3.4+, Bundler 2.7.2, PostgreSQL 16+, Node.js 22.x (see .tool-versions for the exact pinned version), Yarn 1.22.22, Docker Engine
# Also start PostgreSQL, Temporal, and Qdrant locally before running setup.
bin/setup               # Install deps, prepare DB
bin/dev                 # Start Rails, JS/CSS watchers, and the Temporal worker
```

`bin/setup` now does more than install Ruby and JS dependencies: it configures git hooks, prepares the database, checks Qdrant connectivity, builds the `paid-agent:latest` Docker image, and cleans up stale dev state. If Docker is unavailable, setup is incomplete.

### Access Points

| Service | URL | Description |
| ------- | --- | ----------- |
| Rails app | <http://localhost:3000> | Main application |
| Temporal UI | <http://localhost:8080> | Workflow monitoring |
| PostgreSQL | localhost:5432 | Database (user: paid, password: paid) |
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
| `TEMPORAL_TASK_QUEUE` | Temporal task queue name | `paid-tasks` |
| `TEMPORAL_UI_URL` | Temporal UI base URL for monitoring links | `http://localhost:8080` |
| `OPENAI_API_KEY` | OpenAI API key (for agents that use OpenAI) | _(none)_ |
| `GOOGLE_API_KEY` | Google API key for Gemini proxy requests | _(none)_ |
| `QDRANT_URL` | Qdrant REST endpoint for knowledge search | `http://localhost:6333` |
| `QDRANT_API_KEY` | Optional Qdrant API key | _(none)_ |
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
2. Subscription auth using local CLI login state that Paid copies into the agent container.

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
| `temporal` | 7233 | Temporal server (gRPC) |
| `temporal-ui` | 8080 | Temporal web interface |
| `qdrant` | 6333 | Vector database for semantic knowledge search |
| `temporal-admin-tools` | - | CLI tools for Temporal administration |
| `worker` | - | Temporal worker process (executes workflows) |
| `agent-image` | - | Builds the `paid-agent:latest` image (`setup` profile, exits immediately) |
| `agent-test` | - | Agent container for testing the image (`test` profile only) |

### Networks

- **paid_internal**: Infrastructure services (Rails, Temporal, Postgres)
- **paid_agent**: Restricted network for agent containers (`internal: true`, no default internet access). Allowed egress enforced via iptables.

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
bin/update                   # Update Ruby, Yarn, and supported Dockerfile-pinned deps

# Development
bin/dev                      # Start dev server with Overmind (Rails + JS + CSS + Temporal worker)
bin/rails server             # Start Rails server only
bin/rails console            # Rails console
bin/temporal_worker          # Run the Temporal worker directly
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
│                  Docker Containers (paid_agent network)          │
│   Agent CLI (Claude, Codex, Cursor, Gemini, Aider, ...)         │
│   ── Secrets Proxy ──► Anthropic/OpenAI APIs                    │
│   ── Git Credential Proxy ──► GitHub                            │
│   ── Optional service containers (Postgres/Redis/Selenium)      │
│   ── No default internet access                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Documentation

| Document | Description |
| -------- | ----------- |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Development setup, code style, submitting PRs |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture and technology stack |
| [ROADMAP.md](docs/ROADMAP.md) | Phased implementation plan |
| [DATA_MODEL.md](docs/DATA_MODEL.md) | Database schema, accounts, and RBAC |
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

Phase 2 (Intelligence) is complete. Phase 3 (Scale) is next. See [ROADMAP.md](docs/ROADMAP.md) for the current implementation phases.

## License

TBD
