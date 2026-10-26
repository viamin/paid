# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      def self.call(...) = new(...).call

      def initialize(obligations:, model_declared: false, semantic_audit: false)
        @obligations = Array(obligations)
        @model_declared = model_declared
        @semantic_audit = semantic_audit
      end

      def call
        checks = [ linkage_check ]
        checks << tlc_check if model_declared
        checks << semantic_check if semantic_audit
        { "checks" => checks, "omissions" => omissions, "residual_gaps" => residual_gaps }
      end

      private

      attr_reader :obligations, :model_declared, :semantic_audit

      def linkage_check = check("linkage_freshness", "Maps declared scope to available source/spec/code artifacts.")
      def tlc_check = check("formal_verification", "A declared TLA+ model can expose counterexamples.")
      def semantic_check = check("semantic_audit", "A bounded correspondence read is required for selected obligations.")
      def check(producer, fit) = { "producer" => producer, "fit" => fit, "required_inputs" => [], "assumptions" => [], "resource_expectations" => "bounded by audit budget" }
      def omissions = model_declared ? [] : [ { "producer" => "formal_verification", "reason" => "No declared formal model/config pair." } ]
      def residual_gaps = obligations.empty? ? [ "No obligations selected." ] : [ "Passing checks are scoped evidence, not proof outside the selected scope." ]
    end
  end
end
