# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # A single comment inside a review thread.
      #
      # - +author_login+ [String, nil] Downcased.
      # - +body+ [String]
      # - +path+ [String, nil] File path the comment targets.
      # - +line+ [Integer, nil] Line number the comment targets.
      # - +created_at+ [Time, nil] When the comment was posted. Used to
      #   determine whether the comment predates a later revision (e.g. a
      #   TDD test-review baseline).
      # - +commit_id+ [String, nil] SHA of the commit the comment was made
      #   against, when the provider exposes it.
      ReviewThreadComment = ::Data.define(:author_login, :body, :path, :line, :created_at, :commit_id) do
        def initialize(author_login:, body:, path:, line:, created_at: nil, commit_id: nil)
          super
        end
      end
    end
  end
end
