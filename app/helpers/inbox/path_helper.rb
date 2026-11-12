# frozen_string_literal: true

module Inbox
  module PathHelper
    # @spec INBOX-FOUNDATION-009 @spec INBOX-PHASE-RELEVANCE-002
    def inbox_query_params(project: nil, kind: nil, sort: params[:sort], scope: params[:scope], **overrides)
      {
        project_ids: params[:project_ids].presence || project&.then { |record| [ record.id ] },
        kinds: params[:kinds].presence || kind.presence&.then { |value| [ value ] },
        q: params[:q]&.permit(*Inbox::Query::SEARCH_PREDICATES)&.to_h&.presence,
        sort: sort,
        scope: scope
      }.compact.merge(overrides)
    end

    # @spec CHANGE-INTENT-INBOX-001
    # Builds an inbox-scoped return target that the change_intent approve,
    # request_changes, and discard actions can redirect back to. Falls back
    # to a path-only string so the receiving controller's redirect logic can
    # distinguish an inbox-driven return from the project-page default.
    def inbox_safe_return_target(project: nil, kind: nil)
      inbox_path(**inbox_query_params(project: project, kind: kind))
    end
  end
end
