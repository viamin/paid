# RDR-073 Attachment-Contract Audit — 2026-10-20

- **RDR:** [RDR-073](RDR-073-marketplace-tool-sidecars.md)
- **Closeout issue:** #4445 (follow-up from the #4268 closeout audit)
- **Conclusion:** `TOOL-SIDECAR-001` and `TOOL-SIDECAR-002` are **Implemented**.
- **Epic disposition:** #4263 remains open. This audit `Tracks #4263`; it
  deliberately contains no closing language for the epic. Only #4445's own
  acceptance criteria are in scope.

## Evidence reviewed

This audit re-verified the current checkout's source and permanent tests
rather than treating the prior 2026-10-14 audit or any closed issue as
evidence. It follows the [RDR Closeout Checklist](closeout-checklist.md).

| Acceptance criterion (issue #4445) | Shipped evidence | Result |
| --- | --- | --- |
| A conforming active `tool` entry attaches through automatic, team-default, and manual selection and contributes a `tool_sidecar` definition to the run snapshot | `app/services/marketplace_entries/renderer.rb:57-63` (`inferred_attachment_strategy` maps `entry_type: "tool"` to `"tool_sidecar"`); `app/services/marketplace_entries/attach_to_run.rb:20-54` resolves automatic/team-default/manual results through the same `Resolver` → `Renderer` → `synchronize_tool_sidecar_snapshot!` path; `app/services/marketplace_entries/runtime_attachments.rb:65-77,123-135` writes the normalized definition (with marketplace provenance) to `tool_sidecar_snapshot`, never `mcp_server_snapshot`. | Implemented |
| Canonical artifacts for tool entries validate the required `install_type`, image, and port fields before attachment | `app/models/marketplace_entry_version.rb:25-36,51-65` (`tool_payload_errors`, `tool_canonical_artifact_contract`, `tool_renderer_contract`) validates `install_type == "tool"`, a non-empty `image`, and an integer `port` in 1..65535 on every `tool` entry's canonical artifact and every provider renderer, plus optional `env`/`hardening` object and `alias` string shapes; `runtime_attachments.rb:73` re-checks `tool_payload_errors` at snapshot time as a defense-in-depth guard against stale data. | Implemented |
| Non-tool entries retain their existing rendering behavior | `renderer.rb:57-63` leaves `mcp_server`/`plugin`/`provider_config` inference untouched and still falls through to `prompt_append` for every other `entry_type`; `spec/services/marketplace_entries/renderer_dbless_spec.rb:6-46` (provider-native renderer selection, provider-switch re-render, malformed-payload rejection) exercises the unchanged `skill` path end to end. | Implemented |
| LID EARS coverage for `TOOL-SIDECAR-001` and tests-first evidence | `docs/intent/marketplace-tool-sidecars/marketplace-tool-sidecars-specs.md:9-23` carries the `[x] TOOL-SIDECAR-001` claim with `Tests:`/`Code:` references; `@spec TOOL-SIDECAR-001` annotations are present at `app/models/marketplace_entry_version.rb:51`, `app/services/marketplace_entries/runtime_attachments.rb:65`, and `app/services/marketplace_entries/mcp_snapshot_sync.rb:23`. | Implemented |

Test evidence actually run (not just present) during this audit:

```
bundle exec rspec spec/models/marketplace_entry_version_spec.rb \
  spec/services/marketplace_entries/renderer_dbless_spec.rb \
  spec/services/marketplace_entries/runtime_attachments_dbless_spec.rb \
  spec/services/marketplace_entries/attach_to_run_spec.rb
# 38 examples, 0 failures
```

`bundle exec rubocop` on the touched service/model/spec paths reports no
offenses. `bin/coherence-check.mjs` reports no reverse orphans or staleness
flag against the `marketplace-tool-sidecars` segment.

## TOOL-SIDECAR-002 interaction

`TOOL-SIDECAR-002` (flag-off behavior) was already implemented per the
2026-10-14 audit for directly supplied snapshot definitions. With the
attachment contract now shipping, the same flag-off guard
(`Containers::McpProvisioner#tool_sidecars_enabled?`) applies uniformly: the
`tool_sidecar_snapshot` entry is recorded regardless of the
`marketplace_tool_sidecars` flag, and only container provisioning is
suppressed while it is off, matching the RDR's rollout-guard disposition. No
change to the flag or its default was made or is needed.

## Scope note on TOOL-SIDECAR-003/004/005/006/007

This audit is scoped to #4445's acceptance criteria only. `TOOL-SIDECAR-003`
and `TOOL-SIDECAR-004` (rule-scoping predicates) remain unimplemented —
`app/services/marketplace_entries/resolver.rb` has no
`issue_labels_includes_any`, `languages_include_any`, or
`repo_files_include_any` evaluation — and are out of scope for #4445; they
remain tracked by #4446. `TOOL-SIDECAR-005`/`006`/`007` (hardened
provisioning, image/override gating, lifecycle and endpoint exposure) were
not re-verified here; the RDR's `## Implementation Status` section already
records them as shipped as of 2026-10-15, independent of this attachment-
contract work.

## Outcome and rollout guard

With the attachment contract implemented, a marketplace publisher can
publish a conforming `entry_type: "tool"` entry and have it attach (by any
selection mode) and snapshot as a `tool_sidecar` definition. The remaining
gap toward the RDR's full desired outcome is rule-scoping (#4446); this audit
makes no enablement change and does not remove or broaden the
`marketplace_tool_sidecars` rollout guard.

## Closure disposition

- **#4445**: all stated acceptance criteria have shipped code and passing
  permanent-test evidence as of this audit. No remaining gap for this issue.
- **#4263 (epic)**: remains open. `Tracks #4263`; only a future final-
  acceptance audit covering #4446 (and any residual gaps) may use closing
  language for the epic.
