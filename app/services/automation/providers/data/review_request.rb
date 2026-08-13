# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Snapshot of the reviewers whose review has been requested but not
      # yet satisfied. Returned by
      # {Automation::Providers::ReviewProvider#fetch_review_requests}.
      #
      # - +users+ [Array<String>] Pending user reviewer logins, downcased.
      # - +teams+ [Array<String>] Pending team/group identifiers. Providers
      #   without a team concept MUST return an empty array.
      ReviewRequest = ::Data.define(:users, :teams)
    end
  end
end
