# Operator Console Runbook

## Purpose

The operator console at `/admin` is an internal-only backoffice for Paid maintainers. It exists so operators can inspect and correct tenant, user, membership, and tenant-setting state without Rails console access.

This surface is not customer-facing account administration. Account owners and account admins must continue using the product UI and remain blocked from `/admin` unless they are explicitly allowlisted as operators.

## Access Gate

- `/admin` is fail-closed.
- A signed-in user must also satisfy `User#operator?`.
- `User#operator?` is backed by `OperatorConsole::Access`, which reads:
  - `PAID_OPERATOR_EMAILS`
  - `PAID_OPERATOR_USER_IDS`
  - or `Rails.application.credentials.dig(:operator_console, :emails|:user_ids)`

If no allowlist is configured, nobody gets operator-console access.

## Avo Edition

This console is wired for Avo with Pundit resource authorization and custom actions. Per Avo's current licensing and pricing documentation, that authorization surface requires the Pro tier.

Required deploy-time configuration:

- `AVO_LICENSE_KEY`

## Resource Boundary

The initial operator resource set is intentionally narrow:

- `Account`
- `User`
- `AccountMembership`
- `ProjectMembership`
- `TenantSetting`

Sensitive auth material is excluded from the admin resource definitions. In particular, the console does not expose password digests, reset-password tokens, PATs, OAuth secrets, API keys, or encrypted credential columns.

## Destructive Safety

Raw destroy is disabled across the operator-console policies.

For account lifecycle work, use the explicit Avo actions on `Account`:

- `Suspend Account`
- `Reactivate Account`
- `Deactivate Account`

Those actions call the existing model APIs:

- `Account#suspend!`
- `Account#reactivate!`
- `Account#deactivate!`

Each lifecycle action logs a structured `operator_console.account_lifecycle` event with actor and target-account context.

## Expected Usage

Use the operator console for:

- correcting account plan/status/quota fields
- fixing membership roles or missing memberships
- inspecting tenant-setting JSON configuration
- applying explicit account lifecycle transitions

Do not use the operator console as a substitute for:

- customer-facing team management workflows
- credential/token inspection
- ad hoc destructive cleanup
