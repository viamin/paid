# Paid Agent Bot Setup

This guide configures the git commit identity that agent containers use when they create commits in customer repositories.

## Overview

Paid now sets `git user.name` and `git user.email` per cloned repository at runtime instead of baking a fixed identity into the agent image.

This keeps PAT-based repository access working as-is while letting deployments align commit metadata with the configured `paid-agents` GitHub App identity.

## Configuration

Set these values in Rails credentials or environment variables:

- `paid_agent_app_slug` or `PAID_AGENT_APP_SLUG`
- `paid_agent_name` or `PAID_AGENT_NAME`
- `paid_agent_email` or `PAID_AGENT_EMAIL`

Recommended values for the canonical app:

```yaml
paid_agent_app_slug: paid-agents
paid_agent_name: Paid Agent
paid_agent_email: paid-agents@paid-agents.com
```

## Default and Fallback Behavior

Paid resolves commit identity in this order:

1. `paid_agent_name` / `PAID_AGENT_NAME`
2. `paid_agent_email` / `PAID_AGENT_EMAIL`
3. If only the app slug is configured, Paid derives the email as `<slug>@<slug>.com`
4. If no paid-agent metadata is configured yet, Paid falls back to the legacy identity `Paid Agent <agent@paid.dev>`

That fallback keeps existing PAT-only or partially migrated deployments working until the `paid-agents` app metadata is added.

## Notes

- This change only affects git commit metadata inside agent worktrees.
- GitHub authentication for PAT-backed projects still flows through the existing credential helper and secrets proxy path.
- Future app-backed repository auth can keep using the same identity source without another container-image change.
