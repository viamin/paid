---
parent: PAID
prefix: APPLE-VERIFY
---

# Low-Level Design: Apple Verification Presentation

Apple verification is exposed only when the `apple_verification_workers`
feature flag is enabled for the project. The project setting independently
selects `off`, `on_demand`, or `automatic`; the flag does not change that mode.

The project page presents configured mode, worker profiles, committed workflow
revisions, and attempts from the same structured records used by execution
clients. Approval is bound to the stored content digest, verification files,
worker profile, checks, and lifecycle gate. Only draft revisions can be
approved by a project administrator. Project administrators can rerun or
cancel attempts, waive a failed attempt's required checks with a reason and
expiry, and request early cleanup of a retained failed VM. These controls
delegate lifecycle state changes to the Apple verification attempt capability;
they do not duplicate execution-provider operations in the UI.

Capture artifacts are never embedded in the page. Screenshot and recording
entries link to an authenticated project-scoped endpoint, which authorizes the
viewer before issuing a time-limited storage URL. Result JSON retains build,
test, capture, policy, provenance, and failure data without collapsing the
failure taxonomy.

Authorized users can compare any two revisions belonging to the same project.
The comparison presents fields whose values differ, including digest,
verification files, checks, lifecycle gate, and status.
