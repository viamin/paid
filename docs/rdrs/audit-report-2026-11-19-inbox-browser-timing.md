# Inbox browser timing acceptance — 2026-11-19

Tracking: #4901. Remaining optimization: #5165. Broader measurement automation: #4894.

## Scope and decision

The representative Inbox timing collection requested in #4901 is complete
in Paid's operating devcontainer. The Inbox still takes tens of seconds to
load, so #5165 remains open for the performance correction. It does not attest #4894's
reviewed-recipe admission, isolated execution or resume infrastructure, or
browser-visible chat timing. No production deployment exists.

## Environment and method

- Baseline: `ee300f8deaa4cb0f11490178a42d9423e9729dd6`.
- Current: `4ae2be4de8ae79646431b9c782de6f33a0109523`.
- Both checkouts are pinned in separate worktrees. Their `db/` trees are
  identical; both read the same existing operating database. No schema load,
  migration, reset, cache flush, fixture import or data replacement
  was performed against the operating database. Automatic worktree setup
  prepared separate disposable databases, which these measurements do not use.
- Real headless Chromium 156.0.8078.47, Cuprite, Rails 8.1.4.1, Ruby 3.4.11,
  Debian devcontainer; viewport 1440×1000. Assets were built independently from
  each checkout using the same installed toolchain.
- Existing authorized project-owner session, normal Warden/Devise
  serialization and controller/tenant/policy handling. Test session setup
  avoids changing the owner's password or submitting user actions. No
  controller/policy/query method is stubbed. Background job execution and
  cron are disabled in the final measurement processes using existing
  `GOOD_JOB_EXECUTION_MODE=external` and `GOOD_JOB_ENABLE_CRON=false` settings.
- Full-document navigations; one discarded warm-up per route, followed by
  five samples per route per revision, within a 900-second per-revision budget.
  Browser/process/cache are warm and no cache flush is claimed.
- `usable_ms` in the raw receipt means elapsed time until the Inbox heading
  is visible after navigation. It does **not** attest decision readiness,
  action completion, or time until all lazy panes finish. Browser navigation
  timing separately records TTFB, DOMContentLoaded and load completion.
- Redirects are followed and recorded, and every measured route finishes at
  `/inbox`. These are end-to-end navigation observations, not timings of the
  initial 303 response alone. Matched request paths can follow different
  redirect chains across revisions; the comparison does not normalize those
  chains. A controller exception/HTTP 4xx/5xx rejects a
  sample; only complete successful samples enter the comparison.
- SQL totals cover requests triggered by that browser during the sampling
  window, including lazy frames. Some previous-navigation frames can overlap;
  these totals are diagnostic observations, not deterministic per-request
  query assertions. Controller timings/statuses remain in the raw receipts.
- p50/p95 use linear interpolation at `q*(n-1)` on sorted raw values, matching
  `TechnicalPrerequisites::ValidateExecution#percentile`. Five observations
  yield a descriptive sample p95, not a stable population-tail estimate.

The tenant workload snapshot at 2026-11-19 01:38:33 UTC contains 22 projects,
4,926 issues and 29,580 runs. Both role-level superuser and BYPASSRLS flags are
false. Per-project counts before/after each revision are in the raw receipts.
This is an actively changing operating workload on a shared host, not a
controlled frozen fixture. A mid-run host snapshot showed 10 logical CPUs,
load averages 13.93/11.67/9.31 and approximately 2.8GB available memory. Revisions
run sequentially, so differences cannot establish causality or an improvement.

## Routes

1. Scoped stale selection:
   `/inbox/escalated_pr:7639?kind=escalated_pr&project_id=19`.
2. Filtered collection:
   `/inbox?kind=escalated_pr&project_id=19`.

The target PR has merged and is no longer escalated. This deliberately tests
stale-selection recovery and the filtered collection on the actual dataset;
it does not measure an active blocked-PR detail with a populated escalation
lane, another viewport or another tenant.

## Excluded attempts

Initial harness bootstrapping had missing Devise session serialization and
returned 500 responses. Their timings are excluded. An unfiltered trial reached
the Inbox but was interrupted during a subsequent sample because it expanded
into account-wide queue work; that partial sequence is excluded too. The first
server startup also used development's default worker mode; final comparisons
use worker/cron-disabled processes. These setup attempts are not performance
passes and do not establish an unchanged background workload.

## Results

| Route | Revision | Heading-ready p50 / p95 ms | Browser TTFB p50 / p95 ms | DCL p50 / p95 ms | Load p50 / p95 ms |
| --- | --- | --- | --- | --- | --- |
| Scoped stale selection | baseline | 59,823.597 / 69,359.983 | 57,531.400 / 68,785.600 | 59,234.200 / 69,174.760 | 59,448.500 / 69,229.360 |
| Scoped stale selection | current | 46,035.334 / 68,206.604 | 44,156.900 / 66,977.780 | 45,733.700 / 67,939.620 | 45,814.000 / 68,058.140 |
| Filtered collection | baseline | 48,418.669 / 69,771.201 | 47,790.300 / 69,064.040 | 48,229.600 / 69,601.240 | 48,253.900 / 69,652.020 |
| Filtered collection | current | 38,745.078 / 60,897.522 | 38,447.800 / 59,920.920 | 38,645.400 / 60,638.840 | 38,679.400 / 60,733.320 |

