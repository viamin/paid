# frozen_string_literal: true

module LayeredVerification
  module Plans
    # Produces an explicit, auditable plan; semantic selection is supplied at
    # the request boundary, while this class preserves its structural contract.
    # @spec LAYERED-VERIFY-021
    class Build
      class EmptySelectionError < ArgumentError; end

      def self.call(...) = new(...).call

      def initialize(obligations:, selections: {})
        @obligations = obligations
        @selections = selections.to_h
      end

      def call
        obligations.to_h do |obligation|
          plan = plan_for(obligation)
          raise EmptySelectionError, "select at least one verification check for every obligation" if plan["selected_checks"].empty?

          [ obligation.id.to_s, plan ]
        end
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
