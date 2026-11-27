---
parent: PAID
prefix: TEST-SUITE
---

# Design: Test Suite Performance

## Purpose

Paid's non-system suite contains tens of thousands of examples. Repeated fixture
construction and queries accumulate across the suite, so the slowest individual
examples account for only part of the total. Reduce feedback latency while retaining every
distinct regression check, isolation boundary, and the 80% whole-suite coverage
floor. Keep local `bin/rspec` and separate system/performance checks available.

Examples with the same setup and operation may consolidate related assertions
without dropping the assertions or distinct failure scenarios. Similar names or
overlapping code coverage alone do not establish redundancy.
A cheaper retained check must catch the removed example's plausible regression;
use failure or mutation evidence where practical alongside code coverage.
Section-specific dashboard examples exercise the public `only:` interface for
the sections they assert, while default-response and cross-account integration
examples retain complete dashboard assembly. Avoid recomputing unrelated
sections in every component example.

## Execution

The runner startup-budget regression freezes its wall clock within the example,
so setup latency cannot consume the exact remaining budget under assertion.
The scope restores time afterward; application deadline calculations and both
timeout expectations remain unchanged (TEST-SUITE-029).

The assignment-update regression starts with an explicit control assignment and
verifies its persisted state before selecting the other variant. This guarantees
the existing-row update path is exercised regardless of randomized selection,
while retaining the same record and all existing assertions (TEST-SUITE-030).

Partition all non-system, non-performance spec files into five deterministic,
disjoint groups. Assign largest source files first to the least-loaded group,
using file bytes as a cheap structural estimate, not a correctness judgment or
promise of equal runtime. Each CI job has its own PostgreSQL/Qdrant services,
workspace and temporary files. Files and examples are never split across jobs.
Random ordering within a shard continues to expose order dependencies.

Each shard uses the existing RSpec runner, records a unique coverage command
name, and uploads raw coverage and JSON example timings even on failure. Disable
per-shard HTML formatting and partial-suite coverage thresholds only in shard
mode. A stable final `test` job requires every shard to succeed, verifies all
expected distinct coverage reports exist, then collates them with the original
Rails filters and enforces the existing 80% minimum. Missing reports, failing
shards, or insufficient combined coverage fail the final check. Separate query
performance specs run once, and the system-test workflow remains unchanged.
Allow each shard and dropped-shard recovery execution path 360 minutes at the
GitHub job boundary. This remains a bounded failure window while leaving
headroom for hosted-runner contention beyond the normal shard duration and the
bounded setup retries; reaching the boundary still cancels the shard and fails
the stable final check.

The shard matrix and dropped-shard recovery retry JavaScript dependency setup
at most five times, bounding each attempt to twenty minutes with increasing
delays. Each attempt runs in an isolated process group so timeout termination
also stops its package-manager descendants and reaps its owned session leader
before the next retry. Its watchdog runs in a separate owned session containing
both the timer and grace delay, acknowledges that session before cleanup can
target its process group, and retains its exact child PID from fork through
that acknowledgement so cancellation can terminate and reap startup ownership
without waiting for an attempt timer. The setup leader is likewise supervised
without a blocking wait that defers TERM or INT cleanup. The wrapper terminates
and waits for owned watchdog state on every success, failure, timeout, and
cancellation before returning. Retry
backoff and termination-escalation timers are likewise owned children: cleanup
terminates and reaps them before returning, including when the wrapper receives
TERM or INT. The supervisor
sends TERM to only that owned group, follows with KILL after a finite grace
period for TERM-resistant descendants, and reports a timeout as a failed setup
attempt. This absorbs transient registry
and hosted-runner stalls without skipping setup or relaxing the shard's
360-minute job boundary.

Before the shard matrix starts, CI runs the complete MCP Registry contract in
its own bounded preflight job. That focused job retains the literal,
reviewed write-tool inventory and the read-only-definition exclusion check;
it is not generated from production write flags. It records elapsed time in
the job summary. Expensive shards depend on that job, so a failed contract
leaves them skipped rather than consuming their database, service, dependency,
and test budgets. The stable final test check reports a failed trusted
preflight as a failure, while remaining skipped when the preflight is
intentionally skipped for an untrusted pull request. Tool authors update the reviewed inventory whenever they
add, remove, rename, or change the write classification of an MCP tool.

The same shard paths install the pinned ast-grep binary before running specs.
Each release-asset transfer has explicit connection and total-transfer bounds.
The existing finite, process-group supervisor retries the complete install and
reaps a timed-out curl descendant before the next fresh connection. The
downloaded archive remains checksum-verified before installation; exhausted
retries fail the shard rather than skipping structural-search coverage.

## Platform-dropped shard recovery

