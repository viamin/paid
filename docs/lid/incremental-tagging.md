# Incremental `@spec` Tagging

Brownfield LID conversion creates HLD, LLD, and EARS first. It does not force a one-time retroactive `@spec` sweep across all existing code.

The default policy is incremental maturation:

- As `create_pr` runs touch an area under the LID-aware prompt, they add `@spec` at behavior entry points and on the tests that directly verify the cited EARS IDs.
- `bin/coherence-check.mjs` reports the remaining untagged code and test files as drift signals so the gap stays visible.
- A dedicated repo-wide tagging pass remains a deferred future enhancement, not a prerequisite for using LID.
