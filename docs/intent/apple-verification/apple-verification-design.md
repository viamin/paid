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
checks, and lifecycle gate. Only draft revisions can be approved. Project
administrators may waive one failed, required attempt with a reason or destroy
one retained failed VM. Members may rerun when the project mode permits
on-demand execution, or cancel their active project attempts. These lifecycle
rules are enforced by record transitions, not only by the page controls. A
rerun receives its Temporal workflow identifier while holding the attempt lock,
which also serializes cancellation with workflow startup.

Capture artifacts are never embedded in the page: screenshot and recording
entries are explicitly labelled protected. Result JSON retains build, test,
capture, policy, provenance, and failure data without collapsing the failure
taxonomy.