GitHub Actions occasionally drops a matrix leg (or another job) entirely during
platform incidents: the job is never created, no check run appears, and the
matrix aggregate reports failure even though no test ran. A lightweight
`shard-status` job classifies each expected leg from the run's job list after
the matrix completes: a leg with no job is recoverable, a leg that ran and did
not succeed is failing, and an unclassifiable run (jobs API unavailable) fails
closed. A `shard-recovery` job then re-runs exactly the recoverable legs with
the same services, credentials, coverage command names, and per-leg artifact
contract as the matrix, keeping one shard identity per coverage report. The
final check treats recovery as satisfying only the missing legs: a real shard
failure, a failed re-run, an incomplete classification, or a still-missing
report still fails the check. Recovery never re-runs legs that executed.

The recovery job's `always()` dependency inspection is paired with
`!cancelled()` so a cancelled or superseded pull-request workflow cannot start
recovery after GitHub re-evaluates job conditions. A recovery already in
progress receives normal workflow cancellation; its existing bounded
process-group cleanup stops dependency attempts before another attempt or test
leg can begin. Per-leg artifact uploads retain their `always()` guards so
completed recovery work is reported truthfully, but they do not make recovery
itself eligible after cancellation. A cancelled recovery is not a successful
recovery and cannot satisfy the final coverage gate.

## System-suite infrastructure recovery

The GitHub-hosted PostgreSQL service can rarely return an empty protocol result
while Rails applies tenant context, surfacing from the adapter as a
`cmd_tuples` call on `nil`. A hosted browser process can also stall the suite
without returning an assertion or adapter failure. The system-test job bounds
each complete browser-suite attempt at 80 minutes and may retry the complete
suite after either condition, with three total attempts so repeated transport
faults remain bounded below GitHub's six-hour job maximum. Before each retry,
the job restarts the PostgreSQL service container identified by GitHub Actions'
job-service context and waits for it to accept connections; a missing or
unavailable container fails closed. A short increasing delay then gives the
hosted service time to settle. Any other failure exits immediately, and
exhaustion of the bounded attempts still fails the job. The recovery does not
skip examples or reinterpret assertion failures.

System-test workflow runs do not use GitHub Actions workflow concurrency. GitHub
keeps at most one pending run in a concurrency group and cancels a superseded
pending run even when cancellation of in-progress work is disabled. Leaving
these required runs ungrouped ensures each pull-request check can reach a
terminal result rather than being cancelled while queued.

Allow the system-test job GitHub's six-hour maximum at the job boundary.
Dependency setup is separately bounded, while the browser suite can exceed the
former four-hour allowance on a hosted runner. The larger limit remains a
bounded failure window and does not change spec-level failure or retry behavior.

## Individual test costs

Certificate behavior specs use the existing explicit test key-size parameter
while retaining real key generation, certificate signing, chain validation and
encrypted storage. Production key sizes remain unchanged. CLI specs inherit
Rails database configuration instead of demanding a DATABASE_URL or imposing
agent-container defaults. Keep cold-process boot and CLI checks where process
startup is part of the contract; do not replace them with application mocks.
Use the current Ruby directly when the target already loads Bundler, avoiding a
redundant `bundle exec ruby` wrapper. Suppress child-only profiler diagnostics
that would corrupt boot/coverage probe output while profiling the parent suite.

## Measurement and profiling

JSON timings make each shard's examples and durations inspectable. The existing
opt-in test-prof workflow must allow a full suite to finish within its timeout;
profiling does not relax normal CI requirements. Compare before/after focused
examples and actual CI wall time. Five jobs reduce latency at the cost of extra
setup runner minutes; they do not claim a fivefold reduction in total CPU work.

Normal test logging defaults to `info`, retaining application info, warnings,
and errors without formatting every SQL debug event. `RAILS_LOG_LEVEL=debug`
restores SQL diagnostics for investigation. This changes only test logging;
callbacks, query execution, tenant policy, and coverage remain enabled.
Validate the booted logger and actual SQL/application output in both modes,
and measure runtime, CPU, query counts, and coverage before adopting the default.
For isolated service workers, test stubs use the service's canonical configured
URL. Preserve network blocking and the intended simulated response rather than
contacting a shared development service.

## Open decisions

Use observed timing artifacts to refine balancing if source-size estimates cause
material skew. Broader shared-setup adoption requires direct profiles and isolation
evidence; do not globally bypass callbacks, tenant checks or validation.

## Reducing repeated work

CLI listing, help and invalid-argument checks run before Rails boot. Provider
metadata lives in one Rails-independent catalog shared with Runner; actual smoke
execution still delegates to the existing RSpec entry point, which boots Rails.
Apple preflight and project lookup retain Rails and database checks.

Reuse stable persisted setup graphs in profiled hotspot groups with the installed
test-prof `let_it_be` recipe and `refind: true`. Normal factories create the graph
inside a group transaction; each example refetches fresh model instances and
rolls its mutations back. Provisioning and command-execution scenarios share
project setup. Other cases retain lazy per-example setup. Preserve the existing system
access context during group initialization. Keep issues, agent runs and
scenario-specific records/settings per example, including creation overrides
under active-run uniqueness constraints. Preserve association identity within
each example. Do not share mutable model objects or disable callbacks/validations.

