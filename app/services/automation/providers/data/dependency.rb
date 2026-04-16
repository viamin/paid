# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Structured dependency edge exposed by a work-item provider.
      # +relation+ describes the semantic link ("blocks", "blocked_by",
      # "related_to", "duplicates", ...). Policy code uses +relation+ to
      # decide whether the edge blocks auto-pick.
      #
      # - +relation+ [Symbol]
      # - +target_repo+ [String] Provider-local container identifier of
      #   the target work item.
      # - +target_number+ [Integer, String] Target work-item identifier.
      Dependency = ::Data.define(:relation, :target_repo, :target_number)
    end
  end
end
