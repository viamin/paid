# frozen_string_literal: true

# Single source of truth for the visual + structural rules shared by the
# Inbox (`/inbox`, `/inbox/:id`) and Chat (`/chat`, `/chat/:id`)
# list-and-detail surfaces. Both pages render through
# `app/views/shared/_list_detail_shell.html.erb` and call the helpers here
# so the pane widths, breakpoint, gap, pane chrome, empty state, and
# selected-row treatment stay in lockstep. A future change to any of those
# rules is a single edit in this file.
#
# @spec LIST-DETAIL-001 @spec LIST-DETAIL-002 @spec LIST-DETAIL-003
# @spec LIST-DETAIL-004 @spec LIST-DETAIL-005
module MasterDetailLayoutHelper
  # Width of the list pane on desktop. Matches the existing inbox and chat
  # layouts (`22rem`) so this helper is a refactor with no visible change.
  # Documents the value baked into `MASTER_DETAIL_GRID_CLASSES` below; kept
  # as a separate constant rather than interpolated into that string
  # because Tailwind's CSS build scans source files as plain text for
  # complete utility class names and never executes Ruby, so an
  # interpolated arbitrary-value class is invisible to the scanner and the
  # whole utility silently never makes it into the compiled CSS.
  MASTER_DETAIL_LIST_PANE_WIDTH = "22rem"

  # Selected row treatment applied by both Inbox's row link and Chat's
  # session card when the row is the active entry. Picked `indigo-50` to
  # match the rest of the page's primary brand color; the previous
  # `border-sky-400 bg-sky-50 shadow-md` on Chat and bare `bg-indigo-50`
  # on Inbox have been unified here.
  MASTER_DETAIL_ACTIVE_ROW_CLASSES = "bg-indigo-50 ring-1 ring-inset ring-indigo-200".freeze

  # Shared chrome applied to both the list pane card and the detail pane
  # card so the two halves of the surface read as one unit. `rounded-xl`
  # matches the existing inbox pane chrome; chat's container switches from
  # `rounded-lg bg-white shadow` to this shared chrome.
  MASTER_DETAIL_PANE_CLASSES = "overflow-hidden rounded-xl border border-gray-200 bg-white shadow-sm".freeze

  # Empty-state card rendered in the detail pane slot when there is no
  # selection. Both Inbox ("Inbox clear") and Chat ("No conversation
  # selected") use this same chrome so the no-selection visit reads the
  # same as a populated one.
  MASTER_DETAIL_EMPTY_STATE_CLASSES =
    "rounded-xl border border-dashed border-gray-300 bg-white px-6 py-12 text-center shadow-sm".freeze

  # CSS grid wrapper around the two panes. Single source of truth for the
  # `22rem` fixed list track and the `minmax(0,1fr)` flexible detail track
  # — Tailwind underscores become spaces, so this compiles to
  # `grid-template-columns: 22rem minmax(0,1fr)`, a valid CSS declaration
  # (a top-level comma in a track list is a parse error the browser drops
  # entirely, leaving both panes stacked as one column). The `minmax(0,1fr)`
  # on the detail track also keeps long unbreakable content in the detail
  # pane from blowing out the flexible track. Combined with the `gap-6`
  # inter-pane spacing, both inbox and chat pages render through
  # `_list_detail_shell` and pick up this exact class string.
  #
  # Written as a literal string rather than interpolating
  # `MASTER_DETAIL_LIST_PANE_WIDTH` — see the note on that constant.
  MASTER_DETAIL_GRID_CLASSES = "grid gap-6 lg:grid-cols-[22rem_minmax(0,1fr)]".freeze

  def master_detail_grid_classes
    MASTER_DETAIL_GRID_CLASSES
  end

  # Pane-card chrome — see `MASTER_DETAIL_PANE_CLASSES`. Returned as a
  # method so future additions (e.g. an opt-in dark variant) can be
  # applied centrally without re-encoding the constant in the views.
  def master_detail_pane_classes
    MASTER_DETAIL_PANE_CLASSES
  end

  # Selected-row class set — see `MASTER_DETAIL_ACTIVE_ROW_CLASSES`.
  # Inbox applies this directly at render time based on its `selected_entry`
  # comparison; Chat renders it into each card's `data-active-classes` and
  # `chat-session-list#updateActiveCard` toggles it on the active card
  # whenever the active session id changes. Both controllers keep
  # `hover:bg-gray-50` mutually exclusive with this set so hovering the
  # selected row never overrides the selection state.
  def master_detail_active_row_classes
    MASTER_DETAIL_ACTIVE_ROW_CLASSES
  end

  # Empty-state chrome — see `MASTER_DETAIL_EMPTY_STATE_CLASSES`. The
  # empty-state copy stays per-feature and is passed into
  # `shared/_list_detail_empty_state` as a local; only the chrome lives
  # here.
  def master_detail_empty_state_classes
    MASTER_DETAIL_EMPTY_STATE_CLASSES
  end
end
