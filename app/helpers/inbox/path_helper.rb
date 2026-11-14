# frozen_string_literal: true

module Inbox
  module PathHelper
    # @spec INBOX-FOUNDATION-009 @spec INBOX-PHASE-RELEVANCE-002
    def inbox_query_params(project: nil, kind: nil, sort: params[:sort], scope: params[:scope], **overrides)
      {
        project_ids: params[:project_ids],
        project_id: project&.id || params[:project_id],
        kinds: params[:kinds],
        kind: kind || params[:kind],
        q: params[:q].respond_to?(:permit) ? params[:q].permit(:text_cont).to_h : params[:q],
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
