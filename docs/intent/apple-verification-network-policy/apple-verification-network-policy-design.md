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

An Apple verification attempt resolves the run's existing egress policy using
`AgentRuns::EgressPolicy::Resolve` with a forced proxy-restricted networking
intent. The resulting snapshot remains the authoritative combination of
platform, tenant, operator, project, and run decisions and is persisted before
the guest starts.

`AppleVerification::GuestNetworkPolicy` translates that snapshot into a
credential-free host/guest contract. The host provider must install the
contract before it starts the VM: no direct external route, DNS only through
the Paid resolver, and HTTP(S) only through the Paid proxy. The guest receives
the proxy endpoint but no proxy userinfo, password, token, or alternate DNS
configuration. The provider must reject guest traffic that does not use this
path, including direct IP, non-Paid DNS, proxy override, and non-HTTP(S)
protocols.

The contract is deliberately declarative. Tart/Softnet or a later provider
implements the transport mechanics, while policy resolution and the safe
manifest stay provider-neutral.

## Decisions and audit

The contract matches exact and leading-wildcard hosts from the persisted
snapshot and applies the destination port restriction when present. Invalid
hosts, IP literals, disallowed protocols, and unmatched destinations are
denied before they can be represented as allowed guest traffic.

Each denial is recorded as an `EgressSecurityEvent` and an execution audit
event with a sanitized destination, scheme, port, decision reason, and policy
mode. Payloads, proxy credentials, and raw IP literals are never recorded.
`NetworkPolicyError` carries a `network_policy` failure category so callers do
not mistake a boundary failure for build, test, or worker infrastructure work.

## Rollout

All runtime resolution checks the default-off
`apple_verification_workers` feature flag for the project. Project mode and
operator approval remain separate gates supplied by the Apple worker control
plane.
