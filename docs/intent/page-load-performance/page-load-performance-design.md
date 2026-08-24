---
parent: PAID
prefix: PAGE-LOAD
---

# Low-Level Design: Page Load Performance

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers page load measurement during PR screenshot capture, the
> per-project load-time ledger and its exported file, before/after regression
> detection, and the opt-in follow-up agent run that fixes a confirmed
> regression.

## Purpose

Paid already drives a real browser through every changed route of a PR to
capture screenshots. That navigation is the expensive part of the pipeline;
timing it is nearly free. This segment turns each screenshot navigation into a
performance sample, keeps the samples as durable per-project history so
regressions and trends are visible across PRs, and — when a PR makes a page it
touched measurably slower — lets the project queue a follow-up agent run to fix
the regression.

## Context and Design Philosophy

Three properties of the measurement environment shape every decision here.

**Measurements are noisy.** Capture runs inside a preview container on a shared
Docker host, against seeded data, with a cold application cache. A single
navigation can vary by tens of percent for reasons that have nothing to do with
the diff. The design answers this in three places: several samples per route
with the median reported, a regression rule that requires both a ratio and an
absolute delta, and a ledger that keeps history so a human (or an agent) can
see whether a spike is a trend or a blip.

**Measurements are evidence, not a gate.** A confirmed regression queues an
agent run that proposes a fix in the PR; nothing here blocks a merge or fails a
check. This follows the HLD's *Human final say* tenet: authority over what
lands stays with the reviewer.

**The record is the source of truth, the file is a projection.** Per the HLD's
*Data over configuration* tenet, each measurement is a row in PostgreSQL. The
single per-project file asked of this feature is regenerated from those rows
after each capture, so concurrent captures on different PRs can never lose each
other's history — the worst case is a momentarily stale file, not a dropped
entry.

## Measurement

### Where it happens

Instrumentation lives in the container capture runner — the JavaScript program
`Screenshots::ContainerCapture` writes into the workspace and executes inside
the preview container. That runner already navigates each route with
Playwright, so it is the only place with access to the browser's own timing
data.

Scope is the agent-run capture path only. The rake/CI capture path
(`Screenshots::Capture` and the `screenshots` branch storage) keeps capturing
screenshots with no timing.

### What is measured

Per route, from the browser's Performance APIs:

| Metric | Source | Meaning |
|---|---|---|
| `ttfb_ms` | `PerformanceNavigationTiming.responseStart` | Server response latency |
| `dcl_ms` | `domContentLoadedEventEnd` | HTML parsed, deferred scripts run |
| `load_ms` | `loadEventEnd` | All subresources loaded |
| `fcp_ms` | `first-contentful-paint` paint entry | First visible content |
| `lcp_ms` | `largest-contentful-paint` observer entry | Main content visible |

All are relative to navigation start and rounded to whole milliseconds.
`lcp_ms` and `fcp_ms` can legitimately be absent (no qualifying paint, observer
never fires); they are recorded as null rather than zero, and a null on either
side of a comparison disqualifies that metric from regression evaluation.

### Sampling

Once per capture — not once per route — the runner performs a single discarded
warm-up navigation to the first route before any sampling. Without it, whichever
route happens to be captured first absorbs application boot, code loading, and
cold database caches, and since route order follows the PR's diff, that penalty
moves between captures and reads as a regression.

Each route is then navigated `SAMPLES` (3) times with timing collected, then
navigated once more with tracing enabled for the screenshot itself. The
reported value per metric is the **median** of the samples; min, max, and the
raw per-sample values are retained so noise is inspectable rather than hidden.

Each route also records the HTTP status of its final measured navigation. A
route that returns 500 or redirects produces timings that look fine in
isolation and mean nothing in comparison, so status travels with the sample and
gates comparison later.

The measured navigations run *before* tracing starts, because Playwright
tracing with screenshots and snapshots inflates load timings by an amount that
varies with page complexity — measuring under trace would make timings
incomparable across projects and across captures where tracing failed to start.

Sampling runs under a per-capture time budget. When the budget is spent,
remaining routes are measured with a single navigation and recorded with a
sample count of one, so a pull request that touches many routes degrades to
noisier data rather than pushing capture past its timeout and losing the
screenshots along with the timings.

