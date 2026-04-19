# frozen_string_literal: true

module IssueTrackers
  CommentData = Data.define(
    :external_id,
    :body,
    :author,
    :created_at
  ) do
    def initialize(external_id:, body:, author: nil, created_at: nil)
      super
    end
  end
end
