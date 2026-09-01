---
parent: PAID
prefix: KNOWLEDGE-AGENT-TOOLS
---

# Low-Level Design: Knowledge Agent Tools

> Companion to `docs/intent/knowledge-base/knowledge-base-design.md`. That
> segment covers collection, retrieval, and evolution of project knowledge.
> This segment covers exposing that knowledge, read-only, as an explicit
> agent tool surface (issue #3568).

## Purpose

Paid's knowledge search and context-bundle assembly were previously reachable
only from inside Paid's own prompt-building code and the interactive chat
agent loop. Coding agents that connect to Paid as an MCP client had no small,
explicit, read-only surface for browsing the knowledge base the way they can
browse a filesystem: get an overview, list what exists in an area, search by
query, and fetch one item in full.

## Approach

Add four read-only MCP tools to the existing `Tools::*` / `Tools::Registry`
surface (`app/mcp/tools/`), the same mechanism `PaidMcpServer` already uses to
expose tools like `search_intents` and `get_intent`. No new authentication or
transport layer is introduced — the tools ride the existing chat-session MCP
endpoint (`Api::McpController` → `PaidMcpServer` → `Tools::Registry`).

- `paid_knowledge_map` — active artifact counts grouped by `artifact_type`
  for a project, so an agent can see what kinds of knowledge exist before
  drilling in.
- `paid_knowledge_browse` — paginated listing of artifacts within one
  `artifact_type`, optionally filtered by a `scope_path` prefix (e.g. a
  directory), mirroring `Knowledge::BrowseController`.
- `paid_knowledge_search` — thin wrapper over `Knowledge::Search`, the
  existing exact/semantic/hybrid retrieval service, with bounded, truncated
  results.
- `paid_knowledge_get` — full content (all active/stale chunks) of one
  artifact by ID, mirroring `Knowledge::ArtifactsController#show`.

All four:

- Are namespaced `Tools::Knowledge*`, sharing a `Tools::KnowledgeBaseTool`
  base class that resolves and authorizes the `project_id` argument via
  `policy_scope(Project).find(project_id)` + `authorize :show?` — identical
  to the existing `Tools::SearchIntents` / `Tools::GetIntent` pattern, so
  authorization stays exactly the account-membership / project-role rule
  already enforced for every other project-scoped tool.
- Are read-only (`write_operation?` defaults to `false`); none accepts a
  `confirmed` argument or mutates state.
- Return a stable identifier per artifact: `artifact_id` (the
  `knowledge_artifacts.id`) plus a `knowledge://<project_id>/<artifact_type>/<artifact_id>`
  URI, so an agent can round-trip from a search/browse result into
  `paid_knowledge_get` without re-deriving state.
- Bound content: search results truncate chunk content to a preview length;
  `paid_knowledge_get` caps the number of chunks returned and truncates each
  chunk, with a `truncated` flag when either cap is hit.

## Important Boundaries

- **No new write path.** Knowledge mutation continues to flow only through
  collector runs, redaction/scrub workflows, and knowledge-evolution
  recommendations — never through these tools.
- **No new authorization model.** Access is exactly `ProjectPolicy#show?`
  (account membership or an explicit project role), the same rule already
  governing `Tools::SearchIntents`/`Tools::GetIntent` and the human-facing
  `Knowledge::BrowseController`/`Knowledge::ArtifactsController`.
- **No CLI wrapper in this slice.** The issue's "MCP and/or a local CLI
  wrapper" framing is satisfied via MCP only; a CLI wrapper is deferred until
  a concrete consumer needs one, since no CLI-over-API pattern exists yet to
  extend.
- **`Knowledge::Search` unchanged.** The search tool calls the existing
  service as-is; no new search modes or ranking behavior were added.
