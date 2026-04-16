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
      ReviewThreadComment = ::Data.define(:author_login, :body, :path, :line)
    end
  end
end
