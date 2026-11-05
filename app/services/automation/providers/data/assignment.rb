# frozen_string_literal: true

module Automation
  module Providers
    module Data
      AssignmentOverride = ::Data.define(:assignee_identities, :actor_identity, :reason)

      # The source distinguishes the provider's current assignment from a
      # Paid override, which must never be silently written back to a tracker.
      Assignment = ::Data.define(:assignee_identities, :provenance, :override)
    end
  end
end
