# EARS Specs: Billing Aggregation

> Testable claims for billing aggregation and account-facing billing visibility.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r BILLING-AGG-001`).

- [x] **BILLING-AGG-001** — When an authenticated account user requests
  billing data through `/api/billing/*`, the system SHALL authorize access via
  billing policy, SHALL scope usage/period/invoice lookups to the current
  account, and SHALL reject unauthorized or cross-account access instead of
  leaking tenant billing data.
  *Code:* `app/controllers/api/billing_controller.rb`.
  *Test:* `spec/controllers/api/billing_controller_spec.rb`.

- [x] **BILLING-AGG-002** — When scheduled billing period management runs, the
  system SHALL invoke the billing advancement flow and SHALL emit a structured
  summary of processed accounts, period transitions, and invoice generation so
  operators can observe managed billing rollover.
  *Code:* `app/jobs/billing_period_management_job.rb`.
  *Test:* `spec/jobs/billing_period_management_job_spec.rb`.

- [x] **BILLING-AGG-003** — When the account administration page is rendered
  for a billing-authorized user, the system SHALL load the active plan, current
  billing period, recent invoices, and payment-sync visibility alongside the
  rest of the account summary so managed billing status is visible in the
  customer account UI.
  *Code:* `app/controllers/concerns/account_administration_page.rb`.
  *Test:* `spec/requests/accounts_spec.rb`.
