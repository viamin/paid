# RDR-036 Audit Report — 2026-08-04

## Summary

RDR-036 is fully implemented as of Tuesday, August 4, 2026. The repo now matches the scope that had previously remained open under issues [#2367](https://github.com/viamin/paid/issues/2367), [#2368](https://github.com/viamin/paid/issues/2368), and [#2370](https://github.com/viamin/paid/issues/2370).

The closeout issue for this audit is [#3169](https://github.com/viamin/paid/issues/3169).

## GitHub State

- [#2367](https://github.com/viamin/paid/issues/2367) is closed.
- [#2368](https://github.com/viamin/paid/issues/2368) is closed.
- [#2370](https://github.com/viamin/paid/issues/2370) is closed.

## Verified Shipped Scope

### 1. `viamin/mutant` is the default sanctioned source

- `docs/MUTATION_TESTING.md` documents `viamin/mutant` as the default source.
- `bin/mutation` runs `bundle exec mutant run --since HEAD~1` with no legacy source-selection flags.
- `.github/workflows/mutation.yml` runs both incremental and nightly mutation jobs against the same default source.

This satisfies the remaining RDR gap previously tracked by [#2367](https://github.com/viamin/paid/issues/2367).

### 2. Legacy `--usage` and licensing plumbing is gone

- `app/models/pre_commit_requirement.rb` now exposes a fixed `MUTATION_TEST_DEFAULT_COMMAND` with no `usage_value` placeholder.
- The repo no longer carries the `--usage` branches or `MUTANT_LICENSE_KEY` wiring described in the original follow-up.
- The mutation workflow and local runner both execute without the old licensing flags.

This satisfies the remaining RDR gap previously tracked by [#2368](https://github.com/viamin/paid/issues/2368).

### 3. Customer-facing mutation-test configuration shipped

- `app/views/projects/edit.html.erb` exposes a Mutation Testing section with an enable toggle, command field, and failure-behavior selection.
- `app/controllers/projects_controller.rb` persists the `mutation_test` requirement from the project settings form.
- `app/services/tenant_configurations/apply_project_defaults.rb` seeds an opt-in-off `mutation_test` requirement for new projects.
- `spec/system/projects/mutation_test_requirements_spec.rb` covers rendering, enabling, disabling, and updating the project-level mutation-test requirement.

This satisfies the remaining RDR gap previously tracked by [#2370](https://github.com/viamin/paid/issues/2370).

## Conclusion

RDR-036 should now be treated as **Implemented**:

- the sanctioned-source transition is complete
- the stale licensing path is removed
- the customer-facing project configuration is shipped

No additional follow-up issue is required for the original RDR-036 scope.
