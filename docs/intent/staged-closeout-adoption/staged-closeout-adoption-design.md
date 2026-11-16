# LLD: Staged Closeout Adoption

```yaml
parent: partial-closeout-recovery
prefix: STAGED-CLOSEOUT-ADOPTION
```

## Problem

Staged closeout verification needs an explicit project decision before a later
scheduler can run any check. Neither merge automation nor phase settings is
that decision, and untrusted issue, PR, or agent content cannot make it.

## Design

Each project has one default-off enrollment. An authorized project maintainer
may enable or disable it. Disabling it immediately makes every mapping
ineligible without deleting its history.

Enrollments, mappings, and their source issues are tenant-owned records. When a
project or its account is deleted, mappings are removed before their referenced
parents and reviewers so the ordinary owner lifecycle can remove the complete
adoption graph.

A reviewed mapping is an append-only revision for one source issue and stable
criterion string. It pins its stage, target shape, existing execution-path
key, version and digest, optional environment class, freshness, retry policy,
reviewer, and review time. Replacing or revoking a mapping retires the old
revision; future admission must select only the latest approved, current
revision. This is an eligibility contract only: it creates no run and does not
schedule a merge event.

Mapping admission validates the criterion against the current persisted
closeout assessment, project/account scope, stage-to-phase pairing, and the
existing permitted registry. Checkout validations resolve an enabled effective
`PreCommitRequirement`; live observations resolve only
`TrustedMeasurements::ALLOWLIST`. The stored immutable digest is recomputed at
admission, so a changed recipe/check makes the mapping ineligible.

The project closeout adoption surface and its JSON representation use the same
service and `ProjectPolicy#update?` authorization as any API/agent caller.

## Decisions & Alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Revision rows instead of in-place edits | Keeps the reviewed decision and invalidation history inspectable. | Editing the current mapping would erase the approval it superseded. |
| Registry references only | Prevents this feature from becoming a command or deployment executor. | Accepting arbitrary commands or targets would bypass existing authorization. |
