---
parent: PAID
prefix: EXEC-INGRESS
---

# Low-Level Design: Execution Ingress

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> the execution/runtime boundary captured in
> [`container-runtime`](../container-runtime/container-runtime-design.md).

## Purpose

Paid's execution environment is designed for isolated outbound work, not as a
general inbound application host. This segment makes the default ingress
contract explicit and constrains the exceptions that exist today or are
expected to exist later.

## Default Contract

Every execution environment starts with **no public inbound endpoint**.
Neither an agent-run container nor its sidecars become publicly reachable by
default. If a workflow needs inbound reachability, that need must be expressed
as an explicit scoped ingress capability on the run contract.

## Scoped Exceptions

Ingress exceptions are modeled as declarative capabilities on the execution
run spec rather than as implicit side effects of provisioning:

- `preview` covers live preview exposure and is mediated through Paid's Rails
  proxy plus the RDR-045 outbound tunnel path.
- `browser` reserves space for a future browser-facing ingress exception.
- `debug` reserves space for an explicitly approved diagnostic endpoint.
- `callback` reserves space for an explicitly approved callback receiver.

Each capability carries:

- an expiration timestamp,
- an authentication requirement, and
- grant metadata (`granted_at`, `granted_by`) so later audit instrumentation
  can consume the decision without scraping logs.

## Current Support Boundary

Only the mediated `preview` capability is currently supported for execution
environments. It does **not** make the whole execution environment publicly
reachable. The preview tunnel remains outbound from the workload, terminates at
Paid-managed infrastructure, and is exposed to users only through the
`/previews/:token` Rails path.

`browser`, `debug`, and `callback` capabilities are recognized by the contract
so intent is explicit, but the current runtime rejects them during
compatibility/provision validation unless and until a future implementation
lands.

In production, unsupported diagnostic or callback exposure must fail closed;
there is no silent enablement path.
