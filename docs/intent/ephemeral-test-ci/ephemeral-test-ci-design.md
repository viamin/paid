---
parent: PAID
prefix: EPHEMERAL-CI
---

# Ephemeral test CI

PR events enter the ephemeral workflow only when their complete PR diff touches
an ephemeral Ruby spec, a detected JavaScript/TypeScript test, or the workflow.
Deleting a test also matches the filter. Existing detection, trusted-author and
same-repository gates, test execution, and comment reconciliation remain in place.

Native path filtering avoids all runner allocation for unrelated PRs. The workflow
must not be a required check for every PR. GitHub's native diff limits apply.
If a PR adds and then completely removes its tests, its net diff can stop matching;
comment reconciliation then does not run. Result comments identify the tested
revision and workflow run so an earlier result cannot attest to a later revision.
