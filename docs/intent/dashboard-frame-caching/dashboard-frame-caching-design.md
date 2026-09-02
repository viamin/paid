# Design: Dashboard Frame Caching

> Segment: dashboard-frame-caching · Status: implemented
> Specs: [dashboard-frame-caching-specs.md](dashboard-frame-caching-specs.md)

## Problem

The dashboard loads ~13 tiles as deferred turbo-frames (staggered by
`dashboard-frames` to protect small Puma pools). Every visit shows skeleton
pulses that pop into content one-by-one — UI thrash that makes the page feel
slow even when the underlying data is unchanged.

The same page also shows a continuous "Live" ping in the header. Without a
reduced-motion alternative, motion-sensitive operators still see perpetual
animation on a dense operational screen.

## Approach

Stale-while-revalidate, entirely inside the existing `dashboard-frames`
Stimulus controller (`app/javascript/controllers/dashboard_frames_controller.js`):

1. **Hydrate** — on `connect()`, each deferred frame (no `src` attribute)
   renders instantly from `sessionStorage` under the key
   `dashboard-frame:v1:{account_id}:{user_id}:{frame_id}:{src}`. Cache misses
   keep the server-rendered skeleton.
2. **Indicate staleness** — hydrated frames get `opacity-60` +
   `transition-opacity` until fresh content lands, so cached data is never
   mistaken for live data.
3. **Revalidate** — the existing stagger loads each frame's deferred `src`;
   on `turbo:frame-load` the fresh HTML replaces the cache entry and the dim
   is removed.

## Decisions

- **`sessionStorage`, not `localStorage`** — cache lives per tab session;
  closing the tab drops all cached tenant data. No cross-session persistence.
- **Scope = account + user id** — `queue_preview` and `eligibility_breakdown`
  render per-user data (their Rails cache keys already namespace by user), so
  the client cache must too. A blank scope disables caching entirely
 (fail-safe for future reuse of the controller).
- **Version token in the prefix (`v1`)** — bump when tile markup shape
  changes so stale-structure entries are ignored (the repo cache
  invalidation strategy rule).
- **Turbo snapshot restores are skipped** — frames that already carry `src`
  (back navigation, live-stream replacement) keep their rendered content:
  hydrating them would clobber fresher snapshot markup with older cache, and
  they never re-enter the stagger, so a dim would never clear.
- **Only the deferred `src` response is cached** — if in-frame navigation
  (filter links, cancel forms) changes the frame URL, the response is not
  written to the cache, preventing wrong-content poisoning.
- **`turbo:frame-missing` releases the queue and keeps stale content** —
  HTTP errors and expired-session redirects render a page without the
  matching frame and fire no load/error event; without handling, the whole
  stagger would wedge forever. When a stale copy is showing, its default
  (Turbo's "Content missing") is prevented; nothing is cached.
- **Storage failures degrade to skeletons** — private mode and quota errors
  are caught; the dashboard behaves exactly as before the feature.
- **Reduced-motion users get static affordances** — the header live indicator
  and skeleton placeholders keep their visual structure but disable pulse/ping
  animation when the browser advertises `prefers-reduced-motion`.

## Testing

- `spec/lib/dashboard_frames_controller_node_harness_spec.rb` — Node harness
  (ThemeControllerNodeHarness pattern) covering hydration, dim/undim,
  revalidation, scope isolation, navigation guard, error paths, restore skip,
  and storage failure degradation.
- `spec/requests/dashboard_spec.rb` — asserts the cache scope value renders
  with account + user id, and that dashboard loading/live indicators render
  motion-safe/motion-reduce classes.
