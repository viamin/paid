# Mutation Testing

Paid runs a tier-1 mutation suite from [`.mutant.yml`](../.mutant.yml) in CI. That suite stays intentionally small and targets high-blast-radius code such as trusted-comment filtering, tenant context handling, and authorization policy behavior.

## Gem source

Paid now uses the MIT-licensed [`viamin/mutant`](https://github.com/viamin/mutant) fork as the sanctioned default source:

- `Gemfile` resolves `mutant` and `mutant-rspec` from `https://github.com/viamin/mutant` on `main`.
- `.mutant.yml`, `bin/mutation`, and CI all use the same default source and do not carry `--usage` or license-key plumbing.
- Customer-facing mutation-test enablement and configuration remain tracked separately in `#2370`.

## CI jobs

- `incremental` in [`.github/workflows/mutation.yml`](../.github/workflows/mutation.yml) runs `bundle exec mutant run --since origin/<base-ref>` on pull requests.
- `full` in the same workflow runs the tier-1 suite nightly without `--since`.
- Both jobs exercise the same sanctioned `viamin/mutant` source that local development uses.
