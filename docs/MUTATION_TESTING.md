# Mutation Testing

Paid runs a tier-1 mutation suite from [`.mutant.yml`](../.mutant.yml) in CI. That suite stays intentionally small and targets high-blast-radius code such as trusted-comment filtering, tenant context handling, and authorization policy behavior.

## Switching gem source

Two gem sources are supported during the transition to the MIT-licensed `viamin/mutant` fork:

| Source | Gemfile | Package | License |
|--------|---------|---------|---------|
| **upstream** (default) | `Gemfile` | `mbj/mutant` from rubygems | Commercial |
| **viamin** | `Gemfile.viamin` | `viamin/mutant` from GitHub | MIT |

The switch is controlled by the `BUNDLE_GEMFILE` environment variable:

```bash
# Default — upstream rubygems release (mbj/mutant)
bundle exec bin/mutation

# viamin/mutant fork (MIT-licensed)
BUNDLE_GEMFILE=Gemfile.viamin bundle exec bin/mutation
```

**Why default to upstream for now?** The viamin/mutant fork is blocked on upstream features tracked in `viamin/mutant#9`, `viamin/mutant#10`, `viamin/mutant#11`, and `viamin/mutant#12`. Once those land, the default source will flip to `viamin/mutant` and `Gemfile.viamin` will become the primary `Gemfile`. See [RDR-036](rdrs/RDR-036-mutation-testing-for-ai-generated-tests.md) Amendment 1 and viamin/paid#2367 for the full rationale.

> **Note**: `viamin/mutant` (v0.8.x) uses a different CLI surface than the upstream release (v0.16.x).
> In particular, the `--usage opensource` flag is upstream-only. When running against `Gemfile.viamin`,
> use the parity script (`script/ci/mutation_viamin_parity.sh`) or invoke `mutant` directly without
> that flag. Cleanup of the `--usage` flag in `bin/mutation` and CI is tracked in viamin/paid#2368.

## CI jobs

- `incremental` in [`.github/workflows/mutation.yml`](../.github/workflows/mutation.yml) runs the sanctioned `mutant-rspec` release on pull requests with `--usage opensource --since origin/<base-ref>`.
- `full` in the same workflow runs the sanctioned release nightly across the full tier-1 suite.
- `mutation-viamin-parity` runs against `viamin/mutant@main` as an allowed-failure check on every pull request and on the nightly schedule.

## viamin parity signal

`mutation-viamin-parity` is a measurement job, not a gate. It uses `BUNDLE_GEMFILE=Gemfile.viamin` so Bundler resolves `mutant` and `mutant-rspec` directly from `https://github.com/viamin/mutant` `main`.

The green-light signal is simple: when `mutation-viamin-parity` starts passing without workflow-side workarounds, Paid can treat that as evidence that the structural blockers called out in issue `#2372` are effectively cleared and the sanctioned source can be flipped from the current release to `viamin/mutant`.

Until then, the job's step summary is the breadcrumb trail for upstream work. It records:

- which parity probe command failed
- whether a CLI flag or legacy subcommand was unrecognized
- which main `mutant` invocation exited non-zero
