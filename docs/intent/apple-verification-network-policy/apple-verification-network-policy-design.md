---
parent: PAID
prefix: APPLE-NETWORK
---

# Low-Level Design: Apple Verification Guest Network Policy

## Purpose

Apple verification guests run untrusted repository build and test code. This
segment extends the existing RDR-055 egress snapshot and gateway intent to
those guests; it does not create an Apple-specific allowlist.

## Resolution and enforcement contract

`AgentRuns::AppleVerification::ResolveGuestContract` resolves the run's
existing egress policy using `AgentRuns::EgressPolicy::Resolve` with a forced
proxy-restricted (`:proxy_only`) networking intent. The resulting snapshot
remains the authoritative combination of platform, tenant, operator, project,
and run decisions and is persisted before the guest starts. Resolution is
gated on the project's `apple_verification_workers` flag: when the flag is
off, `ResolveGuestContract` raises `WorkersDisabledError` without persisting
anything or producing a contract.

When the flag is on, `AgentRuns::AppleVerification::GuestContract.from_snapshot`
translates the snapshot into a credential-free host/guest contract: the Paid
DNS marker, the proxy endpoint (host/port only — no userinfo, password, or
token), and the snapshot's destinations. `AgentRuns::AppleVerification::ValidateGuestRequest`
is the enforcement decision point: given a `GuestNetworkRequest` (host, port,
scheme, and any reported alternate DNS server or proxy override), it permits
only HTTP(S) destinations that match the contract and denies everything else
— direct IP, non-Paid DNS, proxy override, non-HTTP(S) protocols, and
unmatched host/port pairs — before it can be represented as allowed guest
traffic.

The future Apple verification control-plane entry point SHALL send this
contract only to the authenticated, narrow host-service start operation,
which SHALL install it before it starts the VM. The concrete Tart/Softnet
transport that carries the contract onto a real guest, and the guest-start
lifecycle registration, belong to #3933. Until that authenticated host
implementation exists, nothing in Paid calls `ResolveGuestContract` or
`ValidateGuestRequest` from a guest-admission path, so Paid still does not
expose or admit Apple verification guests — this segment only builds and
tests the policy decision layer those future call sites will use.

## Decisions and audit

The contract matches exact and leading-wildcard hosts from the persisted
snapshot (reusing `AgentRuns::EgressPolicy::HostPattern`) and applies the
destination port restriction when present. Invalid hosts, IP literals,
disallowed protocols, and unmatched destinations are denied before they can be
represented as allowed guest traffic.

Each denial is recorded as an `EgressSecurityEvent` (`source_layer:
"apple_guest"`) and an `apple_guest.network_policy.denied` execution audit
event with a sanitized destination, scheme, port, decision reason, and policy
mode. Payloads, proxy credentials, and raw IP literals are never recorded.
`NetworkPolicyError` carries a `network_policy` category so callers do not
mistake a boundary failure for build, test, or worker infrastructure work.

## Rollout

All runtime resolution checks the default-off
`apple_verification_workers` feature flag for the project. Project mode and
operator approval remain separate gates supplied by the Apple worker control
plane.
