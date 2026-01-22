# Paid Vision: Platform for AI Development

## The Bitter Lesson Applied

> "The biggest lesson that can be read from 70 years of AI research is that general methods that leverage computation are ultimately the most effective, and by a large margin." — Rich Sutton

Paid is built on a fundamental insight: **configuration is ephemeral, but data endures**. Every decision point in Paid that could be hardcoded as configuration is instead stored as data—prompts, model preferences, workflow patterns, quality thresholds. This isn't just good engineering; it's a bet that tomorrow's compute will make today's careful optimizations obsolete, while the data we collect will only become more valuable.

### Core Principle: Data Over Configuration

Traditional tools encode human expertise as rules:
- "Use GPT-4 for complex reasoning tasks"
- "Limit context to 8K tokens for cost efficiency"
- "Always include a system prompt about code style"

Paid treats these as **hypotheses to be tested**, not truths to be encoded. Every prompt is versioned. Every model choice is logged. Every agent run produces metrics. Over time, Paid learns what actually works—not what we thought would work.

## What Paid Is

Paid is a **Rails application with a web UI** that orchestrates AI agents to build software. Users add GitHub projects, and Paid:

1. **Watches** for labeled issues signaling work to be done
2. **Plans** by decomposing feature requests into trackable sub-issues
3. **Executes** by running AI agents in isolated containers
4. **Learns** by tracking what works and evolving its approach

## What Paid Is Not

- **Not a replacement for developers**: Humans review and merge all PRs
- **Not a prompt playground**: Paid manages production workflows, not experiments
- **Not a hosted service** (yet): Single-team deployment, multi-tenant ready
- **Not magic**: Paid is infrastructure that makes AI agents useful and safe

## Guiding Principles

### 1. Human Final Say

Every code change goes through a PR. Agents cannot merge their own work. This isn't a limitation—it's a feature. The human review step is where quality is enforced, trust is built, and agents learn from feedback.

### 2. Isolation by Default

Agents run in containers. They don't have access to secrets. They work on copies of code in git worktrees. They can't interfere with each other. This isolation isn't paranoia; it's the only way to run multiple agents in parallel safely.

### 3. Observable Everything

You can't improve what you can't measure. Paid tracks:
- Token usage and costs per project, per model, per agent
- Iteration counts and success rates
- Code quality metrics
- Prompt effectiveness through A/B testing
- Agent execution time and resource usage

### 4. Prompts Are Data

Prompts are not hardcoded strings. They are versioned entities with:
- A/B test assignments
- Performance metrics
- Human feedback scores
- Automated quality ratings
- Lineage (which prompt evolved from which)

A prompt that works well gets used more. A prompt that fails gets evolved or retired.

### 5. Models Are Commodities

Today's best model is tomorrow's baseline. Paid doesn't bet on any single provider:
- Model capabilities are tracked in a registry (via ruby-llm)
- A meta-agent (with rules-based fallback) selects models for tasks
- Per-project cost tracking enables informed tradeoffs
- New models can be adopted without code changes

### 6. Progressive Complexity

Paid should be useful on day one:
- Add a repo, add a token, label an issue
- An agent plans the work and opens a PR

But Paid should also support sophisticated workflows:
- Multiple agents collaborating on complex features
- Custom style guides compressed into LLM-friendly formats
- Workflow templates for different project types
- Quality gates that pause work when standards slip

## The Paid Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│                         PAID WEB UI                             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐   │
│  │ Projects │ │ Agents   │ │ Prompts  │ │ Live Dashboard   │   │
│  │ & Tokens │ │ & Models │ │ & Tests  │ │ (interrupt/stop) │   │
│  └──────────┘ └──────────┘ └──────────┘ └──────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      TEMPORAL WORKFLOWS                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ GitHub Poll │  │ Agent       │  │ Prompt Evolution        │  │
│  │ Workflow    │  │ Orchestrator│  │ & Quality Sampling      │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     TEMPORAL WORKERS                             │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              AGENT ACTIVITIES                             │   │
│  │  ┌─────────────────────────────────────────────────────┐ │   │
│  │  │           PROJECT CONTAINERS                        │ │   │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐               │ │   │
│  │  │  │ Agent A │ │ Agent B │ │ Agent C │  (worktrees)  │ │   │
│  │  │  │ Claude  │ │ Cursor  │ │ Copilot │               │ │   │
│  │  │  └─────────┘ └─────────┘ └─────────┘               │ │   │
│  │  └─────────────────────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         GITHUB                                   │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐   │
│  │  Issues  │ │ Projects │ │   PRs    │ │ Human Review     │   │
│  │ (labels) │ │  (V2)    │ │          │ │ & Merge          │   │
│  └──────────┘ └──────────┘ └──────────┘ └──────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Success Metrics

Paid succeeds when:

1. **Agents are productive**: PRs opened by agents get merged at a high rate
2. **Costs are predictable**: Per-project budgets are respected
3. **Quality improves over time**: Prompt evolution actually works
4. **Humans trust the system**: The dashboard shows what's happening, and interrupts work

## Inspiration: aidp

Paid is directly inspired by [aidp](https://github.com/viamin/aidp), a CLI tool for AI-driven development. Key ideas borrowed from aidp:

- **Watch mode**: Polling GitHub for labeled issues
- **Provider abstraction**: Supporting multiple AI agents through a common interface
- **Git worktrees**: Isolating parallel work streams
- **Style guides**: Compressing project conventions into LLM-friendly formats
- **Work loops**: Iterative agent execution with test/lint feedback

Paid adds:
- **Web UI**: Visual management and live dashboards
- **Temporal workflows**: Durable, observable orchestration
- **Container isolation**: Security through sandboxing
- **Prompt evolution**: Data-driven prompt improvement
- **Multi-agent orchestration**: Parallel agent execution with coordination

## Looking Forward

The AI landscape changes monthly. Models get better and cheaper. New agents emerge. Best practices evolve. Paid is built to adapt:

- New agent CLIs can be added without architectural changes
- New models appear in the registry and become available immediately
- Prompts evolve based on measured performance
- Workflow patterns can be shared and imported

The goal isn't to build the perfect system for today. It's to build infrastructure that gets better with time—and that leverages every increase in available compute to deliver better results.

---

*"The bitter lesson is that the general methods that leverage computation are ultimately the most effective."*

*Paid is our bet on that lesson.*
