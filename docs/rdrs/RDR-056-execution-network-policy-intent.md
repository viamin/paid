# RDR-056: Provider-Neutral Execution Network Policy Intent

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-13
- **Status**: Implemented
- **Type**: Architecture + Security
- **Priority**: P1
- **Related Issues**: #3403 (implementation), #3341, #3356, #3402 (dependencies)
- **Related RDRs**: RDR-004 (Container Isolation Strategy), RDR-006 (Secrets Proxy Architecture), RDR-020 (Service Container Architecture), RDR-040 (Runner Model Compatibility Contracts), RDR-048 (Multi-Host Docker Backend Support), RDR-054 (Runner Abstraction Boundary)
- **Related Tests**: `spec/services/execution_runners_spec.rb`, `spec/services/execution_runners/base_spec.rb`, `spec/services/execution_runners/local_docker_runner_spec.rb`, `spec/services/execution_runners/contract_runner_spec.rb`, `spec/services/network_policy_spec.rb`, `spec/services/containers/proxy_url_spec.rb`

## Implementation Status

Implemented as of 2026-08-13 via issue #3403. The expanded networking intent
vocabulary and the runner capability-validation contract land in this PR:

- `ExecutionRunners::NetworkingPolicy` exposes six canonical intents
  (`:no_outbound`, `:proxy_only`, `:git_plus_proxy`, `:approved_services`,
  `:model_direct`, `:explicit_internet`) plus the three backward-compatible
  aliases (`:proxy_restricted`, `:subscription_auth`, `:direct_outbound`).
- `ExecutionRunners::Base` declares the abstract `supports_policy?` class
  method; `LocalDockerRunner.supports_policy?` returns `true` for every
  intent (Docker already implements every shape) and `compatible?` rejects
  specs whose policy the runner does not support.
- `LocalDockerRunner` translates the new intents to Docker network + iptables
  shapes via `NetworkPolicy.contract_for_policy` and the firewall
  application helpers in `NetworkPolicy.apply_firewall_rules`. The current
  restricted behavior is preserved for `:proxy_restricted` and the current
  unrestricted behavior is preserved for `:subscription_auth` /
  `:direct_outbound`.
- `ExecutionRunners::ContractRunner` provides an in-memory implementation
  with a caller-set supported mode list, so the runner contract specs
  can assert that capability mismatches surface in `.compatible?` and
  `#provision` rather than silently downgrading.

## Problem Statement

The execution network policy model expressed through `NetworkPolicy::NetworkContract`
and the recent `ExecutionRunners::NetworkingPolicy` value object has only three
modes: `proxy_restricted`, `subscription_auth`, and `direct_outbound`. The three
modes conflate several distinct deployment intents:

1. **Air-gapped** runs that should have no outbound traffic at all (used by
   some security-sensitive deployments and offline evaluations).
2. **Proxy-only** runs where the agent must reach the Paid secrets proxy but
   must not initiate outbound connections to provider APIs or GitHub.
3. **Git + proxy** runs that need proxy-mediated LLM traffic and direct
   GitHub access for cloning/pushing.
4. **Approved services** runs that need proxy + Git + service containers
   (the current restricted behavior, used by default for API-key runs).
5. **Model direct** runs where the provider CLI authenticates itself against
   an upstream provider subscription (the current `direct_outbound` and most
   `subscription_auth` cases).
6. **Explicit internet** runs that need unrestricted egress (used for tests
   of new network shapes, scrapers, or operator-driven debugging).

All of these intents are currently expressed indirectly through combinations
of Docker network names (`paid_agent` / `paid_internal`) and the absence or
presence of a firewall. A future runner (Fly machine, remote bare-metal) cannot
translate Docker network choices into its native controls, so the contract leaks
Docker concepts into orchestration code.

In addition, runner capability is currently only checked against the
backend's host-path support via `Containers::Provision.compatibility_for`.
There is no equivalent check for whether a selected networking policy is even
implementable on a given runner — the runner only fails (and only in
production) when the firewall script cannot run on a host without iptables.

## Recommendation

Adopt a coarse, provider-neutral intent vocabulary on
`ExecutionRunners::NetworkingPolicy`. Runners translate the intent into their
native controls; orchestration code never references Docker network names.

The six intents:

