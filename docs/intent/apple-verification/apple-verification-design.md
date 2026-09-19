---
parent: PAID
prefix: APPLE-VERIFY
---

# Low-Level Design: Apple Verification Presentation

Apple verification is exposed only when the `apple_verification_workers`
feature flag is enabled for the project. The project setting independently
selects `off`, `on_demand`, or `automatic`; the flag does not change that mode.

The project page presents inferred profiles, committed workflow revisions, and
attempts from the same structured records used by execution clients. Approval
is bound to the stored source digest, referenced files, worker constraints,
checks, and lifecycle gate. Project administrators may approve, waive one
attempt with a reason, or destroy a retained failed VM. Members may rerun or
cancel their project attempts.

Capture artifacts are never embedded in the page: screenshot and recording
entries are explicitly labelled protected. Result JSON retains build, test,
capture, policy, provenance, and failure data without collapsing the failure
taxonomy.