Prompt seed specs load the actual application default seed script once in a
test-prof group transaction. Per-example transactions isolate mutations; a
repeated synchronization check verifies stable prompt/version identities. The
PR scanner shares only its baseline project graph with its existing settings,
using fresh records per example instead of replaying a FixtureKit SQL snapshot.
Keep scenario-specific issues, runs, projects and configuration changes local
to each example. FactoryBot remains the record builder; no global seed dataset
or new data framework is required for these optimizations.

Focused Apple live-validation examples inject a subset of the actual scenario
matrix through the existing suite port, retaining network, capacity and reporting
evidence scaffolding. Keep a full default-suite integration
example to verify all scenario IDs and repeat counts. Capacity checks retain
the functional work that collects their samples; recovery checks retain their
real persistence and cleanup choreography.

Shell availability checks need only persisted authorization and clone-manifest
metadata. Create filesystem workspaces only for execution and path-validation
checks, with cleanup that never evaluates unused lazy setup.

HTTP retry tests record delays by replacing the external Faraday retry
middleware's timer. Keep real middleware, HTTP response sequences, retry counts,
backoff configuration and exhaustion behavior. Production timing is unchanged.

Profile model, queue and request factory cascades before selecting further shared
graphs. Reuse stable request account/user/credential/project configuration only
where overrides preserve its dependencies. Keep scenario records and roles per
example, and verify graph mutation isolation. Do not disable callbacks or alter
global factory defaults to reduce counts.

Queue host-saturation setup reuses one project per generated load batch. Host
occupancy retains a distinct active run and issue for every requested slot;
other accounts and independently constructed batches remain separate.

Auto-pick candidate selection and dashboard statistics specs reuse their stable
project configuration through group transactions and fresh per-example instances.
Candidate projects retain auto-pick enablement from creation. Dashboard accounts
and projects retain their original factory ownership relationships. Scenario
issues, runs, role changes, owner settings, and secondary projects remain local
to each example; isolation checks mutate configuration and create scenario rows
to verify that the next example starts clean.

Inbox queue and request specs share their matching baseline account, user and
project configuration. Project requests share only the baseline account and
user; request-created projects, credentials and nested actor overrides remain
per example. Agent-run creation activities share their Ruby project, retaining
per-example issues, runs, routing changes and owner settings. Fresh instances
and explicit association rebinding preserve each example's account and actor
identity.

Failure marking, pull-request creation, and issue-analysis activity specs reuse
an uncustomized project through the existing stable project context. Customized
nested project and owner overrides remain per example. The context also serves
provisioning scenarios; its generic name reflects the shared factory contract.
All business callbacks and rendering remain enabled in these measurements.

Anomaly-detection checks for the same token outlier can inspect persistence,
classification, logging, and notification from one detection. Keep cost, duration,
severity boundaries, stale baselines, and guardrail scenarios independent. The
historical runs still use normal factories in each retained example.
Effective-provider value tests instantiate a run directly because they only
exercise attribute normalization; the legacy alias integration retains a
persisted run and verifies its effective provider after reloading.

Prometheus status-matrix specs reuse seven distinct project/account graphs,
refinding each project per example. Runs, issues and scenario-specific terminal
records remain per example, preserving aggregation across accounts and mutation
rollback. Cache clearing and real collector queries remain enabled.

Git operations, partial-closeout analysis, dependency parsing, issue creation,
existing-PR completion, and issue enhancement reuse uncustomized project
configuration through the stable project context. Auto-pick service specs use
the enabled project variant. Installation, upstream-target, owner, and other
customized nested project overrides remain per example. Issues, runs, routing
credentials, comments, and scenario settings retain their per-example lifetime.

Simple status-scope checks use one persisted matrix across two projects and
accounts. Each named scope is checked against competing statuses, and by_status
is checked for every matrix entry. Active and finished membership use explicit
expected sets. Specialized claim, recovery, timeout, synthetic-run, and tenant
cases remain independent; all matrix rows use normal status factory traits.

## Prepared query plans

Repeated closeout-candidate checks use a scalar ID lookup and a bound evidence
predicate so ActiveRecord can prepare the statement. Retain the original open
state, evidence, project, hold and in-flight-work filters. A restricted-role
regression reuses the actual candidate statement across tenant A/B/A under a
generic plan; normal execution keeps PostgreSQL's automatic plan selection.

The default PostgreSQL test connection uses prepared statements, matching normal
Rails connection behavior. Reusing query plans avoids repeating planning work
across factory callbacks and service queries. Cached statements must continue to
read tenant context at execution time; an uncached client query warmed across
account changes verifies the server-side statement is reused with correct rows.
That regression forces generic planning only inside its test transaction and
checks the server reports at least eighteen executions of the generic plan;
normal connection plan selection remains unchanged.
Schema-mutating specs must keep statement and model-schema caches coherent at
their own mutation boundaries. Do not restore a suite-wide prepared-statement
opt-out to mask a local fixture problem. Existing complete DATABASE_URL routing,
transactional fixtures, callbacks, RLS roles and the aggregate coverage gate
remain authoritative.
