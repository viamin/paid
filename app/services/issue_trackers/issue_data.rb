# frozen_string_literal: true

module IssueTrackers
  IssueData = Data.define(
    :external_id,
    :title,
    :body,
    :status,
    :url,
    :labels,
    :assignee,
    :metadata
  ) do
    def initialize(external_id:, title:, body: nil, status: nil, url: nil,
                   labels: [], assignee: nil, metadata: {})
      super
    end
  end
end
