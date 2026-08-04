# EARS Specs: Tenant Access Control

> Testable claims for the implemented tenant membership and authorization
> layer. Status markers: `[x]` implemented · `[ ]` active gap · `[D]`
> deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r TENANT-ACCESS-001`).

- [x] **TENANT-ACCESS-001** — When a user evaluates visibility or policy scope
  for an account-scoped resource, the authorization layer SHALL restrict access
  to resources in the user's current account and SHALL deny cross-account
  access.
  *Tests:* `spec/policies/project_policy_spec.rb`,
  `spec/policies/account_policy_spec.rb`.
  *Code:* `ApplicationPolicy`, `AccountPolicy`.

- [x] **TENANT-ACCESS-002** — When a user performs project actions, the
  authorization layer SHALL require same-account membership first, SHALL allow
  account owners/admins/members to run agents and manage issues, and SHALL
  allow viewer access only when the user also holds an explicit project role.
  *Tests:* `spec/policies/project_policy_spec.rb`.
  *Code:* `ProjectPolicy`, `ApplicationPolicy`.
