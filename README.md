# Paid - Platform for AI Development

Paid is a Rails 8 application that orchestrates AI agents to build software. Users add GitHub projects, and Paid watches for labeled issues, plans implementations, and runs agents in isolated Docker containers to create pull requests.

## Philosophy

> "Configuration is ephemeral, but data endures."

Paid stores every decision point as data—prompts, model preferences, workflow patterns—rather than hardcoding assumptions. This allows the system to evolve through measurement and A/B testing rather than relying on intuition alone. See [VISION.md](docs/VISION.md) for our full philosophy.

## Key Features

- **GitHub Integration**: Add projects via PAT, watch for labeled issues
- **Temporal Workflows**: Durable, observable orchestration of agent activities
- **Container Isolation**: Agents run in sandboxed Docker containers with no default internet access
- **Multiple Agents**: Support for Claude Code, Cursor, Aider (via agent-harness gem)
- **Secrets Proxy**: API keys never enter agent containers; proxied through authenticated endpoint
- **Human-in-the-Loop**: All changes go through PRs; humans approve merges

## How It Works

1. User adds a GitHub project with a Personal Access Token
2. Paid polls the repo for issues labeled `paid-build`
3. An `AgentExecutionWorkflow` starts in Temporal, orchestrating:
   - Git worktree creation for isolated workspace
   - Docker container provisioning on a restricted network
   - Agent execution (e.g., Claude Code) with the issue as prompt
   - Branch push, PR creation, and issue update
4. User reviews and merges the PR

## Quick Start

### Option 1: Docker Compose (recommended)

```bash
# Clone and configure
git clone <repo-url> && cd paid
cp .env.example .env

# Start all services
docker compose up

# In another terminal, setup the database
docker compose exec web bin/rails db:prepare
```

> **Note**: Docker Compose sets `DATABASE_URL`, `TEMPORAL_HOST`, and `RAILS_ENV` directly in `docker-compose.yml`. Additional variables like `ANTHROPIC_API_KEY` (needed for agent execution) must be added to the `environment` section of the `web` and `worker` services, or loaded via `env_file: .env` in `docker-compose.yml`.

### Option 2: Dev Container

Open in VS Code with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension, or use GitHub Codespaces. The `.devcontainer/` configuration provides a complete development environment.

### Option 3: Local Development

```bash
# Prerequisites: Ruby 3.4+, PostgreSQL 16+, Node.js 20+, Yarn
bin/setup               # Install deps, prepare DB
bin/dev                 # Start dev server (Rails + JS + CSS watchers)
```

### Access Points

| Service | URL | Description |
| ------- | --- | ----------- |
| Rails app | <http://localhost:3000> | Main application |
| Temporal UI | <http://localhost:8080> | Workflow monitoring |
| PostgreSQL | localhost:5432 | Database (user: paid, password: paid) |
| Temporal gRPC | localhost:7233 | Temporal server |

### First-Time Setup

1. Sign up at <http://localhost:3000>
2. Add a GitHub token (Settings > GitHub Tokens) with `repo` scope
3. Add a project (Projects > New) by entering the GitHub repo URL
4. Label a GitHub issue with `paid-build` to trigger an agent run, or use the "Trigger Run" button in the UI

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
| `AGENT_TIMEOUT` | Agent execution timeout in seconds | `600` |
| `CURSOR_ENABLED` | Enable Cursor agent provider | `false` |
| `AIDER_ENABLED` | Enable Aider agent provider | `false` |
| `PAID_DATABASE_PASSWORD` | Production database password | _(none)_ |

## Docker Compose Services

| Service | Port | Description |
| ------- | ---- | ----------- |
| `web` | 3000 | Rails application server |
| `postgres` | 5432 | PostgreSQL database |
| `temporal` | 7233 | Temporal server (gRPC) |
| `temporal-ui` | 8080 | Temporal web interface |
| `temporal-admin-tools` | - | CLI tools for Temporal administration |
| `worker` | - | Temporal worker process (executes workflows) |
| `agent-test` | - | Agent container for testing (test profile only) |

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

# Development
bin/dev                      # Start dev server with Foreman
bin/rails server             # Start Rails server only
bin/rails console            # Rails console

# Testing
bin/rspec                    # Run the full RSpec test suite

# Code Quality
bin/rubocop                  # Run RuboCop linter
bin/rubocop -a               # Auto-fix violations
bin/lint                     # Run all linters (RuboCop, markdownlint)
bin/lint -A                  # Run all linters with auto-fix

# Security
bin/brakeman                 # Static security analysis
bin/bundler-audit            # Gem vulnerability audit

# CI (runs all checks)
bin/ci                       # Setup, style, security checks
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Rails App (3000)                        │
│   Controllers ─── Services ─── Models ─── Views (ERB/Hotwire)  │
│        │              │            │                            │
│   Auth (Devise)  GitHub Client  PostgreSQL                     │
│   Authz (Pundit) Container Mgmt  Encrypted tokens              │
└────────────┬───────────┬────────────────────────────────────────┘
             │           │
┌────────────▼───────────▼────────────────────────────────────────┐
│                    Temporal (7233)                               │
│   GitHubPollWorkflow ──► AgentExecutionWorkflow                 │
│   (long-running)         (per-issue lifecycle)                  │
│                          1. Create AgentRun                     │
│                          2. Create Worktree                     │
│                          3. Provision Container                 │
│                          4. Run Agent                           │
│                          5. Push Branch                         │
│                          6. Create PR                           │
│                          7. Update Issue                        │
└────────────────────────────┬────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────┐
│                  Docker Containers (paid_agent network)          │
│   Agent CLI (Claude Code, Cursor, Aider)                        │
│   ── Secrets Proxy ──► Anthropic/OpenAI APIs                    │
│   ── Git worktree isolation                                     │
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
| [SECURITY.md](docs/SECURITY.md) | Security model and container isolation |
| [STYLE_GUIDE.md](docs/STYLE_GUIDE.md) | Coding standards for developing Paid |
| [RDRs](docs/rdrs/README.md) | Recommendation Decision Records |
| [VISION.md](docs/VISION.md) | Philosophy, principles, and goals |
| [PROMPT_EVOLUTION.md](docs/PROMPT_EVOLUTION.md) | Prompt versioning and A/B testing |
| [OBSERVABILITY.md](docs/OBSERVABILITY.md) | Metrics, logging, dashboards, and alerting |

## Inspiration

Paid is inspired by [aidp](https://github.com/viamin/aidp), a CLI tool for AI-driven development. Key concepts borrowed include watch mode, provider abstraction, git worktrees, and style guide compression.

## Status

Phase 1 (Foundation) is complete. See [ROADMAP.md](docs/ROADMAP.md) for implementation phases.

## License

TBD
