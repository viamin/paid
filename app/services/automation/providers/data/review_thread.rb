# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Provider-neutral review thread (line-level discussion). Returned by
      # {Automation::Providers::ReviewProvider#fetch_review_threads}.
      #
      # - +id+ [String] Provider-local thread identifier. The value is
      #   opaque to the policy layer but MUST round-trip to
      #   {Automation::Providers::ReviewProvider#resolve_review_thread}.
      # - +resolved+ [Boolean]
      # - +comments+ [Array<ReviewThreadComment>] Ordered from oldest to
      #   newest.
      ReviewThread = ::Data.define(:id, :resolved, :comments)
    end
  end
end
