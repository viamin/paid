# Paid - Platform for AI Development

Paid is a Rails application that orchestrates AI agents to build software. Users add GitHub projects, and Paid watches for labeled issues, plans implementations, and runs agents in isolated containers to create pull requests.

## Philosophy

> "Configuration is ephemeral, but data endures."

Paid is built on the [Bitter Lesson](http://www.incompleteideas.net/IncssIdeas/BitterLesson.html): general methods that leverage computation are ultimately the most effective. Every decision point that could be hardcoded is instead stored as data—prompts, model preferences, workflow patterns. This positions Paid to benefit from increased computing power over time.

## Key Features

- **GitHub Integration**: Add projects via PAT, watch for labeled issues
- **Temporal Workflows**: Durable, observable orchestration of agent activities
- **Container Isolation**: Agents run in sandboxed Docker containers without secrets
- **Multiple Agents**: Support for Claude Code, Cursor, Codex, GitHub Copilot
- **Prompt Evolution**: A/B testing and automatic prompt improvement
- **Human-in-the-Loop**: All changes go through PRs; humans approve merges

## Documentation

| Document | Description |
|----------|-------------|
| [VISION.md](docs/VISION.md) | Philosophy, principles, and goals |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture and technology stack |
| [ROADMAP.md](docs/ROADMAP.md) | Phased implementation plan |
| [DATA_MODEL.md](docs/DATA_MODEL.md) | Database schema design |
| [AGENT_SYSTEM.md](docs/AGENT_SYSTEM.md) | Agent execution and Temporal workflows |
| [PROMPT_EVOLUTION.md](docs/PROMPT_EVOLUTION.md) | Prompt versioning and A/B testing |
| [SECURITY.md](docs/SECURITY.md) | Security model and container isolation |

## Inspiration

Paid is inspired by [aidp](https://github.com/viamin/aidp), a CLI tool for AI-driven development. Key concepts borrowed include watch mode, provider abstraction, git worktrees, and style guide compression.

## Status

This project is in the planning phase. See [ROADMAP.md](docs/ROADMAP.md) for implementation phases.

## License

TBD
