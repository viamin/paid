# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Provider-neutral pull-request review. Returned by
      # {Automation::Providers::ReviewProvider#fetch_reviews} and
      # {Automation::Providers::ReviewProvider#submit_review}.
      #
      # - +id+ [Integer, String] Provider-local review identifier.
      # - +author_login+ [String, nil] Reviewer login, downcased.
      # - +state+ [Symbol] One of {STATES}. Providers MUST normalize to
      #   this set.
      # - +raw_state+ [String, nil] Native provider state for audit.
      # - +body+ [String] Markdown body (empty string when no body).
      # - +submitted_at+ [Time, nil] Nil for reviews still in +:pending+
      #   state.
      # - +commit_sha+ [String, nil] SHA that the review was submitted
      #   against.
      class Review < ::Data.define(
        :id,
        :author_login,
        :state,
        :raw_state,
        :body,
        :submitted_at,
        :commit_sha
      )
        STATES = %i[approved changes_requested commented dismissed pending].freeze
      end
    end
  end
end
