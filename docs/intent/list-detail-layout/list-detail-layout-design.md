# Design: Shared List-and-Detail Layout

> Segment: list-detail-layout · Status: implemented
> Specs: [list-detail-layout-specs.md](list-detail-layout-specs.md)
> Consumers: [operator-inbox](../operator-inbox),
> [api-mode-chat](../api-mode-chat)

## Problem

Paid exposes two parallel list-and-detail surfaces today:

- **Inbox** (`/inbox`, `/inbox/:entry_id`) — operator queue of human-actionable
  work, with a route-based master-detail mobile flow (`OPERATOR-INBOX-003`).
- **Chat sessions** (`/chat/:id`, `/chat`) — open-ended conversations, with a
  mobile overlay drawer for the session list.

Both screens share a desktop split-pane layout (22rem list + 1fr detail at
`lg` ≥1024px) but encode that layout independently. The pane widths, the
`gap-6` inter-pane spacing, the active-row treatment, the empty-state card,
and the pane-card chrome are duplicated across the two views and their
partials. Drift between the two screens has already happened:

- Inbox selected rows are highlighted with `bg-indigo-50`; chat session cards
  are highlighted with `border-sky-400 bg-sky-50 shadow-md`. Two different
  color schemes for the same interaction state.
- Inbox uses `gap-6` between panes; chat uses `gap-4 lg:gap-6`.
- Inbox renders its list rows inside a flat `<ul>` with no per-row border;
  chat renders each session as a standalone rounded card. The pane chrome
  differs in `rounded-xl` vs `rounded-lg` and `shadow-sm` vs `shadow`.

A change to the shared layout rule — adjust the breakpoint, narrow the list
column, change the active row color, or restyle the empty card — has to be
applied twice, and the second application tends to forget one of the three
or four spots the rule shows up in two views.

## Approach

Define one maintained UI pattern — a `MasterDetail::Pane` shell — that
encodes the shared rules and have both Inbox and Chat render through it.
Feature-specific content, controls, and interaction state stay in each
feature's own partials and controllers; only the layout rules move to the
shared pattern.

The pattern has three pieces:

1. **`MasterDetailLayoutHelper`** — the single source of truth for the
   shared class strings and structural constants. Both pages consume these
   helpers; a future tweak to the breakpoint, gap, pane width, active-row
   treatment, or pane chrome lands here and propagates to both.
2. **`app/views/shared/_list_detail_shell.html.erb`** — the shared partial
   that wraps the two panes in the grid and renders the empty-state card
   when there is no selected entry. Both pages render through this partial
   so the pane proportions, spacing, breakpoint, and empty state stay in
   lockstep.
3. **Active-row class set** — a single class string the list-row markup on
   each page applies when the row is the selected entry, replacing the
   two divergent treatments (indigo background vs. sky background+shadow)
   with one.

The mobile behavior stays per-feature:

- Inbox keeps the route-based master-detail flow (`/inbox` vs.
  `/inbox/:entry_id`, `Back to queue` link) wired through
  `inbox-master-detail` (`OPERATOR-INBOX-003`).
- Chat keeps the overlay drawer for the mobile session list
  (`chat-session-list`, search input, "Previous chats" toggle).

The shared pattern is layout-only; it does not unify the mobile interaction
model. Inbox is still a queue of human-actionable work; Chat is still
open-ended conversation. Routes, queues, records, and actions are not
touched.

## Shared rules

A change to any of these rules is now a one-line edit in
`MasterDetailLayoutHelper`. Each rule records the prior visible divergence it
replaces.

