# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      Plan = Data.define(:selected_checks, :omissions, :required_inputs, :assumptions, :resource_expectations, :residual_gaps) do
        def to_h
          { selected_checks:, omissions:, required_inputs:, assumptions:, resource_expectations:, residual_gaps: }
        end
      end

      def self.call(...) = new(...).call

      def initialize(obligations:, formal_model: nil)
        @obligations = obligations
        @formal_model = formal_model
      end

      def call
        Plan.new(
          selected_checks: selected_checks,
          omissions: omissions,
          required_inputs: required_inputs,
          assumptions: [ "Host CI, security, branch protection, review, and intent-conformance remain independent." ],
          resource_expectations: { "check_count" => selected_checks.size },
          residual_gaps: residual_gaps
        )
      end

      private

      attr_reader :formal_model, :obligations

      def selected_checks
        @selected_checks ||= begin
          checks = [ check("implementation_conformance", "Every scoped obligation has a correspondence assessment.") ]
          checks << check("formal_verification", "A declared TLA+ model is available.") if formal_model.present?
          checks
        end
      end

      def omissions
        return [] if formal_model.present?

        [ check("formal_verification", "No declared TLA+ model; this is non-applicable, not a pass.") ]
      end

      def required_inputs
        { "obligation_ids" => obligations.map(&:id), "formal_model" => formal_model }
      end

      def residual_gaps
        [ "Semantic audit is selected only when an isolated agent_harness assessment is available." ]
      end

      def check(producer, fit)
        { "producer" => producer, "fit" => fit, "limitations" => "Bounded to the declared obligation scope." }
      end
    end
  end
end
