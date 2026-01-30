# Paid - Platform for AI Development

Paid is a Rails application that orchestrates AI agents to build software. Users add GitHub projects, and Paid watches for labeled issues, plans implementations, and runs agents in isolated containers to create pull requests.

## Philosophy

> "Configuration is ephemeral, but data endures."

Paid stores every decision point as data—prompts, model preferences, workflow patterns—rather than hardcoding assumptions. This allows the system to evolve through measurement and A/B testing rather than relying on intuition alone. See [VISION.md](docs/VISION.md) for our full philosophy.

## Key Features

- **GitHub Integration**: Add projects via PAT, watch for labeled issues
- **Temporal Workflows**: Durable, observable orchestration of agent activities
- **Container Isolation**: Agents run in sandboxed Docker containers without secrets
- **Multiple Agents**: Support for Claude Code, Cursor, Codex, GitHub Copilot
- **Prompt Evolution**: A/B testing and automatic prompt improvement
- **Human-in-the-Loop**: All changes go through PRs; humans approve merges

## Development Setup

### Prerequisites

- Docker and Docker Compose
- Ruby 3.x (for local development outside Docker)

### Quick Start

1. Clone the repository and copy environment variables:

   ```bash
   cp .env.example .env
   ```

2. Start all services:

   ```bash
   docker-compose up
   ```

3. Access the applications:
   - **Rails app**: http://localhost:3000
   - **Temporal UI**: http://localhost:8080

### Services

| Service | Port | Description |
|---------|------|-------------|
| web | 3000 | Rails application |
| postgres | 5432 | PostgreSQL database |
| temporal | 7233 | Temporal server (gRPC) |
| temporal-ui | 8080 | Temporal web interface |
| temporal-admin-tools | - | CLI tools for Temporal administration |

### Temporal CLI Access

To access Temporal admin tools:

```bash
docker-compose exec temporal-admin-tools bash
tctl namespace list
```

### Cleanup

```bash
docker-compose down -v  # Remove containers and volumes
```

## Documentation

| Document | Description |
|----------|-------------|
| [VISION.md](docs/VISION.md) | Philosophy, principles, and goals |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture and technology stack |
| [ROADMAP.md](docs/ROADMAP.md) | Phased implementation plan |
| [DATA_MODEL.md](docs/DATA_MODEL.md) | Database schema, accounts, and RBAC |
| [AGENT_SYSTEM.md](docs/AGENT_SYSTEM.md) | Agent execution and Temporal workflows |
| [PROMPT_EVOLUTION.md](docs/PROMPT_EVOLUTION.md) | Prompt versioning and A/B testing |
| [SECURITY.md](docs/SECURITY.md) | Security model and container isolation |
| [OBSERVABILITY.md](docs/OBSERVABILITY.md) | Metrics, logging, dashboards, and alerting |
| [STYLE_GUIDE.md](docs/STYLE_GUIDE.md) | Coding standards for developing Paid |
| [RDRs](docs/rdrs/README.md) | Recommendation Decision Records for all major architectural decisions |

## Inspiration

Paid is inspired by [aidp](https://github.com/viamin/aidp), a CLI tool for AI-driven development. Key concepts borrowed include watch mode, provider abstraction, git worktrees, and style guide compression.

## Status

This project is in the planning phase. See [ROADMAP.md](docs/ROADMAP.md) for implementation phases.

## License

TBD
