# frozen_string_literal: true

module Automation
  module ReviewMethods
    # CI-action-based review — delegates review responsibilities to a
    # GitHub Action (e.g. +Claude Code Review+). Paid dispatches the
    # action via +repository_dispatch+ and waits for the configured
    # +action_name+ check run to conclude +success+.
    #
    # Like {Manual}, a ci_action pending outcome blocks PR progress when
    # +wait_for_reviews+ is enabled. The decision emitted in that case is
    # handled at the workflow layer (dispatching the action) rather than
    # via {Automation::Decision} — ci_action has no corresponding decision
    # type today, so this plugin reports +:pending+ without producing a
    # decision, leaving the existing dispatch path in place.
    class CiAction < Base
      TRIGGER_TYPE = "ci_action_pending"

      def kind = :ci

      def blocking_by_default?
        config.wait_for_reviews?
      end

      def evaluate
        pending = signals.trigger(TRIGGER_TYPE)
        if pending
          return outcome_pending(
            blocking: blocking_by_default?,
            message: "ci_action review pending",
            metadata: {
              action_name: method.action_name,
              dispatch_required: pending[:dispatch_required] == true
            }.compact
          )
        end

        return outcome_not_applicable unless config.method_enabled?(:ci_action)

        outcome_satisfied
      end

      # ci_action dispatch is currently owned by +DispatchClaudeReviewActivity+
      # in the workflow layer; there is no matching {Automation::Decision}
      # type today. Returning +nil+ preserves that ownership while still
      # letting the strategy report the method's pending/satisfied state.
      def decision
        nil
      end
    end
  end
end