There is no dedicated per-route warm-up navigation. Cold-start cost lands in one of the
three samples, where the median discards it; adding a fourth navigation per
route to formalize that costs capture time for no additional signal.

### Handing timings back to the host

The runner writes one JSON document, `page-load-timings.json`, into the
screenshot output directory. The host collects it from the workspace the same
way it collects `.trace.zip` and `.webm` artifacts.

```json
{
  "captured_at": "2026-08-23T18:04:11Z",
  "viewport": { "width": 1280, "height": 900 },
  "routes": {
    "dashboard": {
      "path": "/dashboard",
      "samples": 3,
      "http_status": 200,
      "metrics": {
        "load_ms": { "median": 812, "min": 780, "max": 903, "values": [780, 812, 903] },
        "lcp_ms": { "median": 640, "min": 615, "max": 701, "values": [615, 640, 701] }
      }
    }
  }
}
```

Timing collection is isolated from capture: if the Performance APIs throw or a
route's timings are unavailable, that route's screenshot still succeeds and the
route is simply absent from the document. A missing or unparseable document
degrades the capture to today's behavior — screenshots, no timings — and is
logged rather than raised, since a screenshot comment is still worth posting.

## The ledger

### Record

`page_load_measurements` is a tenant-scoped table under forced row-level
security, one row per route per capture:

- `account_id`, `project_id`, `agent_run_id` — ownership and provenance
- `pull_request_number`, `commit_sha` — which capture this belongs to
- `route_name`, `route_path` — which page, and the path it resolved to
- `http_status` — status of the measured navigation
- `ttfb_ms`, `dcl_ms`, `load_ms`, `fcp_ms`, `lcp_ms` — median values, nullable
- `samples` (jsonb) — raw per-sample values, min/max per metric
- `sample_count`, `viewport_width`, `viewport_height`, `captured_at`

It is an operational table, so it carries no logidze trigger, per the project's
change-tracking policy. Indexes serve the three read paths: trend queries
`(project_id, route_name, captured_at)`, baseline lookup `(project_id,
pull_request_number, route_name, captured_at)`, and run-scoped cleanup
`(agent_run_id)`.

A capture is identified by `(project_id, pull_request_number, commit_sha,
route_name)`, enforced by a unique index: a re-run of capture at the same commit
replaces its earlier measurement rather than appending a second one, so a
retried run does not become its own baseline or double-count in the trailing
median.

Rows are pruned on the same schedule as the screenshots they were captured
alongside — 30 days by default — so the ledger's depth matches the artifacts it
describes.

### Exported file

One file per project, written under the storage namespace the screenshots
themselves live in: `screenshots/{org}/{repo}/page-load-times.json`. Keeping it
inside `Screenshots::Storage.namespace_prefix` means the existing
manifest/re-signing rules cover it unchanged.

The file covers every route with measurements still inside the retention
window, so routes deleted from a project's screenshot config age out of the
export with their measurements rather than lingering.

The file is **regenerated from the table** after each successful capture, not
patched in place. It holds, per route, the most recent 100 entries newest-first
plus a summary block (trailing median, best, worst, and the direction of the
last comparison), so a reader gets both the current state and enough history to
see a trend without querying Paid.

Export requires configured object storage. Without it, measurement and
regression detection still work from the table; only the file is skipped.

## Regression detection

A regression is evaluated per route, comparing this capture against the most
recent earlier capture for the same project, PR, and route at a different
commit — the same before/after pair the screenshot comment already shows.

The comparison is only valid when the two captures measured the same thing.
Three conditions disqualify it, and each reports as "not comparable" rather
than as a result: the route resolved to a different `route_path`, the two
captures returned different HTTP statuses, or the viewport differed. Without
these guards a renamed path, a page that started erroring, or a viewport change
would each surface as a performance finding.

A route is flagged when **both** hold for the comparison metric:

- `current > baseline * (1 + ratio)`, default `ratio` 0.25
- `current - baseline > floor_ms`, default `floor_ms` 150

The ratio alone would flag a 40 ms page that drifted to 55 ms; the floor alone
would ignore a 3 s page that doubled. Requiring both keeps the signal on
regressions a reviewer would care about.

