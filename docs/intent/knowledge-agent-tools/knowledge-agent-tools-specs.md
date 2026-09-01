# EARS Specs: Knowledge Agent Tools

> Testable claims for the read-only knowledge agent tool surface (issue
> #3568). Status markers: `[x]` implemented · `[ ]` active gap · `[D]`
> deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r KNOWLEDGE-AGENT-TOOLS-001`).

- [x] **KNOWLEDGE-AGENT-TOOLS-001** — When an authorized agent calls
  `paid_knowledge_map` for a project, the system SHALL delegate to
  `Knowledge::Map::Build` (the same service behind `api/knowledge_map`) and
  SHALL return knowledge artifact counts (active and stale) grouped by
  `artifact_type` plus the top scope paths, for that project only, so the
  tool's numbers never diverge from the existing knowledge-map API.
  *Code:* `app/mcp/tools/knowledge_map.rb`.
  *Test:* `spec/mcp/tools/knowledge_map_spec.rb`.

- [x] **KNOWLEDGE-AGENT-TOOLS-002** — When an authorized agent calls
  `paid_knowledge_browse` with a project and `artifact_type`, the system
  SHALL return a bounded, paginated list of that project's active artifacts
  of that type, SHALL support filtering by a `scope_path` prefix, and SHALL
  include a stable `artifact_id` and `knowledge://` URI per result.
  *Code:* `app/mcp/tools/knowledge_browse.rb`.
  *Test:* `spec/mcp/tools/knowledge_browse_spec.rb`.

- [x] **KNOWLEDGE-AGENT-TOOLS-003** — When an authorized agent calls
  `paid_knowledge_search` with a project and query, the system SHALL delegate
  to `Knowledge::Search` and SHALL return a bounded number of results with
  content truncated to a preview length, each carrying a stable
  `artifact_id`/`chunk_id` and `knowledge://` URI.
  *Code:* `app/mcp/tools/knowledge_search.rb`.
  *Test:* `spec/mcp/tools/knowledge_search_spec.rb`.

- [x] **KNOWLEDGE-AGENT-TOOLS-004** — When an authorized agent calls
  `paid_knowledge_get` with a project and `artifact_id`, the system SHALL
  return that artifact's active/stale chunks up to a bounded chunk count and
  per-chunk content length, and SHALL flag the response as `truncated` when
  either bound is exceeded.
  *Code:* `app/mcp/tools/knowledge_get.rb`.
  *Test:* `spec/mcp/tools/knowledge_get_spec.rb`.

- [x] **KNOWLEDGE-AGENT-TOOLS-005** — When any of the four knowledge tools is
  called for a project the calling user cannot access, the system SHALL deny
  the call under the same `ProjectPolicy#show?` rule (account membership or
  an explicit project role) used elsewhere for project-scoped tools, rather
  than a bespoke authorization path.
  *Code:* `app/mcp/tools/knowledge_base_tool.rb`.
  *Test:* `spec/mcp/tools/knowledge_map_spec.rb`,
  `spec/mcp/tools/knowledge_browse_spec.rb`,
  `spec/mcp/tools/knowledge_search_spec.rb`,
  `spec/mcp/tools/knowledge_get_spec.rb`.

- [x] **KNOWLEDGE-AGENT-TOOLS-006** — The knowledge agent tool surface SHALL
  be read-only: none of the four tools SHALL declare `write_operation?` true
  or accept arguments that mutate knowledge state.
  *Code:* `app/mcp/tools/knowledge_map.rb`, `app/mcp/tools/knowledge_browse.rb`,
  `app/mcp/tools/knowledge_search.rb`, `app/mcp/tools/knowledge_get.rb`.
  *Test:* `spec/mcp/tools/knowledge_map_spec.rb`,
  `spec/mcp/tools/knowledge_browse_spec.rb`,
  `spec/mcp/tools/knowledge_search_spec.rb`,
  `spec/mcp/tools/knowledge_get_spec.rb`.
