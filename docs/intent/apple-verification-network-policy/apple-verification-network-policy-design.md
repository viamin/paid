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
proxy-restricted (`:proxy_only`) networking intent. `AppleVerification::ExecuteGuestJob`
is the guest-admission boundary: it resolves and persists the snapshot before
sending a manifest to the authenticated guest executor. Resolution is gated on
the project's `apple_verification_workers` flag: when the flag is off,
`ResolveGuestContract` raises `WorkersDisabledError` without persisting
anything or producing a contract.

When the flag is on, `AgentRuns::AppleVerification::GuestContract.from_snapshot`
translates the snapshot into a credential-free host/guest contract: the Paid
DNS marker, the proxy endpoint (host/port only — no userinfo, password, or
token), and the snapshot's destinations. The proxy endpoint is the egress
gateway (RDR-055 step 5 — the only component that filters the guest's
CONNECT/HTTP requests against the per-run allowlist), not the secrets proxy
(which is a Paid-internal destination the executor / harness reach directly).
`AgentRuns::AppleVerification::ValidateGuestRequest` is the enforcement
decision point: given a `GuestNetworkRequest` (host, port, scheme, and any
reported alternate DNS server or proxy override), it permits only HTTP(S)
destinations that match the contract and denies everything else — direct IP,
non-Paid DNS, proxy override, non-HTTP(S) protocols, and unmatched host/port
pairs — before it can be represented as allowed guest traffic.

`ExecuteGuestJob` validates that every destination in the resolved contract is
a non-IP-literal hostname with a supported scheme, then sends the contract
with the manifest to the authenticated guest executor. The serialized contract
explicitly denies the default route and host services, requires Paid-only DNS
and proxy routing through the egress gateway, blocks proxy overrides, and
contains only the resolved HTTP(S) destinations. The executor must install
that contract before accepting work; a failed resolution or validation prevents
the dispatch request altogether.

## Decisions and audit

The contract matches exact and leading-wildcard hosts from the persisted
snapshot (reusing `AgentRuns::EgressPolicy::HostPattern`) and applies the
destination port and scheme restrictions when present. Invalid hosts, IP literals,
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