The comparison metric defaults to `lcp_ms`, falling back to `load_ms` when LCP
is null on either side. LCP is the metric closest to what a user perceives;
`load_ms` is the deterministic backstop that is always present.

A route can also lack a baseline mid-PR, because capture is scoped to the
routes in the run's screenshot hints and a route timed on one commit may not be
captured on the next. Whether it is the PR's first capture or a first capture
of that route, the row is recorded, no comparison is made, and the comment says
the baseline is missing rather than implying an improvement.

Findings are rendered into the existing screenshot PR comment as a per-route
before/after table, so performance lands next to the visual before/after it
belongs with. The trailing-median comparison from the ledger is shown as trend
context; only the before/after comparison can trigger a follow-up.

## Follow-up run

Where the project enables it, a confirmed regression on a route the PR actually
touched queues one agent run against the PR branch, carrying the route, the
metric deltas, the sample values, and the PR's changed files.

### How the run is queued

The run is queued through Paid's existing PR follow-up path rather than a
private one. A confirmed regression is persisted as an open finding; the PR
scanner reads open findings for the PR's head commit and emits a
`page_load_regression` trigger, which maps to a new `performance_regression`
focus. The focused-run machinery then applies unchanged: focus priority
resolution places it below the correctness-oriented focuses (merge conflict, CI
failure, review feedback, conversation), the scanner's existing per-PR
suppression prevents a second run while one is queued or running, and the
prompt builder emits the single scoped section for that focus with everything
else deferred.

The boundary is drawn at the trigger: this segment decides *whether a finding
warrants a trigger*; `focused-agent-runs` owns *what the trigger maps to and
where it sits in focus priority*. One emitter, one mapper.

This crosses a segment boundary by design: `focused-agent-runs` owns the focus vocabulary, its
resolution, the scoped prompt section, and focus-weighted quality scoring. This
segment owns the finding and the trigger; that segment owns how a focused run
is shaped, and it takes the cascade.

The evidence the prompt needs — route, metric, before/after values, sample
spread, changed files — is persisted on the finding and copied onto the queued
run's metadata, so the prompt is built from a stable record rather than
re-measuring or re-querying at prompt time.

### One finding per route

A pull request holds at most one open finding per route. A later capture that
still shows the route regressed updates the existing finding with the newer
comparison rather than opening a second one, so the follow-up run targets a
single current statement of the problem.

Whether a finding is *actionable* — eligible to trigger work — is decided when
it is created, from the screenshot hints of the capture that produced it. The
hints are the capture run's derivation of which routes this pull request's diff
touches, and they are not available to the scanner later. Findings for routes
the pull request did not touch are recorded and reported with the flag unset.

### When a finding closes

A finding stays open until a later capture on a newer commit evaluates the same
route within threshold, at which point it resolves. A finding whose route is no
longer captured on newer commits is superseded rather than left open forever,
so a PR does not accumulate stale performance work.

Two gates narrow this deliberately:

- **Only touched routes.** The ledger records every captured route; only routes
  present in the run's screenshot hints — the routes derived from this PR's
  diff — are eligible to trigger work. A regression on an untouched route is
  recorded and reported, not acted on.
- **Opt-in per project.** `screenshot_settings["performance"]["followup_enabled"]`
  defaults to false. Measurement (`performance.enabled`) defaults to true for
  projects with screenshots enabled, because history is only useful once it has
  accumulated and it costs three navigations per route.

At most one performance follow-up run is queued per PR per commit; an existing
queued or running follow-up suppresses a new one.

## Configuration

