---
parent: PAID
prefix: PROD-CONFIG
---

# Low-Level Design: Production Configuration Validation

> Companion to the high-level design (`docs/high-level-design.md`). This segment
> covers the production-only startup configuration validator that fails fast when
> a required setting is absent or unsafe, and warns (without failing) when a
> development-unsafe default is detected in a production deploy.

## Purpose

Paid's configuration contained development-unsafe defaults and colocated-service
assumptions (`localhost` service addresses, compose DNS names) with no
production guardrails. Most services connect lazily, so a misconfigured cloud
deploy failed at first workflow or silently degraded rather than at boot. This
segment makes the production contract explicit and enforced.

## Shipped Behavior

`Config::ProductionValidator` (`app/services/config/production_validator.rb`) is
a pure, injectable object. Its `.from_environment` builder is the single
integration point that resolves the live values from `ENV` / Rails config /
credentials; the instance itself takes already-resolved values so every branch
is unit-testable without booting a production process.

It runs from an `after_initialize` hook in
`config/initializers/production_config.rb`, gated on `Rails.env.production?`.

- **Required settings** (boot fails fast): database credentials
  (`DATABASE_URL` or `PAID_DATABASE_PASSWORD`) and the Qdrant API key
  (`QDRANT_API_KEY` or the `qdrant.api_key` credential). All offending settings
  are collected and reported in a single `ConfigurationError` so one failed boot
  surfaces the full repair list.
- **Warned settings** (logged, not fatal): Temporal / Redis / Qdrant addresses
  that resolve to a localhost host, `CONTAINER_BACKEND=local` with no Docker
  socket, an unwritable workspace root, and unconfigured screenshots storage.
  Each emits a structured `warn` (`message: production_config.unsafe_default`).

## Scope decisions

- **Workspace root is a warning, not a hard failure.** Named-volume clones are
  the default workspace strategy and do not need a host path; the default
  `/var/paid/workspaces` is therefore not guaranteed writable in a standard
  Kamal deploy. Hard-failing on it would break existing deployments. Legacy
  worktree bind-mount execution does need it, so the warning still surfaces a
  real misconfiguration for that mode.
- **Redis is a warning, not a hard failure.** In production the cache is
  DB-backed (`solid_cache_store`) and `rails_performance` is development-only;
  Redis is consumed only by optional coordination features. An unset value falls
  back to a localhost default elsewhere, so unset and localhost both warn.
- **Build commands are skipped.** The Docker image's `assets:precompile` step
  boots Rails in the production environment without runtime secrets.
  `Config::ProductionValidator.build_command?` detects `assets:*` tasks (via
  Rake top-level tasks plus ARGV) and skips them, so the image build is not
  falsely blocked. Runtime processes and deploy-time `db:*` tasks carry secrets
  and are validated.
- **Infrastructure spend thresholds are optional, not boot-required.** The
  aggregate resource and provisioning-rate ceilings are required so capacity
  admission fails closed in every production deploy, but infrastructure spend
  thresholds (`MAX_*_INFRA_SPEND_*_CENTS` and the `INFRA_SPEND_*` pricing /
  projection settings) default to disabled (`0`) and are deliberately absent
  from the boot-required set: spend limits are an operator choice layered onto
  admission by the [`infrastructure-spend-thresholds`](../infrastructure-spend-thresholds/)
  segment. The complete optional variable list lives in
  `docs/PRODUCTION_CONFIG.md`.
- **No generic config framework.** Simple explicit checks only; no
  dry-validation or RailsConfig gem (per the issue's non-goals).

## What this is not

- **Not a connectivity probe.** The validator checks that settings are present
  and non-localhost, not that the services are reachable. Actual connections
  remain lazy.
- **Not a settings UI.** Boot-time validation only.
- **Not a deployment provider choice.** It passes for any deployment that sets
  the documented variables.

## References

- `docs/PRODUCTION_CONFIG.md` — the complete required/warned variable list
- `docs/SCALING.md` — deployment sizing and process topology
- `app/services/config/production_validator.rb`
- `config/initializers/production_config.rb`
- `spec/services/config/production_validator_spec.rb`
