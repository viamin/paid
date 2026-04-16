# frozen_string_literal: true

module Automation
  # Shared contract implemented by every automation strategy.
  #
  # A strategy is a pure policy object: it receives an Automation::Context
  # and returns an Automation::Result describing the actions to take. It
  # performs no I/O of its own — signal collection and side effects live
  # in the layers above and below.
  #
  # Concrete strategies (auto-pick, auto-continue, auto-review, auto-merge)
  # will be introduced in follow-on issues and plug into this interface
  # without changing how orchestration invokes them.
  module Strategy
    # @param context [Automation::Context]
    # @return [Automation::Result]
    def evaluate(context)
      raise NotImplementedError, "#{self.class} must implement #evaluate(context)"
    end

    # Convenience helper so strategies can return a noop result without
    # reaching into the Result class directly.
    def noop_result
      Result.noop
    end
  end
end
