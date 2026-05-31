# Mutation Testing

Paid runs a tier-1 mutation suite from [`.mutant.yml`](../.mutant.yml) in CI. That suite stays intentionally small and targets high-blast-radius code such as trusted-comment filtering, tenant context handling, and authorization policy behavior.

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
