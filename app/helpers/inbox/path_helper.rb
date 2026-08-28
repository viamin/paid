# frozen_string_literal: true

module Inbox
  module PathHelper
    def inbox_query_params(project: nil, kind: nil, **overrides)
      {
        project_id: project&.id,
        kind: kind
      }.compact.merge(overrides)
    end
  end
end
