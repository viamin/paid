# EARS Specs: Shared List-and-Detail Layout

> Visual + structural rules shared by the Inbox and Chat list-and-detail
> screens. Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r LIST-DETAIL-001`).

- [x] **LIST-DETAIL-001** — When Inbox or Chat renders its two-pane surface
  on a viewport `≥1024px` wide, the system SHALL lay out the panes as a
  single CSS grid with a `22rem` left pane (the list) and a `1fr` right pane
  (the detail), separated by `gap-6`. Below `1024px` the panes SHALL stack,
  and the page-level behavior falls back to the feature's own mobile flow
  (Inbox: route-based master-detail; Chat: overlay drawer).
  *Code:* `app/helpers/master_detail_layout_helper.rb`,
  `app/views/shared/_list_detail_shell.html.erb`,
  `app/views/inbox/index.html.erb`,
  `app/views/chat_sessions/index.html.erb`,
  `app/views/chat_sessions/show.html.erb`.
  *Test:* `spec/lib/master_detail_layout_helper_spec.rb`,
  `spec/system/dashboard_inbox_spec.rb`, `spec/system/chat_layout_spec.rb`.

- [x] **LIST-DETAIL-002** — The two-pane shell SHALL render the list pane
  and the detail pane inside cards that share the same chrome
  (`overflow-hidden rounded-xl border border-gray-200 bg-white shadow-sm`)
  so the two halves of the surface read as one unit. The empty state for an
  no-selection visit SHALL render in the detail pane slot as
  `rounded-xl border border-dashed border-gray-300 bg-white px-6 py-12
  text-center shadow-sm` so it visually matches the populated state.
  *Code:* `app/helpers/master_detail_layout_helper.rb`,
  `app/views/shared/_list_detail_shell.html.erb`,
  `app/views/shared/_list_detail_empty_state.html.erb`.
  *Test:* `spec/lib/master_detail_layout_helper_spec.rb`,
  `spec/system/dashboard_inbox_spec.rb`.

- [x] **LIST-DETAIL-003** — When a list row is the selected entry on Inbox
  or Chat, the row SHALL carry the shared active-row class set
  (`bg-indigo-50 ring-1 ring-inset ring-indigo-200`) so both screens render
  the same active state and a future tweak to the active-row treatment can
  be made in one place. The active class SHALL be applied at render time
  via the same helper (`MasterDetailLayoutHelper#master_detail_active_row_classes`)
  on both pages; Chat's existing JS-driven selection update keeps doing the
  same toggle on top of the shared class set.
  *Code:* `app/helpers/master_detail_layout_helper.rb`,
  `app/views/dashboard/_inbox_list.html.erb`,
  `app/views/chat_sessions/_session_card.html.erb`,
  `app/javascript/controllers/chat_session_list_controller.js`.
  *Test:* `spec/requests/inbox_spec.rb`,
  `spec/requests/chat_sessions_spec.rb`,
  `spec/system/dashboard_inbox_spec.rb`.

- [x] **LIST-DETAIL-004** — `MasterDetailLayoutHelper` SHALL expose the
  shared class strings (`master_detail_grid_classes`,
  `master_detail_pane_classes`, `master_detail_active_row_classes`,
  `master_detail_empty_state_classes`) and the structural constant
  `MASTER_DETAIL_LIST_PANE_WIDTH` as constants so a future layout-rule
  change is a single edit and the values stay aligned between the helper,
  the shared partial, and the per-feature views that consume it. The
  desktop split-pane breakpoint (`1024px`) is encoded as Tailwind's `lg:`
  prefix on the grid wrapper and as the
  `window.matchMedia("(min-width: 1024px)")` media queries consumed by
  `inbox-master-detail` and `chat-session-list`; the Tailwind config and
  the two media-query literals are the live sources of truth for that
  value (and are deliberately mirrored — the helper does not re-export it
  so changing it does not silently drift one of the three call sites).
  *Code:* `app/helpers/master_detail_layout_helper.rb`.
  *Test:* `spec/lib/master_detail_layout_helper_spec.rb`.

- [x] **LIST-DETAIL-005** — The shared `_list_detail_shell` partial SHALL
  render the empty-state card when the `detail` local is blank and an
  `empty_title` local is present, and the per-feature pages SHALL pass the
  empty-state copy and the list/detail content as locals so the
  layout-rule markup stays in one file and the feature-specific copy stays
  in the feature.
  *Code:* `app/views/shared/_list_detail_shell.html.erb`,
  `app/views/shared/_list_detail_empty_state.html.erb`,
  `app/views/inbox/index.html.erb`,
  `app/views/chat_sessions/index.html.erb`.
  *Test:* `spec/lib/master_detail_layout_helper_spec.rb`,
  `spec/system/dashboard_inbox_spec.rb`.

- [x] **LIST-DETAIL-006** — Inbox and Chat SHALL keep their distinct
  content, controls, and interaction state: Inbox's
  `inbox-master-detail` controller and `/inbox/:id` route-based
  master-detail flow (`OPERATOR-INBOX-003`), and Chat's
  `chat-session-list` controller and overlay drawer with search input,
  remain feature-specific. The shared list-and-detail layout SHALL NOT
  unify the mobile interaction model; it unifies only the desktop grid,
  pane chrome, pane widths, gap, empty state, and selected-row treatment.
  *Code:* `app/views/inbox/index.html.erb`,
  `app/views/chat_sessions/index.html.erb`,
  `app/javascript/controllers/inbox_master_detail_controller.js`,
  `app/javascript/controllers/chat_session_list_controller.js`.
  *Test:* `spec/requests/inbox_spec.rb`,
  `spec/requests/chat_sessions_spec.rb`,
  `spec/system/inbox_chat_popup_spec.rb`,
  `spec/lib/chat_session_list_controller_node_harness_spec.rb`.