| Rule | Value | Previously |
|------|-------|-----------|
| Desktop breakpoint | `lg` (≥1024px) | same on both |
| List pane width | `22rem` | same on both |
| Inter-pane gap | `gap-6` | `gap-6` (inbox) vs. `gap-4 lg:gap-6` (chat) |
| Grid template | `grid lg:grid-cols-[22rem_minmax(0,1fr)]` | same on both |
| Pane card chrome | `overflow-hidden rounded-xl border border-gray-200 bg-white shadow-sm` | `rounded-xl border ... shadow-sm` (inbox) vs. `rounded-lg bg-white shadow` (chat) |
| Active row treatment | `bg-indigo-50 ring-1 ring-inset ring-indigo-200` | `bg-indigo-50` (inbox) vs. `border-sky-400 bg-sky-50 shadow-md` (chat) |
| Empty state | `rounded-xl border border-dashed border-gray-300 bg-white px-6 py-12 text-center shadow-sm` | per-screen |

Active-row color picks `indigo-50` (the primary brand color used elsewhere
on the page) because both surfaces live in a UI that already uses indigo
for the active nav item, primary buttons, and selected state badges. Chat
moving from sky to indigo is a small visible change on the selected session
card; the unification is the point.

## Decisions

- **Layout rules shared, not interaction rules.** Inbox keeps route-based
  master-detail on mobile (`/inbox/:id` swaps the pane via Turbo + Stimulus
  visibility), Chat keeps overlay drawer. Forcing the same mobile behavior
  on both would either break Chat's search-and-archive flow or break
  Inbox's deep-link-friendly member-route state. The shared pattern is
  visual + structural.
- **Selected row treatment is a single class set, not a feature color.**
  Both pages already had "selected" rows; the shared rule is what those
  selected rows look like, not whether they exist.
- **Pane card chrome is one shared class.** `rounded-xl border
  border-gray-200 bg-white shadow-sm overflow-hidden` matches Inbox's
  current chrome. Chat's container switches from `rounded-lg bg-white
  shadow` to the shared chrome; the difference is a small visual tightening
  that brings the chat conversation card into line with the rest of the
  detail pane.
- **No new shared Stimulus controller.** The mobile master-detail flow on
  Inbox (`inbox-master-detail`) and the mobile drawer on Chat
  (`chat-session-list`) are genuinely different behaviors with different
  responsibilities; unifying them would either bloat the shared controller
  with a flag-driven mode switch or paper over the difference. The visual
  rules are constants and class strings, not state machines.

## Testing strategy

- `spec/helpers/master_detail_layout_helper_spec.rb` covers the shared class
  strings and constants stay aligned: pane width, breakpoint, gap, active
  row, empty state, pane chrome. A future edit that drifts the values is
  caught here.
- `spec/system/dashboard_inbox_spec.rb` and the existing inbox system specs
  cover the rendered grid + active row + empty state on Inbox.
- `spec/system/chat_layout_spec.rb` and a new chat system spec cover the
  rendered grid + active row + empty state on Chat.
- The existing per-feature behavior tests
  (`inbox_chat_popup_spec`, `chat_session_list_controller_node_harness_spec`)
  stay green; the shared pattern does not alter the per-feature Stimulus
  lifecycle. The chat node harness also covers
  `chat-session-list#updateActiveCard` toggling the shared active-row set
  and keeping `hover:bg-gray-50` exclusive with it, mirroring
  `inbox-master-detail#highlightRow`.

## LID anchors

- **HLD →** [high-level-design.md](../../high-level-design.md) ·
  *Section: "No silent stops" + "Coherent Paid interface"* — both Inbox and
  Chat are first-class operator surfaces and must read as one product.
- **LLD →** [operator-inbox](../operator-inbox/operator-inbox-design.md) ·
  *Layout* section. **LLD →** chat sessions LLD (pending) · *Layout*
  section. Both anchor on this design for the shared two-pane shell.
- **Specs →** [list-detail-layout-specs.md](list-detail-layout-specs.md) ·
  `LIST-DETAIL-001`–`LIST-DETAIL-006`. Existing inbox and chat specs
  (`OPERATOR-INBOX-003`, `CHAT-API-008`/`CHAT-API-009`) reference this
  segment for the shared visual rules.