Under `screenshot_settings["performance"]`:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Measure load times during capture |
| `followup_enabled` | `false` | Queue a follow-up run on confirmed regression |
| `comparison_metric` | `"lcp_ms"` | Metric compared for regressions |
| `regression_ratio` | `0.25` | Fractional slowdown required to flag |
| `regression_floor_ms` | `150` | Absolute slowdown required to flag |
| `samples` | `3` | Measured navigations per route |

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
|---|---|---|---|
| Source of truth | PostgreSQL table; file regenerated from it | Single JSON in object storage as the only record; per-capture shards plus a rollup | Object storage has no compare-and-swap, so concurrent captures on different PRs would silently drop each other's history in a read-modify-write. Regenerating from rows makes the file lossless and keeps trends queryable in SQL. |
| Metric set | TTFB, DCL, load, FCP, LCP | Wall-clock navigation time only | Wall clock says a page got slower but not where; the breakdown is what makes a follow-up agent's job tractable — server time and paint time point at different code. |
| Samples per route | 3, report median | 1 sample; 5+ samples with a warm-up | One sample in a shared container is too noisy to act on. Three is the smallest count with a meaningful median; each additional sample costs a navigation on every route of every capture. |
| Measure before tracing | Timed navigations run with tracing off | Time the traced navigation that produces the screenshot | Trace capture inflates load timings unevenly, and tracing sometimes fails to start — timings would not be comparable between captures. |
| Regression rule | Ratio **and** absolute floor | Ratio only; absolute only; statistical test over history | Ratio-only flags trivial drift on fast pages; absolute-only ignores a doubled slow page. A statistical test needs more samples per capture than the pipeline can afford. |
| Baseline | Previous capture on the same PR | Trailing median of the default branch | Matches the before/after pair the screenshot comment already shows, and attributes the change to this PR's diff. The trailing median is still exported as trend context. |
| Comparison metric | LCP, falling back to load | Always load; always LCP | LCP is closest to perceived speed but is legitimately absent on some pages; falling back keeps every route comparable. |
| Export retention | Last 100 entries per route | Full history; 90-day window | Keeps the file small and diffable while the table keeps everything. A count window is stable regardless of PR volume. |
| Capture paths covered | Agent-run container path only | Also the rake/CI path with branch storage | The rake path has no per-project record and no follow-up mechanism, so timings there would be write-only. Adding it later is additive. |
| Follow-up queueing | Open finding → scanner trigger → `performance_regression` focus | A private queue service creating a `create_pr` run with a custom prompt; reusing the `review_feedback` focus | The scanner path already owns per-PR suppression, quality-gate admission, and single-problem prompt scoping; a private service would reimplement all three. Reusing `review_feedback` would mislabel run provenance in metrics and emit a prompt section that does not describe the task. |
| Capture identity | Unique on (project, PR, commit, route); re-capture replaces | Append every capture | A retried run at the same commit would otherwise become its own baseline and skew the trailing median. |
| Invalid comparisons | Disqualify on path, HTTP status, or viewport change | Compare regardless and let the reviewer judge | A renamed path, a newly-erroring page, and a viewport change each produce a large, meaningless delta — reporting them as findings trains reviewers to ignore real ones. |
| Warm-up | One discarded navigation per capture | None; one per route | Application boot lands on whichever route the diff happens to put first, so the bias moves between captures. One navigation per capture removes it; one per route pays the cost N times for the same effect. |
| Measurement retention | Prune with the screenshots, 30 days | Keep forever | The ledger describes artifacts that expire; keeping measurements past them leaves history no one can look at. |
| Follow-up default | Off | On for every screenshot-enabled project | Thresholds need tuning against real data per project; spending runner budget on unvalidated signal violates *No silent stops* in the wrong direction — noisy runs train reviewers to ignore them. |

## Open Questions & Future Decisions

### Deferred

1. Extending measurement to the rake/CI capture path and the `screenshots`
   branch, for projects without object storage.
2. Measuring the pages an agent verification run visits. Paid provisions that
   browser container but does not drive it — the agent navigates through a
   third-party `playwright-mcp` server, so there is no point at which Paid can
   time a navigation or attach route identity to it. Reaching the data would
   mean either an out-of-band CDP collector (URL-keyed, agent-chosen pages, no
   sampling control) or owning a fork of the upstream MCP server.
3. Normalizing measurements for host load (a calibration benchmark per capture)
   so timings are comparable across Docker hosts of different sizes.
4. Surfacing trends in the Paid UI; today the export file and the PR comment
   are the read surfaces.

## References

- `docs/intent/live-web-app-preview/live-web-app-preview-design.md` — the
  preview/capture foundations this measurement rides on
- `docs/intent/artifact-storage/artifact-storage-design.md` — the storage
  abstraction the exported file uses
- `docs/intent/focused-agent-runs/focused-agent-runs-design.md` — how
  single-problem PR follow-up runs are scoped