Each cell summarizes five complete samples. Raw SQL/query observations and
all controller statuses/timings remain in the linked receipts. No causal
improvement or acceptable-latency claim follows from these comparisons.

### Baseline provenance

Window: `2026-11-19T01:35:39Z` through `2026-11-19T01:46:23Z`; elapsed 643.814 seconds.
Project workload before/after: `{"after": {"escalated_prs": 0, "issues": 3423, "runs": 15476}, "before": {"escalated_prs": 0, "issues": 3422, "runs": 15475}, "project_id": 19}`.

### Current provenance

Window: `2026-11-19T01:46:31Z` through `2026-11-19T01:55:39Z`; elapsed 547.349 seconds.
Project workload before/after: `{"after": {"escalated_prs": 0, "issues": 3423, "runs": 15476}, "before": {"escalated_prs": 0, "issues": 3423, "runs": 15476}, "project_id": 19}`.

### Raw evidence and integrity

| Artifact | SHA-256 |
| --- | --- |
| [baseline.json](evidence-4901/baseline.json) | `5390f807b0930589c7691311907ea36750626de261284dba1c62fcbb45aa8e28` |
| [current.json](evidence-4901/current.json) | `907a5ef2ebb38fa0d4446bf57bb3d1f724f0cdbf6de8da5b414f1d30e2299222` |
| [comparison.json](evidence-4901/comparison.json) | `c7c84807b6724fee2166396472f9ebd291669459174b11a648e5d3df3fbd8ec5` |
| [workload-context.json](evidence-4901/workload-context.json) | `1c0d43f1383f3e87ff8d49d9214255afca6a644ad57110d63b51255264a514d3` |

Harness SHA-256: `00aae327cf0f79345fd5649db59d61d2eaecddc0b6d46c935e4b0f135efb07cc`.

### Mechanical verification

The comparison rejects incomplete runs, failed samples, missing/nonfinite/zero
metrics, wrong repetition counts, mismatched harness digests or mismatched
viewports. Raw sample arrays and absolute current-minus-baseline p50/p95
differences remain in `comparison.json`. The percentile calculation is also
checked independently against the application helper (48 checks passed); this is arithmetic
verification, not proof of recipe admission/resume behavior.

### Remaining work

Issue #4901's standalone timing collection can be reviewed from this receipt.
The observed delays remain a performance failure for #5165. The expensive
`Issue Eager Load` appears in the Rails SQL log at
`Issues::DependencyCycles#nodes` (`app/services/issues/dependency_cycles.rb:84`).
Investigate its wide account-scoped eager join and the filtered queue path
without removing cycle coverage, hiding warnings, or weakening authorization.
This is a profiling lead, not a tested optimization.

## Reproduction recipe

The exact reviewed harness below boots an independent loopback-only Puma
server and Chromium in the selected pinned checkout. It accepts only the
expected revision and existing operating database, authenticates the existing
project owner, navigates the two fixed read routes and writes bounded JSON.
Extract it to a local temporary file, use the corresponding revision and an
absolute output path, and run:

```sh
GOOD_JOB_EXECUTION_MODE=external GOOD_JOB_ENABLE_CRON=false \
PAID_DEVELOPMENT_DATABASE=paid_development \
PAID_DEVELOPMENT_CABLE_DATABASE=paid_development_cable \
MEASUREMENT_REVISION=<full-pinned-sha> MEASUREMENT_OUTPUT=<absolute-json-path> \
bin/rails runner <temporary-harness.rb>
```

