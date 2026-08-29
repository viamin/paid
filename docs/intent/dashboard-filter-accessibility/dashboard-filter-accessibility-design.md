---
parent: PAID
prefix: DASHBOARD-FILTER-A11Y
---

# Low-Level Design: Dashboard Filter Accessibility

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers exposing the selected state of dashboard filter link
> controls (time range, status, goal type) to assistive technology.

## Problem

`app/views/dashboard/_metrics.html.erb` and `app/views/dashboard/_performance.html.erb`
render filter controls as `<a>` tags styled via `DashboardHelper#filter_button_classes`.
The active filter is only distinguished visually (indigo background vs. white
with a gray ring) — there is no `aria-current` or other semantic marker, so
keyboard and screen reader users navigating the links cannot tell which time
range, status, or goal filter is currently selected.

## Approach

Add `DashboardHelper#dashboard_filter_link`, a thin wrapper around `link_to`
that always pairs `filter_button_classes(active)` with `aria-current="page"`
when `active` is true (and omits the attribute otherwise, since `aria-current`
should not be present with a falsy value). All three filter call sites (time
range in `_metrics.html.erb`; status and goal in `_performance.html.erb`) go
through this one helper, so selected-state semantics can't drift between the
three lists.

## Decisions

- **`aria-current="page"`, not `aria-selected` or a `aria-pressed`.** These
  links navigate the dashboard/performance frame to a new filtered view
  (they are `<a>` elements, not toggle buttons), so `aria-current="page"`
  is the correct token per the ARIA spec for "the current page within a set
  of navigation links" — matching how each filter link changes the
  effective page/view.
- **One helper, not a per-list partial.** The three filter lists (time
  range, status, goal) already share `filter_button_classes`; wrapping
  `link_to` centrally is a five-line change that removes the chance of a
  future filter list forgetting the attribute, without introducing a new
  view partial or Stimulus controller.

## What this is not

- **Not a visual redesign.** The active/inactive Tailwind classes from
  `filter_button_classes` are unchanged.
- **Not a general-purpose segmented control component.** Scope is limited
  to the existing dashboard filter link lists.