| Intent | Allowlist | Firewall | Network choice | Existing analog |
|--------|-----------|----------|----------------|-----------------|
| `:no_outbound` | none | yes (default-deny, loopback only) | none | new |
| `:proxy_only` | Paid secrets proxy + DNS | yes | restricted | new |
| `:git_plus_proxy` | Paid secrets proxy + DNS + GitHub ranges | yes | restricted | new |
| `:approved_services` | Paid secrets proxy + DNS + GitHub ranges + service container IPs | yes | restricted | current `:proxy_restricted` |
| `:model_direct` | DNS (upstream provider hosts via subscription) | no | unrestricted | current `:direct_outbound` and most `:subscription_auth` |
| `:explicit_internet` | unrestricted | no | unrestricted | new |

The vocabulary is deliberately coarse: each mode maps to a fixed allowlist,
not an arbitrary rule set. The runner does not build a generic firewall DSL;
it selects a runner-defined native primitive (Docker network + iptables
script, Fly machine egress rules, etc.) for each intent.

`LocalDockerRunner` (the only current concrete runner) translates the six
intents to the existing Docker network and firewall shapes:

- `:no_outbound`, `:proxy_only`, `:git_plus_proxy`, `:approved_services` use
  the existing restricted `paid_agent` Docker network and the in-container
  iptables script with an allowlist derived from the intent.
- `:model_direct` and `:explicit_internet` use the existing unrestricted
  `paid_internal` Docker network with no firewall.

### Runner capability validation

Each concrete runner declares the set of intents it can implement via
`ExecutionRunners::Base.supports_policy?(policy)`. `compatible?` calls it
before returning a positive result so that the queue scheduler rejects a
policy that no runner in the deployment can satisfy, instead of failing only
after a provision attempt.

`LocalDockerRunner.supports_policy?` returns `true` for all six intents —
Docker already implements every shape via the existing network and firewall
mechanisms. The fake/contract runner used in specs declares a partial set so
the runner contract spec can assert that capability mismatches are rejected
rather than silently downgraded.

### Existing behavior is preserved

The current `:proxy_restricted` factory still returns a policy with
`mode = :proxy_restricted`, `firewall = true`, and an empty default
`allow_destinations` — the same shape `LocalDockerRunner` already understands.
For convenience and so that callers expressing the new intent vocabulary do
not lose approved-services handling, `:approved_services` is the canonical
name and `:proxy_restricted` remains as a backward-compatible alias.

The current `:subscription_auth` and `:direct_outbound` modes remain valid
constructors; they map to the new `:model_direct` intent. The plan is to
keep the old factories compiling so existing callers do not break, while
encouraging new code to use the named intent factories.

## Issue Plan

Implementation is tracked by a small chain:

| Issue | Priority | Scope | Dependency |
|-------|----------|-------|------------|
| #3403 | P1 | Expand `NetworkingPolicy` intent vocabulary, add runner capability validation, add contract runner, update specs/docs | #3341, #3356, #3402 |

## Proposed Design

### Intent vocabulary and constructors

`ExecutionRunners::NetworkingPolicy` adds six intent constructors:

- `.no_outbound` — air-gapped; only loopback traffic.
- `.proxy_only(allow_destinations: [])` — secrets proxy + DNS only.
- `.git_plus_proxy(allow_destinations: [])` — adds GitHub CIDR ranges.
- `.approved_services(allow_destinations: [])` — adds service container IPs
  resolved at provision time (current restricted behavior).
- `.model_direct(allow_destinations: [])` — unrestricted egress.
- `.explicit_internet` — explicit unrestricted egress (operator opt-in).

Each carries:

- `mode` — one of `:no_outbound`, `:proxy_only`, `:git_plus_proxy`,
  `:approved_services`, `:model_direct`, `:explicit_internet`.
- `firewall` — boolean; true for the four restricted modes.
- `allow_destinations` — caller-supplied additional destinations
  (`[{ host:, port: }]`) merged into the firewall's allowlist.

Backward-compatible constructors stay:

- `.proxy_restricted(allow_destinations: [])` — alias for
  `.approved_services(allow_destinations:)`.
- `.subscription_auth` — alias for `.model_direct` (kept as a named
  constructor for the existing subscription-auth call sites).
- `.direct_outbound` — alias for `.model_direct`.

`restricted?` returns true for the four firewall-required modes.
`firewall?` returns true for the four firewall-required modes.
`#model_direct?` / `#explicit_internet?` predicates clarify the
unrestricted split.

The existing `restricted?` / `firewall?` predicates keep working, so the
`Containers::ProxyUrl` and `LocalDockerRunner` plumbing stays unchanged
where it depends only on the restricted/unrestricted split.

### Runner capability validation

`ExecutionRunners::Base` adds:

