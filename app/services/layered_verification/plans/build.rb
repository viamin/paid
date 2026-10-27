# frozen_string_literal: true

module LayeredVerification
  module Plans
    # Produces an explicit, auditable plan; semantic selection is supplied by
    # agent_harness at execution time, while this class preserves its contract.
    # @spec LAYERED-VERIFY-021
    class Build
      def self.call(...) = new(...).call

      def initialize(obligations:, selections: {})
        @obligations = obligations
        @selections = selections.respond_to?(:to_unsafe_h) ? selections.to_unsafe_h : selections
      end

      def call
        obligations.to_h { |obligation| [ obligation.id.to_s, plan_for(obligation) ] }
      end

      private

      attr_reader :obligations, :selections

      def plan_for(obligation)
        selection = selections.fetch(obligation.id.to_s, selections.fetch(obligation.id, {})).to_h.deep_stringify_keys
        {
          "selected_checks" => Array(selection["selected_checks"]),
          "fit" => selection["fit"].to_s,
          "exclusions" => Array(selection["exclusions"]),
          "required_inputs" => Array(selection["required_inputs"]),
          "assumptions" => Array(selection["assumptions"]),
          "resource_expectations" => selection["resource_expectations"] || {},
          "residual_gaps" => Array(selection["residual_gaps"])
        }
      end
    end
  end
end
