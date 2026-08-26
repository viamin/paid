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
    def inbox_detail_path(entry)
      dashboard_inbox_entry_path(
        entry_kind: entry.kind,
        entry_id: entry.record.id
      )
    end

    # Selector the inbox view uses to find the active entry in the URL
    # state. Maps to the `selected` URL param for #3676's RESTful routes
    # today and after the route migration.
    def inbox_selected_param(entry)
      "#{entry.kind}:#{entry.record.id}"
    end

    # Returns the next inbox entry after the given one, within the same
    # project/kind scope. Falls back to nil when the queue is drained so
    # the caller can redirect to the bare inbox index.
    def inbox_next_entry(after:, user:, project: nil, kind: nil)
      entries = Inbox::Queue.call(user: user, project: project, kind: kind)
      return nil if entries.empty?

      return entries.first if after.nil?

      index = entries.index { |candidate| candidate.record.id == after.record.id && candidate.kind == after.kind }
      return nil if index.nil?

      entries[index + 1]
    end
  end
end
