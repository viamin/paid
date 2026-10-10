---
parent: root
prefix: QUIET-MODE
---

# Quiet mode design

Projects may opt into a quiet GitHub timeline without losing Paid's durable
workflow state. Quiet mode is a project-scoped boolean, disabled by default.
When enabled it suppresses issue and pull-request comments at the GitHub client,
automation-provider, and issue-tracker adapter boundaries. It does not suppress
PR body creation or updates, labels, review submissions, run state, or inbox
state.

The project-scoped GitHub client decorator is required because a token-backed
`GithubClient` can be shared by more than one project. It intercepts comment
creation and pull-request comment replies without changing the rest of the
GitHub client surface. Provider and tracker boundaries also short-circuit so
future implementations cannot bypass the preference accidentally.

Permission-blocker commentary is the exception that receives a replacement:
when auto-merge lacks the required App permission, quiet mode publishes one
blocking `action_required` notification for the project instead of a GitHub
comment. Escalations remain load-bearing through labels and PR phase state, and
clarifying-question answers move to description sections in #4236.
