# EARS Specs: Toolchain Pin Management

> Testable claims for how `bin/update` keeps pinned third-party tool versions
> current and consistent. Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r TOOLCHAIN-PIN-001`).

## Pin Registry

- [x] **TOOLCHAIN-PIN-001** — The toolchain pin registry SHALL declare, for
  every Paid-owned pin, each file that carries it and the pattern that locates
  it, so that pin locations are defined in one place rather than rediscovered
  by each caller.
  *Tests:* `spec/config/toolchain_pins_spec.rb`.
  *Code:* `scripts/lib/toolchain_pins.rb`.

- [x] **TOOLCHAIN-PIN-002** — When a registry pattern fails to match the file
  it is declared against, the update SHALL raise rather than report success, so
  a reworded file cannot silently disable its own update path.
  *Tests:* `spec/config/toolchain_pins_spec.rb`.
  *Code:* `scripts/lib/toolchain_pins.rb`, `bin/update`.

- [x] **TOOLCHAIN-PIN-003** — Every version a registry entry currently records
  SHALL be identical across all files in that entry's consistency group, so
  environments never diverge on a pin.
  *Tests:* `spec/config/toolchain_pins_spec.rb`.
  *Code:* `scripts/lib/toolchain_pins.rb`.

## Paid-Owned Binary Pins

- [x] **TOOLCHAIN-PIN-010** — When `bin/update` runs, it SHALL resolve the
  latest upstream release of each Paid-owned binary pin (`yarn`, `ast-grep`,
  `scc`, `rathole`, `rtk`, `codegraph`) and rewrite every file in that pin's
  consistency group.
  *Tests:* `spec/config/toolchain_pins_spec.rb`.
  *Code:* `bin/update`, `scripts/lib/toolchain_pins.rb`.

- [x] **TOOLCHAIN-PIN-011** — When a binary pin's install path verifies a
  SHA-256 checksum, `bin/update` SHALL rewrite the per-architecture checksums
  from the same upstream release that supplied the version, resolving a
  checksum the release does not publish by hashing the asset, and SHALL refuse
  any checksum that is not a SHA-256 digest.
  *Tests:* `spec/lib/upstream_registries_spec.rb`.
  *Code:* `scripts/lib/upstream_registries.rb`, `bin/update`.

## PostgreSQL Pins

- [x] **TOOLCHAIN-PIN-020** — When a newer PostgreSQL patch release exists
  within the pinned major version, `bin/update` SHALL update the server image
  pin in every Compose file and workflow service block that carries it.
  *Tests:* `spec/config/toolchain_pins_spec.rb`,
  `spec/lib/upstream_registries_spec.rb`.
  *Code:* `bin/update`, `scripts/lib/toolchain_pins.rb`.

- [x] **TOOLCHAIN-PIN-021** — When `bin/update` updates the PostgreSQL server
  image pin, it SHALL resolve each image's client package version from the PGDG
  package index for that image's target distribution rather than constructing
  it, because the PGDG package revision is not derivable from the upstream
  version.
  *Tests:* `spec/lib/upstream_registries_spec.rb`.
  *Code:* `scripts/lib/upstream_registries.rb`, `bin/update`.

- [x] **TOOLCHAIN-PIN-022** — When a resolved PostgreSQL client package does
  not exist, for every architecture Paid builds, in the PGDG index of every
  target distribution, `bin/update` SHALL leave the whole PostgreSQL group
  unchanged, so an image is never pinned to a package that cannot be installed.
  *Tests:* `spec/lib/upstream_registries_spec.rb`.
  *Code:* `scripts/lib/upstream_registries.rb`, `bin/update`.

- [x] **TOOLCHAIN-PIN-023** — When a PostgreSQL major version newer than the
  pinned major is available, `bin/update` SHALL report it and SHALL NOT apply
  it, because a major upgrade requires a data migration.
  *Tests:* `spec/lib/upstream_registries_spec.rb`.
  *Code:* `bin/update`, `scripts/lib/upstream_registries.rb`.

- [x] **TOOLCHAIN-PIN-024** — CI SHALL verify that each image's pinned
  PostgreSQL client package matches the pinned server version and that image's
  target distribution, without assuming a fixed PGDG package revision.
  *Tests:* `spec/config/ci_workflow_file_spec.rb`.
  *Code:* `.github/workflows/ci.yml`.

## Contract-Owned Agent CLI Versions

- [x] **TOOLCHAIN-PIN-030** — `bin/update` SHALL NOT write agent CLI versions
  into Paid-owned files, because those versions are declared by `agent-harness`
  installation contracts and a Paid-side pin would diverge from the version
  `agent-harness` was tested against.
  *Tests:* `spec/config/toolchain_pins_spec.rb`.
  *Code:* `scripts/lib/toolchain_pins.rb`.

- [x] **TOOLCHAIN-PIN-031** — When `bin/update` runs, it SHALL report each
  agent CLI's contract-declared version alongside that package's latest
  upstream release, distinguishing a contract that declares no version from one
  it could not read, so a lagging contract is visible and can be filed against
  `agent-harness`.
  *Tests:* `spec/lib/agent_contract_versions_spec.rb`.
  *Code:* `scripts/lib/agent_contract_versions.rb`, `bin/update`.

- [x] **TOOLCHAIN-PIN-032** — When a newer `agent-harness` release exists,
  `bin/update` SHALL update the gem's version pin, because the gem dependency
  is the only lever Paid controls over contract-owned versions. Because the pin
  is an exact version that `bundle update` cannot move, a run that already owns
  the lockfile SHALL reinstall so `Gemfile.lock` does not trail the rewritten
  pin; a run that does not SHALL report that reinstall as the next step.
  *Tests:* `spec/config/toolchain_pins_spec.rb`.
  *Code:* `bin/update`, `scripts/lib/toolchain_pins.rb`.

- [x] **TOOLCHAIN-PIN-033** — When the agent CLI contracts cannot be read,
  `bin/update` SHALL report that the check was skipped and SHALL complete its
  remaining checks, so an unavailable bundle does not block Paid-owned updates.
  *Tests:* `spec/lib/agent_contract_versions_spec.rb`.
  *Code:* `scripts/lib/agent_contract_versions.rb`, `bin/update`.

- [x] **TOOLCHAIN-PIN-034** — `bin/update` SHALL reconcile the devcontainer Oh
  My Pi installer's package and Bun runtime defaults against the `agent-harness`
  contract, and SHALL leave them unchanged when the contract supplies only part
  of that pair, so the devcontainer and the agent image install the same
  versions.
  *Tests:* `spec/lib/agent_contract_versions_spec.rb`,
  `spec/config/toolchain_pins_spec.rb`.
  *Code:* `scripts/lib/agent_contract_versions.rb`, `bin/update`,
  `.devcontainer/install-oh-my-pi.sh`.

## Report-Only Toolchain

- [x] **TOOLCHAIN-PIN-040** — `bin/update` SHALL report the latest available
  release of every language runtime pinned in `.tool-versions` — Ruby, Node,
  and Go — and SHALL NOT apply them, because a runtime upgrade is a deliberate
  migration.
  *Tests:* `spec/lib/upstream_registries_spec.rb`,
  `spec/config/toolchain_pins_spec.rb`.
  *Code:* `bin/update`, `scripts/lib/upstream_registries.rb`,
  `scripts/lib/toolchain_pins.rb`.

## Safety Controls

- [x] **TOOLCHAIN-PIN-050** — When a resolved version was published more
  recently than the configured quarantine period, `bin/update` SHALL report it
  and SHALL NOT apply it, so a compromised release yanked within hours is never
  adopted.
  *Tests:* `spec/lib/package_quarantine_spec.rb`.
  *Code:* `scripts/lib/package_quarantine.rb`, `bin/update`.

- [x] **TOOLCHAIN-PIN-052** — When `bin/update` updates the Ruby lockfile, it
  SHALL pass the quarantine period to the resolver as a cooldown rather than
  relying on an after-the-fact age report, because Bundler's own cooldown
  defaults to unset and would otherwise resolve to a release published minutes
  earlier. The period SHALL be rounded up to whole days so a partial day is
  never rounded away, and SHALL be passed as zero when the age check is
  skipped, so a configured cooldown is overridden rather than inherited.
  *Tests:* `spec/lib/package_quarantine_spec.rb`.
  *Code:* `scripts/lib/package_quarantine.rb`, `bin/update`.

- [x] **TOOLCHAIN-PIN-051** — When `bin/update` completes, it SHALL report
  every pin it held back and why, and SHALL offer a report-only mode that
  writes no files, so that a check-only run is a complete answer and requires
  no second manual sweep.
  *Tests:* `spec/lib/package_quarantine_spec.rb`,
  `spec/lib/update_script_spec.rb`.
  *Code:* `bin/update`, `scripts/lib/package_quarantine.rb`.
