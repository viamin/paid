---
parent: PAID
prefix: DOCKER-DISK-CLEANUP
---

# Docker Disk Cleanup

## Purpose

Docker images and build cache accumulate on shared development hosts. A daily
GoodJob maintenance job bounds that accumulation while preserving application
state and agent runtime images.

## Scheduling and scope

`DockerDiskCleanupJob` runs daily at 04:17 UTC on the maintenance queue. It
requires `PAID_DOCKER_DISK_CLEANUP_ENABLED=true` and a Unix-socket Docker
connection. The setting authorizes cleanup of the shared local daemon, including
unused images from other projects. Remote Docker and Swarm hosts are outside
this job's scope. GoodJob limits this job to one execution and one queued copy.
The Rails/GoodJob process and Docker must be available for cleanup to run.
A twenty-minute job timeout bounds the entire operation, including discovery
and per-image deletion, in addition to the cache request timeout.

## Retention and protection

The cutoff is seven days before execution. Images must have a valid creation
timestamp older than that cutoff and no container references, including stopped
containers. The daemon's image identity is external input to a destructive
request, so only canonical `sha256:<64 hex>` identities are eligible and no
other daemon-reported value can reach a deletion path. Docker receives
non-forced deletion by image ID with implicit parent pruning
disabled, so protected ancestors cannot be removed as a side effect. An image acquired
by a container during cleanup is retained. Missing images and deletion conflicts
are benign races; other Docker failures fail the job visibly.

Paid's base and combo image namespace is protected. Before deleting images, the
job resolves every project's configured runtime plus database catalog image tags
and digests under system read access. Runtime catalog profiles from configuration
and environment are protected even when no project currently selects them;
configuration profiles take precedence over environment profiles. Protected references are resolved to image IDs
on the daemon, preserving aliases of those images. Missing protected images are
ignored; other protection lookup failures abort cleanup. Configuration resolution
failures also abort before deletion.

Build-cache pruning uses Docker's `until=168h` filter with `all=true`; Docker
retains cache currently in use. The request has a fifteen-minute read timeout.
The job never deletes containers, networks, or volumes. The existing orphan and
combo-image jobs retain their own lifecycle and retention policies.

## Observability

Completion logs include removed-image count, the sum of removed images' reported
sizes as an estimate (shared layers prevent treating it as reclaimed bytes),
Docker's actual cache bytes reclaimed, and elapsed time. A separate image-phase
completion log preserves partial results if cache pruning fails. Failures are logged and
re-raised for GoodJob visibility. A missing image or non-forced deletion conflict
also emits a warning with the image ID, so persistent daemon constraints remain
distinguishable from an empty eligible set.

## Decisions & Alternatives

| Decision | Chosen | Alternatives | Rationale |
| --- | --- | --- | --- |
| Scheduling | GoodJob maintenance | Temporal workflow, host cron | Uses the existing recurring maintenance mechanism. |
| Scope | Explicit local-daemon opt-in | Global cleanup on every backend | A shared daemon includes resources belonging to other projects. |
| Images | Selective non-forced deletion | Unrestricted image prune | Preserves configured runtimes even when no container currently uses them. |

## References

- [High-level design](../../high-level-design.md)
- [Agent system](../../AGENT_SYSTEM.md)
- [Docker builder prune filters](https://docs.docker.com/reference/cli/docker/builder/prune/)
