# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Normalized lifecycle state plus the provider mapping and any conflict.
      Lifecycle = ::Data.define(:state, :raw_state, :mapping, :conflict)
    end
  end
end
