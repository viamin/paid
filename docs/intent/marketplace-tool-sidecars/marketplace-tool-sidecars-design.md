---
parent: PAID
prefix: TOOL-SIDECAR
---

# Low-Level Design: Marketplace Tool Sidecars

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> [`docs/rdrs/RDR-073-marketplace-tool-sidecars.md`](../../rdrs/RDR-073-marketplace-tool-sidecars.md).
> Captures the per-run hardened sidecar provisioning shape — the third `install_type`
> arm on `Containers::McpProvisioner#provision` that the RDR designates.

## Purpose

A `MarketplaceEntry` of `entry_type: "tool"` publishes a Docker tool sidecar
(`install_type: "tool"`, `image`, `port`, optional `env`) and must be
provisioned as a hardened per-run sidecar on the agent network, never as a
plain MCP url server. The shape extends the existing `docker_image` MCP
sidecar machinery so all networking, aliasing, idempotent adoption, retry-safe
cleanup, and health-probe behavior carry through. Where the MCP path builds
without hardening, the tool path builds through the
`Containers::ServiceProvisioner` hardening profile path so every tool sidecar
ships with the same baseline controls already required for service containers
(`CONTAINER-RUNTIME-040`).

## Runtime Contract

### Third install arm

`Containers::McpProvisioner#provision` dispatches on `definition["install_type"]`
with `"npx"` (stdio in-container), `"docker_image"` (MCP url sidecar on
`paid_agent`), and `"tool"` (hardened sidecar on `paid_agent`). The tool arm:

- Pulls the image, creates (or adopts, on retry) a single Docker container per
  matching tool definition, attached to `NetworkPolicy::NETWORK_NAME` with a
  per-run DNS alias of the form `paid-tool-<sanitized-name>-run<agent_run_id>`.
- Builds through the `Containers::ServiceProvisioner` hardening profile path:
  `CapDrop: ["ALL"]`, `SecurityOpt: ["no-new-privileges:true"]`, the
  image-family `HARDENING_PROFILES` entry where one matches, the
  `DEFAULT_HARDENING_PROFILE` otherwise. The tool definition's `env` may carry
  a `PAID_SERVICE_HARDENING`-shaped override, validated by the same rules
  used by service containers (`readonly_rootfs`/`user` overrides refused for
  built-in families, `cap_add` restricted to `SAFE_OVERRIDE_CAPABILITIES`).
- Tracks the container ID on `AgentRun#tool_sidecar_container_ids` so retries
  adopt existing sidecars and run cleanup removes them.
- Records a run-scoped endpoint manifest on `AgentRun#tool_sidecar_endpoints`
  only after each tool passes its health probe. `Containers::Provision` passes
  that manifest to the agent as `PAID_TOOL_SIDECAR_ENDPOINTS`, a JSON array of
  `{name, hostname, port, url}` objects. The variable is absent when no tools
  provision successfully, and cleanup clears the persisted manifest.
- Labels each container `paid.tool_sidecar=true`; capacity inventory also uses
  that label and the persisted IDs to retain sidecar resource usage in the
  paid-agent bucket without counting a sidecar as an additional running agent.
- Waits for a TCP health probe against `hostname:port` with a timeout
  matching `McpProvisioner::HEALTH_CHECK_TIMEOUT`, mirroring the
  `docker_image` arm.
- Does **not** register a `url_server` MCP entry; a tool sidecar is a plain
  TCP/HTTP endpoint exposed to the agent via the alias.

### Image gate

Tool sidecar provisioning fails closed when the image is not permitted for
the account. The default evaluation surfaces through `UserSetting`
`allowed_service_images` for the run's account's admin/owner membership, the
same surface that gates `ServiceContainer#image_in_allowlist` for service
containers. A non-allowlisted image raises `Containers::McpProvisioner::Error`
with a typed, non-retryable message so the activity surfaces it as a clean
configuration failure rather than retrying.

### Rollout guard

Provisioning remains behind `FeatureFlags.enabled?(:marketplace_tool_sidecars,
project:)`. When the flag is off, the tool arm returns no containers — a
matching tool definition still records on the snapshot but the arm does not
provision or persist container IDs. The flag is the named enablement surface
in `FeatureFlags::DEFINITIONS` and is checked against the run's project.

## What This Is Not

- **Not a new provisioner.** The existing `McpProvisioner` gains a third
  arm rather than spawning a new subsystem — networking, aliasing, health
  checks, idempotent adoption, cleanup, and run-lifecycle integration are
  all reused.
- **Not MCP semantics.** Tool sidecars do not appear in the run's
  `mcp_provisioned_servers["url_servers"]` and the agent never sees them
  registered as MCP servers; they are exposed via the per-run DNS alias
  and `PAID_SERVICE_HARDENING` style configuration, not the MCP url server
  list.
- **Not MCP semantics.** `PAID_TOOL_SIDECAR_ENDPOINTS` is a runtime contract,
  not an MCP configuration source. Tool sidecars remain absent from
  `mcp_provisioned_servers`, including its `url_servers` list.
