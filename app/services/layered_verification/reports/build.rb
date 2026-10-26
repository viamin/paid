# frozen_string_literal: true

module LayeredVerification
  module Reports
    class Build
      # @spec LAYERED-VERIFY-024
      def self.call(...) = new(...).call

      def initialize(obligations:, plan:)
        @obligations, @plan = obligations, plan
      end

      def call
        synthesis = Audits::SynthesizeCoverage.call(obligations:)
        { business_intent_validation: intent_validation, verification_coverage: synthesis.fetch(:coverage),
          plan:, inbox_required: synthesis.fetch(:inbox_required) }
      end

      private

      attr_reader :obligations, :plan

      def intent_validation
        obligations.map do |obligation|
          { obligation_id: obligation.id, external_identity: obligation.external_identity,
            scope: obligation.scope_description, approval_state: obligation.approval_state,
            revision: obligation.external_revision }
        end
      end
    end
  end
end
