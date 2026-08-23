# EARS Specs: Runners Index Table

> Testable claims for the `/runners` index table. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across docs, tests, and code
> (`grep -r RUNNERS-INDEX-001`).

- [x] **RUNNERS-INDEX-001** — When the `/runners` index renders its table, the
  `Status` column SHALL appear immediately after `Runner` and before `Auth`.
  *Code:* `app/views/runners/index.html.erb`.
  *Test:* `spec/requests/runners_spec.rb`.

- [x] **RUNNERS-INDEX-002** — When the `/runners` index renders the `Agent Runs`,
  `Chat`, and `Fallback` capability columns, each cell SHALL use a disabled
  native checkbox whose checked state matches the runner's corresponding
  enablement flag, and each checkbox SHALL carry a column-specific accessible
  label.
  *Code:* `app/views/runners/index.html.erb`.
  *Test:* `spec/requests/runners_spec.rb`.

- [x] **RUNNERS-INDEX-003** — When the `/runners` index renders an API-key
  runner whose fallback mode is limited to rate-limit handling, the fallback
  checkbox SHALL expose the `rate-limit only` qualifier via its tooltip/title
  instead of inline text.
  *Code:* `app/views/runners/index.html.erb`.
  *Test:* `spec/requests/runners_spec.rb`.

- [x] **RUNNERS-INDEX-004** — When the `/runners` index renders, it SHALL omit
  the top-level `Rate Limits` table column while leaving rate-limit event counts
  available in the "Runner Usage Details" section.
  *Code:* `app/views/runners/index.html.erb`.
  *Test:* `spec/requests/runners_spec.rb`.

- [x] **RUNNERS-INDEX-005** — When the `/runners` index renders, it SHALL omit
  the "Runner Auth Setup" section entirely.
  *Code:* `app/views/runners/index.html.erb`.
  *Test:* `spec/requests/runners_spec.rb`.

- [x] **RUNNERS-INDEX-006** — When the auth setup section is removed from the
  runners index, `RunnersHelper` SHALL no longer expose
  `runner_auth_instruction_blocks`, `runner_auth_instruction_block`, or
  `RUNNER_AUTH_INSTRUCTION_COPY`.
  *Code:* `app/helpers/runners_helper.rb`.
  *Test:* `spec/helpers/runners_helper_spec.rb`.