```ruby
def self.supports_policy?(policy)
  raise NotImplementedError, "#{name} must implement .#{__method__}"
end
```

`LocalDockerRunner.supports_policy?` returns `true` for all six intents
because Docker already implements every shape via the existing network and
firewall mechanisms.

`LocalDockerRunner.compatible?` calls `.supports_policy?` on the spec's
networking policy and surfaces a `CompatibilityResult` with an explanatory
`error_message` when the policy is unsupported, so the queue scheduler
rejects the candidate rather than the runner failing late during provision.

A `ContractRunner` (defined under `app/services/execution_runners/`)
implements the abstract interface for testing: it supports only a
configured subset of intents and raises `ProvisionError` when a spec
asks for an unsupported intent. The shared `it_behaves_like "an
ExecutionRunner implementation"` example exercises the contract; new tests
exercise capability rejection and per-policy translation.

### Translation rules for `LocalDockerRunner`

`LocalDockerRunner` keeps the existing `paid_agent` / `paid_internal` network
choice and in-container iptables firewall script. The mapping is:

| Intent | Network | Firewall allowlist |
|--------|---------|--------------------|
| `:no_outbound` | `paid_agent` | loopback + DNS only |
| `:proxy_only` | `paid_agent` | + Paid secrets proxy |
| `:git_plus_proxy` | `paid_agent` | + GitHub CIDR ranges |
| `:approved_services` | `paid_agent` | + service container IPs (resolved at provision time) |
| `:model_direct` | `paid_internal` | none |
| `:explicit_internet` | `paid_internal` | none |

The runner-owned `NetworkPolicy.apply_firewall_rules` call already
accepts `service_destinations:` and the per-intent allowlist shrinks to the
subset of allowlist rules that fit the intent. The
`NetworkPolicy.contract_for_policy(policy)` helper is extended with the
new modes so the existing `restricted?` / `firewall?` decision still works.

## Acceptance Criteria

- `ExecutionRunners::NetworkingPolicy` exposes six intent constructors and
  three backward-compatible constructors; tests cover each intent's
  `restricted?` / `firewall?` / `mode` shape and round-trip through JSON.
- `ExecutionRunners::Base` defines `supports_policy?` as an abstract class
  method; `LocalDockerRunner.supports_policy?` returns true for every intent;
  `LocalDockerRunner.compatible?` rejects specs whose policy the runner does
  not support before returning a positive result.
- A `ContractRunner` (or equivalent test runner) implements
  `ExecutionRunners::Base` with a configurable policy support set so specs
  can assert that capability mismatches are rejected rather than silently
  downgraded.
- `LocalDockerRunner` translates each of the six intents to a Docker
  network + firewall shape that matches the table above; the existing
  `paid_agent` / `paid_internal` mapping is preserved for backward
  compatibility with the current `:proxy_restricted`,
  `:subscription_auth`, and `:direct_outbound` constructors.
- `Containers::ProxyUrl.resolve` and `NetworkPolicy.contract_for_policy`
  continue to accept every `NetworkingPolicy` shape, including the six new
  intents, without changes that would break existing callers.
- Tests cover policy selection and validation for `LocalDockerRunner`
  and the contract runner.
- EARS specs in `docs/intent/container-runtime/container-runtime-specs.md`
  document the new modes and the capability-validation contract.

## Out of Scope

- Building a generic firewall DSL — the policy stays coarse.
- Auto-selecting a policy from agent identity or runner capability — the
  policy is supplied by orchestration code that already knows the run
  intent.
- Replacing the existing subscription-auth and direct-outbound code paths
  — the existing factories remain and map to the new intent.
- Adding new firewall destinations beyond the existing
  `allow_destinations` shape.

## References

- `app/services/execution_runners.rb`
- `app/services/execution_runners/base.rb`
- `app/services/execution_runners/local_docker_runner.rb`
- `app/services/execution_runners/contract_runner.rb`
- `app/services/network_policy.rb`
- `app/services/containers/proxy_url.rb`
- `app/services/containers/provision.rb`
- `spec/services/execution_runners_spec.rb`
- `spec/services/execution_runners/base_spec.rb`
- `spec/services/execution_runners/local_docker_runner_spec.rb`
- `spec/services/execution_runners/contract_runner_spec.rb`
- `spec/services/network_policy_spec.rb`
- `spec/services/containers/proxy_url_spec.rb`
- `docs/intent/container-runtime/container-runtime-design.md`
- `docs/intent/container-runtime/container-runtime-specs.md`