---
parent: PAID
prefix: TOOLCHAIN-PIN
---

# Low-Level Design: Toolchain Pin Management

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers how Paid keeps pinned third-party tool versions current and
> consistent across the devcontainer, the `paid-agent` image, the production
> image, and GitHub Actions.

## Purpose

Paid pins the exact version of every third-party tool its build environments
install. Pinning is deliberate: reproducible images and checksum-verified
downloads are a supply-chain control, not an accident of convenience. The cost
of pinning is drift — a pin only stays correct if something reminds a human to
move it.

`bin/update` is that reminder. It resolves the current upstream version of
every pin Paid owns, applies the ones it can apply safely, and reports the ones
it cannot.

## Pin Ownership

Pins fall into three ownership classes, and the class determines what
`bin/update` is allowed to do.

**Paid-owned pins** live in Paid's own files and are Paid's to move:
`yarn`, `ast-grep`, `scc`, `rathole`, `rtk`, `codegraph`, and the PostgreSQL
server image plus its matching client packages. `bin/update` resolves the
upstream version and rewrites every file that carries the pin.

**Contract-owned pins** belong to the `agent-harness` gem. The versions of the
agent CLIs — Claude Code, Codex, OpenCode, Kilocode, Gemini, Copilot, Oh My Pi
(`omp`), `pi`, Cursor — and Oh My Pi's Bun runtime are declared by
`agent-harness` installation contracts and read at build time by
`scripts/extract-provider-install-contract.rb`. Paid does not pin them and must
not: a Paid-side override would silently diverge from the version
`agent-harness` was tested against. The only lever Paid controls is which
`agent-harness` release it depends on, so that gem pin is what `bin/update`
moves. Where a contract lags real upstream, `bin/update` reports the gap so it
can be filed against `agent-harness` rather than patched locally.

**Toolchain pins** — Ruby, Node, Go — are report-only. Moving them is a
deliberate migration with build, gem, and CI consequences that no automated
rewrite should decide.

## Consistency Groups

A single logical pin is usually written into several files with different
syntax, because the devcontainer, the agent image, the production image, and
the workflows each express it in their own idiom. Any update that touches one
file must touch all of them, or the environments diverge and only fail at build
time.

Pin locations are therefore declared once, as data, in a shared registry rather
than being rediscovered by each caller. The registry is what `bin/update`
rewrites and what the test suite asserts against, so a Dockerfile reworded past
its own registry pattern is caught by a failing test instead of by a silent
no-op update months later.

## PostgreSQL Version Coupling

PostgreSQL is the most tightly coupled group. The server image version pinned
in Compose and in every workflow's service block determines the client package
the images install. `pg_dump` aborts against a server of a newer *major*
version than itself; it tolerates a newer minor. The images nonetheless pin the
exact client build, because a reproducible image is worth more than that
tolerance is.

The client package version is *derived from* the server version but is not
mechanically constructible from it. PGDG publishes a distribution-specific
package revision that is not stable across releases — the same upstream
PostgreSQL release can be `-1.pgdg12+1` for one version and `-1.pgdg12+2` for
the next. The real revision must be resolved from the PGDG package index for
each target distribution; assuming a revision produces a package name that does
not exist and breaks the image build.

GitHub-hosted jobs are deliberately looser. They add the PGDG repository at run
time and install the client by major version only, so they never depend on the
runner image's preinstalled PostgreSQL and are unaffected by a PGDG minor
release landing after the server image does. That looseness is safe precisely
because the binding constraint is a major-version one; it is what keeps CI
independent of the publication ordering the images must wait on.

Updates stay within the pinned major version. A major upgrade changes the
client package name and requires a data migration, so it remains a human
decision; `bin/update` reports that newer majors exist and stops there.

## Safety Controls

Automated version bumps are a supply-chain attack surface, so the same controls
that already govern Paid's other pins apply to every pin this segment adds.

- **Quarantine.** A release must have been published for a minimum age before
  it is adopted, so that a compromised release yanked within hours is never
  picked up. A version inside the quarantine window is reported and skipped,
  never applied. Where the package manager enforces a cooldown natively, the
  same period is handed to it so the constraint binds during resolution rather
  than being reported once the lockfile has already been rewritten. Native
  cooldowns depend on the registry publishing per-version timestamps, so the
  age report remains a backstop for versions that carry none.
- **Checksum integrity.** Pins whose install path verifies a SHA-256 checksum
  are only rewritten when the new checksum is resolved from the same release
  the version came from, so version and checksum can never disagree.
- **Verified existence.** A resolved version is only written when the artifact
  it names is confirmed to exist upstream.
- **Hold, do not silently skip.** A pin whose registry pattern no longer
  matches its file holds the whole group and surfaces as a warning at the end
  of the run, rather than being treated as up-to-date — a silently unmatched
  pattern would report success while leaving the environment stale. The hold
  is deliberate rather than fatal so one stale entry cannot stop every other
  pin from being checked.

## Reporting

`bin/update` reports rather than acts whenever acting would be unsafe or
outside Paid's ownership: contract-owned versions lagging upstream, newer
PostgreSQL majors, Ruby and Node releases, and any pin held back by quarantine.
The report names the version, where it came from, and what the human's next
step is, so that "check for updates" is a complete answer on its own and does
not require a second manual sweep.
