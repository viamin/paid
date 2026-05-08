# frozen_string_literal: true

module Automation
  module Strategies
    # Safe fallback strategy that always returns a noop result.
    #
    # Used by {Select} when no registration matches the requested
    # strategy type at any scope and no built-in default exists.
    # Ensures callers never receive +nil+ from the selection service.
    class NullStrategy
      include Automation::Strategy

      def evaluate(_context)
        noop_result
      end
    end
  end
end