```ruby
require 'capybara/cuprite'
require 'warden/test/helpers'
require 'json'
require 'digest'
require 'timeout'
include Warden::Test::Helpers

output = ENV.fetch('MEASUREMENT_OUTPUT')
expected = ENV.fetch('MEASUREMENT_REVISION')
revision = `git rev-parse HEAD`.strip
raise 'Revision mismatch' unless revision == expected
raise 'Operating database mismatch' unless ActiveRecord::Base.connection_db_config.database == 'paid_development'
project, owner = TenantContext.with_system_access do
  p = Project.includes(:account, :created_by).find(19)
  [p, p.created_by.tap { |u| u.account }]
end
raise 'No project access' unless ProjectPolicy.new(owner, project).show?
counts = -> { TenantContext.with(project.account) { {issues: project.issues.count, runs: project.agent_runs.count, escalated_prs: project.issues.where(is_pull_request: true, github_state: 'open', pr_review_phase: 'escalated').count} } }
Capybara.app = Rails.application
Capybara.server = :puma, {Silent: true}
Capybara.server_host = '127.0.0.1'
Capybara.default_max_wait_time = 120
Capybara.register_driver(:measurement_browser) do |app|
  Capybara::Cuprite::Driver.new(app, headless: true, timeout: 120, process_timeout: 60,
    browser_path: '/usr/bin/chromium', window_size: [1440, 1000],
    browser_options: {'no-sandbox': nil, 'disable-dev-shm-usage': nil, 'disable-gpu': nil})
end
Rails.application.routes.finalize!
Devise.configure_warden!
raise 'Missing Devise session serializer' unless Warden::SessionSerializer.method_defined?(:user_serialize)
Warden.test_mode!
session = Capybara::Session.new(:measurement_browser, Rails.application)
owner_id = owner.id
Warden.on_next_request do |proxy|
  TenantContext.with_system_access { proxy.set_user(User.find(owner_id), scope: :user) }
end
document = {
  revision: revision, started_at: Time.current.utc.iso8601, environment: 'operating development devcontainer',
  browser: `chromium --version`.strip, ruby: RUBY_VERSION, rails: Rails.version,
  viewport: {width: 1440, height: 1000}, workload: {project_id: project.id, before: counts.call},
  recipe: {identity: '4901-inbox-operating-browser-v1', sha256: Digest::SHA256.file(__FILE__).hexdigest,
    warmups_per_route: 1, samples_per_route: 5, navigation: 'full document with warm process/browser/cache',
    authentication: 'Warden test session for existing authorized project owner; normal controller/tenant/policy path',
    budget_seconds: 900, percentile: 'linear interpolation at q*(n-1)',
    limitations: ['Sequential observational comparison on changing live workload; no controlled causal performance claim',
      'No production deployment; existing devcontainer is the only operating environment',
      'No mutations submitted; redirects followed; five samples do not establish a stable population p95',
      'SQL totals include browser-triggered requests during each navigation; controller actions are recorded separately',
      'Does not attest the isolated recipe admission/resume infrastructure of #4894']}, samples: [], warmups: []
}
started_all = Process.clock_gettime(Process::CLOCK_MONOTONIC)
paths = ['/inbox/escalated_pr:7639?kind=escalated_pr&project_id=19', '/inbox?kind=escalated_pr&project_id=19']
write = -> { File.write(output, JSON.pretty_generate(document)) }
write.call
begin
  paths.each do |path|
    6.times do |index|
      raise 'Budget exceeded' if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_all > 900
      queries = []; actions = []
      sql_subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, start, finish, _id, payload|
        next if payload[:cached] || payload[:name] == 'SCHEMA'
        queries << {name: payload[:name], ms: ((finish-start)*1000).round(3)}
      end
      action_subscriber = ActiveSupport::Notifications.subscribe('process_action.action_controller') do |_name, start, finish, _id, payload|
        actions << {controller: payload[:controller], action: payload[:action], status: payload[:status], ms: ((finish-start)*1000).round(3), exception: payload[:exception]&.first, debug_trace: payload[:exception_object]&.backtrace&.take(12)}
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sample = {path: path, sample: index, warmup: index.zero?, timestamp: Time.current.utc.iso8601}
      begin
        session.visit(path)
        inbox_actions = actions.select { |a| a[:controller] == 'InboxController' }
        raise 'Inbox controller error response' if inbox_actions.empty? || inbox_actions.any? { |a| a[:status].to_i >= 400 || a[:exception] }
        raise 'Expected authenticated Inbox heading' unless session.has_css?('h1', exact_text: 'Inbox', wait: 5)
        sample[:usable_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC)-started)*1000).round(3)
        sample[:navigation] = session.evaluate_script(<<~JS)
          (() => { const n=performance.getEntriesByType('navigation')[0]; return {ttfb_ms:n.responseStart-n.startTime,response_end_ms:n.responseEnd-n.startTime,dom_content_loaded_ms:n.domContentLoadedEventEnd-n.startTime,load_ms:n.loadEventEnd-n.startTime,redirect_count:n.redirectCount,transfer_bytes:n.transferSize}; })()
        JS
        sample[:final_path] = URI(session.current_url).path
        sample[:status] = 'complete'
      rescue => error
        sample[:status] = 'failed'
        sample[:error_class] = error.class.name
        sample[:error] = error.message[0,300]
      ensure
        ActiveSupport::Notifications.unsubscribe(sql_subscriber)
        ActiveSupport::Notifications.unsubscribe(action_subscriber)
        sample[:queries] = queries.size
        sample[:sql_ms] = queries.sum { |q| q[:ms] }.round(3)
        sample[:slowest_sql] = queries.max_by { |q|q[:ms] }
        sample[:controller_actions] = actions
        document[index.zero? ? :warmups : :samples] << sample
        write.call
        puts sample.to_json
        STDOUT.flush
      end
      raise 'Browser acceptance sample failed' unless sample[:status] == 'complete'
    end
  end
ensure
  document[:workload][:after] = counts.call
  document[:finished_at] = Time.current.utc.iso8601
  document[:elapsed_seconds] = (Process.clock_gettime(Process::CLOCK_MONOTONIC)-started_all).round(3)
  write.call
  session.driver.quit
  Warden.test_reset!
end
```
