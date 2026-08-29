# EARS Specs: Dashboard Frame Caching

> Testable claims for the dashboard tile stale-while-revalidate cache.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r DASHBOARD-FRAME-CACHE-001`).

- [x] **DASHBOARD-FRAME-CACHE-001** — When the dashboard loads and a deferred
  tile frame has a cached copy for the current scope and src, the system
  SHALL render the cached HTML immediately in place of the loading skeleton,
  without triggering a network load.
  *Code:* `app/javascript/controllers/dashboard_frames_controller.js` (`hydrateFromCache`).
  *Test:* `spec/lib/dashboard_frames_controller_node_harness_spec.rb`.

- [x] **DASHBOARD-FRAME-CACHE-002** — While a tile displays cached content
  awaiting revalidation, the system SHALL visually distinguish it as stale;
  when fresh content loads, the distinction SHALL be removed. When
  revalidation fails (fetch error or missing frame), the stale distinction
  SHALL persist.
  *Code:* `dashboard_frames_controller.js` (`STALE_CLASSES`, `onFrameSettled`,
  `onFrameMissing`).
  *Test:* `spec/lib/dashboard_frames_controller_node_harness_spec.rb`.

- [x] **DASHBOARD-FRAME-CACHE-003** — When a deferred tile finishes loading its
  own deferred src, the system SHALL store the tile HTML in sessionStorage
  under a key composed of a cache version, the cache scope, the frame id, and
  the frame src. Content loaded under a different frame URL (in-frame
  navigation) SHALL NOT be stored.
  *Code:* `dashboard_frames_controller.js` (`cacheKey`, `cacheFrame`).
  *Test:* `spec/lib/dashboard_frames_controller_node_harness_spec.rb`.

- [x] **DASHBOARD-FRAME-CACHE-004** — When sessionStorage is unavailable or
  throws (private mode, quota exceeded), the system SHALL degrade to
  skeleton-first behavior without raising or breaking page load.
  *Code:* `dashboard_frames_controller.js` (`hydrateFromCache`, `cacheFrame`).
  *Test:* `spec/lib/dashboard_frames_controller_node_harness_spec.rb`.

- [x] **DASHBOARD-FRAME-CACHE-005** — The cache scope SHALL include the
  current account id and current user id, and a blank scope SHALL disable
  caching, so cached per-user tiles (e.g. queue preview, eligibility
  breakdown) are never hydrated for a different account or user.
  *Code:* `dashboard_frames_controller.js` (`cacheScopeValue`),
  `app/views/dashboard/show.html.erb`.
  *Test:* `spec/requests/dashboard_spec.rb`,
  `spec/lib/dashboard_frames_controller_node_harness_spec.rb`.

- [x] **DASHBOARD-FRAME-CACHE-006** — When the dashboard is restored from a
  Turbo snapshot (back navigation) or a tile frame already carries a src, the
  system SHALL leave the frame's rendered content untouched and SHALL NOT
  hydrate from the cache or apply the stale distinction.
  *Code:* `dashboard_frames_controller.js` (`connect`).
  *Test:* `spec/lib/dashboard_frames_controller_node_harness_spec.rb`.

- [x] **DASHBOARD-FRAME-CACHE-007** — When a tile response renders a page
  without the matching frame (HTTP error or expired-session redirect), the
  system SHALL keep already-cached stale content (preventing the fallback
  only in that case), SHALL continue loading remaining tiles, and SHALL NOT
  cache the replacement page.
  *Code:* `dashboard_frames_controller.js` (`onFrameMissing`).
  *Test:* `spec/lib/dashboard_frames_controller_node_harness_spec.rb`.

- [x] **DASHBOARD-FRAME-CACHE-008** — The dashboard loading placeholders and
  live indicator SHALL respect reduced-motion preferences by limiting pulse and
  ping animations to motion-safe contexts and rendering them static otherwise.
  *Code:* `app/views/dashboard/show.html.erb`.
  *Test:* `spec/requests/dashboard_spec.rb`.
