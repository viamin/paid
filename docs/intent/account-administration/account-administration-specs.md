# EARS Specs: Account Administration

> Testable claims for operator-console and customer account-administration
> behavior. Status markers: `[x]` implemented · `[ ]` active gap · `[D]`
> deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r ACCOUNT-ADMIN-001`).

- [x] **ACCOUNT-ADMIN-001** — When a user attempts to access the operator
  console without explicit operator permission, the system SHALL deny access to
  anonymous users, account owners, and account admins instead of treating
  product-level account roles as sufficient for `/admin`.
  *Code:* `app/controllers/operator_console_access_controller.rb`.
  *Test:* `spec/controllers/operator_console_access_controller_spec.rb`.

- [x] **ACCOUNT-ADMIN-002** — When an operator runs an account lifecycle action
  from the console, the system SHALL require exactly one selected account,
  SHALL execute the explicit suspend/reactivate/deactivate transition, and
  SHALL log the successful operator action with actor and target account data.
  *Code:* `app/avo/actions/account_lifecycle_action.rb`,
  `app/avo/resources/account.rb`.
  *Test:* `spec/lib/avo/actions/account_lifecycle_action_spec.rb`.

- [x] **ACCOUNT-ADMIN-003** — When the customer account administration page is
  rendered, the system SHALL load account memberships, project counts, recent
  activity, and the operations/compliance/adoption dashboard summaries into the
  normal account UI rather than requiring operator-console access.
  *Code:* `app/controllers/concerns/account_administration_page.rb`.
  *Test:* `spec/requests/accounts_spec.rb`.

- [x] **ACCOUNT-ADMIN-004** — When a customer views account audit history, the
  system SHALL render recent account activity in the UI and SHALL support JSON
  export of that same activity from the customer-facing account audit log
  surface.
  *Code:* `app/controllers/accounts/audit_logs_controller.rb`.
  *Test:* `spec/requests/accounts_spec.rb`.
