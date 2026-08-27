# frozen_string_literal: true

module Inbox
  # Centralizes URL construction for inbox entry navigation so the upcoming
  # #3676 route change (RESTful `/inbox/:entry_id` with a dedicated
  # `InboxController`) only touches one seam.
  module PathHelper
    # Builds the URL for the inbox index page with the given scope filters
    # and selected entry. The `selected` param identifies the entry that
    # should be auto-selected on page load so submit→redirect→auto-advance
    # works through a plain HTTP redirect.
    def inbox_path(project: nil, kind: nil, selected: nil, view: nil, **overrides)
      params = {
        project_id: project&.id,
        kind: kind,
        selected: selected,
        view: view
      }.compact.merge(overrides)

      dashboard_inbox_path(**params)
    end

    # Builds the URL for the inbox detail Turbo Frame. Today the detail frame
    # is rendered by `DashboardController#inbox_detail`; the dedicated
    # `Inbox::EntriesController#show` endpoint arrives with #3676.
    def inbox_detail_path(entry, project: nil, kind: nil, view: "detail")
      dashboard_inbox_entry_path(
        entry_kind: entry.kind,
        entry_id: entry.record.id,
        project_id: project&.id,
        kind: kind,
        view: view
      )
    end

    # Selector the inbox view uses to find the active entry in the URL
    # state. Maps to the `selected` URL param for #3676's RESTful routes
    # today and after the route migration.
    def inbox_selected_param(entry)
      "#{entry.kind}:#{entry.record.id}"
    end
  end
end
