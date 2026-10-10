# Code Scanning Alert #1838 — Triage Report

> Investigation requested by [#4224](https://github.com/viamin/paid/issues/4224) for
> synthetic issue 200001838 (local issue 3851) and GitHub code-scanning alert
> [#1838](https://github.com/viamin/paid/security/code-scanning/1838).
> Evidence captured 2026-10-10. This report is a reviewable decision document;
> it changes no application code, no scanner state, and no Paid verification
> state. No remediation claim is made by this document.

## Verdict

**False positive (name-heuristic mismatch), consistent with two prior authorized
dispositions of the same finding.** The flagged flow reads a two-valued,
allowlisted form-mode selector (`form_variant` ∈ `{subscription, api_key}`) from
the query string of the authenticated new-runner form. No credential material —
token, key, password, or secret — is read from, transported by, logged from, or
exposed through this GET flow. The detection fires because CodeQL's
`rb/sensitive-get-query` sink model is name-based, and the selector value is
later compared against the string literal `"api_key"` (and reaches
`api_key`-named variables and method names in the form view). Under CWE-598's
threat model (secrets captured from URLs via logs, history, referrer), the value
at issue is not sensitive.

**Recommended action:** an authorized reviewer dismisses alert #1838 as a false
positive using the rationale in [Dismissal rationale](#dismissal-rationale-for-an-authorized-reviewer).
The exact sink expression matched by the current CodeQL build could not be
pinned from the alert API (see [Remaining uncertainty](#remaining-uncertainty)),
but every candidate sink is a name heuristic carrying the same non-secret enum,
so the verdict does not depend on which candidate matched.

## Current alert evidence

Fetched from the GitHub code-scanning API on 2026-10-10:

| Field | Value |
| --- | --- |
| Alert | #1838, state **open** |
| Rule | `rb/sensitive-get-query` — "Sensitive data read from GET request" (CWE-598, medium, security-severity 6.5) |
| Tool | CodeQL 2.27.2, default setup (`analysis_key: dynamic/github-code-scanning/codeql:analyze`, build-mode `none`, category `/language:ruby`) |
| Location | `app/controllers/runners_controller.rb:69:36-42` — the `params` access in `auth_type = sanitize_auth_type(params[:form_variant])` |
| Handler region | `app/controllers/runners_controller.rb#L68-L84` (the `new` action) |
| Most recent instance | commit `3f65c8d` (current `main` HEAD) |
| Created | 2026-06-07T01:31:43Z; never fixed or dismissed since |
| Sibling alerts | Only open alert for this rule in the repository; 20 prior alerts for the rule are fixed or dismissed |

The flagged expression has been constant since before the alert was created —
only its line number drifted (24 → 64 → 66 → 69) as unrelated code was added
above it. The 39 recorded instances show the alert present at every location.

## Prior remediation history and verification outcomes

Five merged PRs claimed `Closes #200001838`. **None of them touched
`runners_controller.rb` or the flagged expression.** Each targeted a different
`rb/sensitive-get-query` finding elsewhere in the codebase:

| PR | Merged | What it actually changed |
| --- | --- | --- |
| [#2553](https://github.com/viamin/paid/pull/2553) | 2026-06-11 | `projects/agent_runs_controller.rb#refresh_auth`: `params[:auth_token]` / `params[:auth_code]` → `request.POST[...]` |
| [#3135](https://github.com/viamin/paid/pull/3135) | 2026-08-03 | `admin/github_app/setup_controller.rb`: `params[:code]` → `oauth_callback_code` with an `# lgtm[rb/sensitive-get-query]` suppression; added `/\Acode\z/` to `filter_parameters` |
| [#4034](https://github.com/viamin/paid/pull/4034) | 2026-09-25 | `claude_login_sessions_controller.rb` / `codex_login_sessions_controller.rb`: `params[:session_token]` / `params[:authorization_code]` → `request.request_parameters[...]` |
| [#4043](https://github.com/viamin/paid/pull/4043) | 2026-09-26 | `setup_controller.rb`: changed the suppression comment syntax `# lgtm[` → `# codeql[` |
| [#4047](https://github.com/viamin/paid/pull/4047) | 2026-09-26 | `setup_controller.rb`: removed the suppression entirely and reverted to plain `params[:code].to_s`; plus an unrelated `pr-screenshots.yml` Postgres image change |

After each merge, Paid's post-merge verification (EAGER-QUEUE-013,
`SecurityAlerts::VerifyRemediationAttempt`) found alert #1838 still open in a
matching default-branch analysis and recorded `verification_failed`
("finding remains open in matching post-merge analysis"), moving the synthetic
issue to manual review (EAGER-QUEUE-014). That is why the issue remains
"failed and partial": merged partial PRs exist, but the scanner-verified
recurrence is real — the merged PRs fixed sibling findings, not the tracked
alert's location. **The verification guard worked as designed; the remediation
targeting did not.**

The mis-targeting is visible in the PR bodies themselves: #2553's body admits it
was "generalized from the CodeQL alert context" and asks the reviewer to
"confirm the specific endpoint … against the actual diff", and #3135/#4043/#4047
say only "See #200001838 for context" while their diffs touch other controllers.
Sibling findings of the same rule did exist and were fixed over time — the
closed-alert history shows five `agent_runs_controller` alerts (#1844–#1848,
created 2026-08-02, fixed 2026-08-03), `clarifying_questions_controller` alerts
(#1841–#1842, fixed 2026-08-03), `plan_reviews_controller` (#1849, fixed
2026-08-26), and `change_intents_controller` alerts (#1851–#1856, fixed
2026-10-07) — which is exactly how five "Closes #200001838" PRs could merge
without ever addressing the tracked alert's location.

## Why the alert exists and keeps returning

1. **The finding predates alert #1838 and was twice dismissed as a false
   positive by the repository owner (`viamin`):**
   - [#1667](https://github.com/viamin/paid/security/code-scanning/1667) on the
     pre-rename `providers_controller.rb:25`, dismissed 2026-05-12 with the
     comment: *"False positive: params[:auth_type] is a UI display parameter
     validated through sanitize_auth_type against an allowlist. Same pattern
     exists in runners_controller.rb after rename."*
   - [#1837](https://github.com/viamin/paid/security/code-scanning/1837) on
     `runners_controller.rb:24` (the same expression after the
     providers→runners rename), dismissed 2026-05-12 as a false positive.
2. **Dismissal is non-sticky.** GitHub does not reopen a dismissed alert; when a
   later default-branch analysis re-detects the finding, a new alert number is
   created. That is exactly what happened on 2026-06-07: after the
   "Phase 5: Free models catalog UI" merge, a new analysis re-detected the
   finding and created #1838, which has remained open since.
3. **A cosmetic parameter rename was already tried and did not help.** The
   parameter was renamed `auth_type` → `form_variant` before 2026-05-27, and the
   `sanitize_auth_type` allowlist wrapper (with a comment saying it was
   extracted "to make it clear to static analyzers (CodeQL) that the raw query
   param is never used directly") predates the first dismissal. The alert kept
   returning because the query's trigger is not the parameter's name — see the
   next section.

## What `rb/sensitive-get-query` actually flags

From the CodeQL Ruby sources (`SensitiveGetQuery.ql`,
`SensitiveGetQueryCustomizations.qll`, `SensitiveActions.qll`,
`SensitiveDataHeuristics.qll` in `github/codeql`):

- **Source:** a `params[...]` read inside a GET request handler
  (`Http::Server::RequestInputAccess`, kind `parameter`).
- **Sink:** any `SensitiveNode` the tainted value reaches, where sensitivity is
  **name-based**:
  - a call whose *method name* looks like it produces credentials
    (e.g. `provider_api_key`),
  - a call carrying a *string-constant argument* whose name matches the
    sensitive-data regexes (e.g. `"api_key"`),
  - a read of a *variable* with a sensitive name, or an element reference with a
    sensitive constant key.
- The sensitive-name regex (`maybePassword`) matches `api.?key`, `api.?tok`,
  `oauth`, `auth…key`, `pass…` among others. Notably: `auth_type`,
  `form_variant`, `runner_key`, `token`, and `session_token` do **not** match;
  `api_key`, `is_api_key`, and `provider_api_key` **do** match
  (classification `password`).
- Taint flows through ordinary method calls (`include?`-based allowlisting is
  not a recognized sanitizer), so the `sanitize_auth_type` wrapper cannot
  silence the query, and neither does renaming the parameter.

In CodeQL's own test for this query, the flagged sinks are reads of a variable
literally named `password`. In Paid's `new` action, the analogous name matches
are all "api_key"-named, and none of them carry a secret.

## Source-and-sink trace of the flagged flow

All line numbers are current `main` (`3f65c8d`).

### Source (flagged)

- `app/controllers/runners_controller.rb:69` —
  `auth_type = sanitize_auth_type(params[:form_variant])` in the GET `new`
  action (lines 68–84, authenticated via `before_action` and
  `authorize @runner`).

### Sanitization at the boundary

- `app/controllers/runners_controller.rb:217-219` — `sanitize_auth_type` reduces
  any input to `Runner::AUTH_TYPES` or defaults to `"subscription"`.
- `app/models/runner.rb:24` — `AUTH_TYPES = %w[subscription api_key].freeze`;
  `app/models/runner.rb:181` additionally validates inclusion at the model
  layer. Array, `nil`, and arbitrary string inputs all collapse to
  `"subscription"`.

### Candidate sinks (all name heuristics; no secret data)

1. `app/controllers/runners_controller.rb:76` — `if auth_type == "api_key"`:
   the `==` call has the sensitive-named string-constant argument `"api_key"`
   with the tainted selector as receiver.
2. `app/views/runners/_form.html.erb:1` — `is_api_key = runner.api_key?`:
   `is_api_key` is a sensitive-named variable (contains `api_key`), tainted via
   `resource_records.new(auth_type: auth_type, …)`
   (`runners_controller.rb:80`) → `Runner#api_key?`
   (`app/models/runner.rb:224-225`, `auth_type == "api_key"`).
3. `app/views/runners/_form.html.erb:15` —
   `runner.provider_api_key&.api_service_type`: a sensitive-named method with a
   tainted receiver (same construction path as #2).

In every case the transported value is the enum `"subscription"` or `"api_key"`
choosing which radio button is preselected on the form
(`spec/requests/runners_spec.rb:1340` ff. assert exactly this behavior).

### Credential construction and handling (not in this flow)

- API-key *material* never enters the GET flow: the form posts
  `runner[provider_api_key_id]` — an integer foreign key — in the POST `create`
  body (`runners_controller.rb:241`).
- Stored key material is encrypted at rest: `ProviderApiKey encrypts :api_key`
  (`app/models/provider_api_key.rb:11`); `RunnerCredential encrypts :token`
  (`app/models/runner_credential.rb:11`).
- `auth_type` selects the authentication *mode* (subscription vs. API key),
  enforced by model validations (`app/models/runner.rb:194-200`), not any
  credential value.

### Logging, URLs, and exposure

- Audit events log only `runner_name` and `runner_key`
  (`runners_controller.rb:94,122,137`); `auth_type` is not logged.
- URLs embedding the parameter carry only the literal enum:
  `app/views/free_models/index.html.erb:12`
  (`new_runner_path(form_variant: "api_key", runner_key: "opencode", …)`) and
  the screenshot target `app/services/screenshots/capture_targets.rb:138`
  (`/runners/new?form_variant=subscription`).
- Worst-case leakage if such a URL is captured from browser history, logs, or a
  referrer header: that a user opened the "API key" variant of the add-runner
  form. That is not sensitive data under CWE-598 (credentials, session
  identifiers, PII).

## Detection instability (corroborating evidence)

The alert's instance history flips between `fixed` and `open` on commits that
never touched `runners_controller.rb`:

- 2026-08-31: not detected at `fbcc1003b9` ("delete never-enqueued job"),
  detected again at `cc10fa8ef5` ("delete orphaned view") hours later.
- 2026-09-01: not detected at `30c01855a2` ("restore tailwindcss dep") and at
  `39f74d99b3` ("GithubClient SimpleDelegator"), detected at
  `5d28e30650` / `9afbfb1c81` / `4163095507` (JS chores) and from
  `8e94bf9b8e` (2026-09-11, "revert json to 2.x") onward continuously through
  HEAD.

`app/controllers/runners_controller.rb` is byte-identical (MD5
`3fa10f0629fc9263bd391b3734ebf2d8`) across the 2026-08-31/09-01 fixed↔open
boundary commits, and none of them touch the runner form view or model. The
analyses come from GitHub default setup (`dynamic/…`), whose CodeQL bundle
version floats. With source bytes constant and the outcome flipping, the
detection sits on a modeling boundary and is version-sensitive — consistent
with a heuristic sink that newer/older bundles match differently, and not with
a code-level regression.

## Dismissal rationale for an authorized reviewer

Proposed dismissal (reason: **false positive**) for
[alert #1838](https://github.com/viamin/paid/security/code-scanning/1838):

> False positive. The flagged GET handler reads `params[:form_variant]`, a
> two-valued form-mode selector whose values are allowlisted by
> `sanitize_auth_type` to `subscription`/`api_key` (`Runner::AUTH_TYPES`) and
> used only to preselect a radio button on the new-runner form. No credential
> material is read from, transported by, or exposed through this flow: API-key
> secrets are encrypted at rest (`ProviderApiKey encrypts :api_key`) and are
> referenced by integer ID submitted in the POST create body. The detection
> fires because the selector value is compared against the string literal
> `"api_key"` and flows into `api_key`-named variables/methods in the form
> view, which CodeQL's name-based sensitive-data sink model treats as
> sensitive. Under CWE-598 the query-string value is not sensitive, so the
> URL-logging/history/referrer exposure the rule guards against does not apply.
> Same finding previously dismissed as false positive in #1667 (with this
> rationale) and #1837. Verified against main @ 3f65c8d.

Caveats the reviewer should weigh:

- **Dismissal is per alert number and non-sticky.** If a future default-setup
  analysis re-detects the finding, GitHub will open a new alert number (as
  happened #1667 → #1837 → #1838). Each successor would need re-triage; this
  report is written to make that cheap.
- **Durable suppression alternatives are code changes and are out of scope
  here** (an inline `# codeql[rb/sensitive-get-query]` pragma on the flagged
  line, or restructuring the comparison so the selector never meets an
  `api_key`-named expression). They would need their own remediation PR and
  scanner verification, and the cosmetic-rename variant has already failed.

## What an authorized disposition does on the Paid side

No one needs to clear Paid verification state by hand. Per
EAGER-QUEUE-013/014 (`SecurityAlerts::VerifyRemediationAttempt`,
`SecurityAlerts::ReconcileResolved`):

1. Once the alert is dismissed upstream, the next verification/reconciliation
   pass records the disposition on the synthetic issue
   (`code_scanning_disposition: dismissed`, with reason and evidence),
   concludes retryable attempts as terminal `upstream_resolved`, and closes the
   synthetic issue's GitHub state.
2. The auto-pick exclusion is governed by the latest attempt status
   (EAGER-QUEUE-015); `upstream_resolved` is not a blocking status.
3. The issue's `manual_review` hold (set by the `verification_failed`
   transition) is an operator decision lane — an operator resolves it from the
   Inbox once the disposition is recorded. An upstream disposition is terminal
   evidence; it is deliberately not recorded as scanner-verified remediation.

If instead the reviewer judges the finding valid after reading this report, the
corrective action would be a focused remediation PR that (a) moves the selector
off the query string (e.g. render both variants and let the client toggle, or
accept the mode via POST/fragment), and (b) is verified by an actual matching
post-merge CodeQL analysis — not by parameter renaming or suppression.

## What this investigation deliberately does not do

- No application code changes (docs-only PR).
- No alert dismissal — that action belongs to an authorized reviewer.
- No changes to Paid verification state, remediation-attempt records, or the
  synthetic issue.
- No new synthetic scanner issue (the tracked item remains
  200001838 / local issue 3851).
- No claim that this investigation fixes the alert.

## Remaining uncertainty

1. **The exact sink expression CodeQL 2.27.2 matched is not directly
   observable.** The alert API exposes only the source location; sink detail is
   not included. The three candidates listed above are derived from the query's
   sink model against the current source; all three are name heuristics
   transporting the same non-secret enum, so the verdict holds regardless of
   which one matched. Pinning it exactly would require running the same CodeQL
   bundle against the repo, which is not available in this environment.
2. **Per-analysis CodeQL bundle versions are not exposed by the instances
   API.** The fixed↔open flicker is attributed to analyzer drift by
   elimination (byte-identical source, unrelated commits, default-setup
   floating version), not by direct version evidence.
3. **Paid-internal attempt records were not directly readable** (the
   investigation environment has an empty database). The
   `verification_failed` / failed-and-partial state is taken from the
   requesting issue plus the implementing services' semantics
   (`spec/services/security_alerts/verify_remediation_attempt_spec.rb`,
   `spec/services/issues/closeout_status_spec.rb`), which encode exactly that
   outcome for a still-open alert in a matching post-merge analysis.

## Evidence index

- Live alert: `GET /repos/viamin/paid/code-scanning/alerts/1838` and
  `…/alerts/1838/instances` (2026-10-10); predecessor alerts #1837, #1667.
- Remediation PRs #2553, #3135, #4034, #4043, #4047 (bodies, diffs, comments).
- CodeQL sources: `ruby/ql/src/queries/security/cwe-598/SensitiveGetQuery.ql`,
  `ruby/ql/lib/codeql/ruby/security/SensitiveGetQueryCustomizations.qll`,
  `ruby/ql/lib/codeql/ruby/security/SensitiveActions.qll`,
  `shared/concepts/codeql/concepts/internal/SensitiveDataHeuristics.qll`.
- Paid verification semantics:
  `docs/intent/eager-queue-seeding/eager-queue-seeding-specs.md`
  (EAGER-QUEUE-013/014/015),
  `app/services/security_alerts/verify_remediation_attempt.rb`,
  `app/services/security_alerts/reconcile_resolved.rb`,
  `app/services/issues/closeout_status.rb`.
