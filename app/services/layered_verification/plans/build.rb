# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      Check = Data.define(:producer, :fit, :required_inputs, :limitations, :applicable)
      Result = Data.define(:checks, :residual_gaps)

      def self.call(...) = new(...).call

      def initialize(obligation:, model: nil)
        @obligation = obligation
        @model = model
      end

      def call
        checks = correspondence_checks + [ semantic_check, formal_check ]
        Result.new(checks:, residual_gaps: checks.reject(&:applicable).map(&:limitations))
      end

      private

      attr_reader :obligation, :model

      def correspondence_checks
        obligation.correspondence_claims.map do |claim|
          Check.new(producer: "implementation_conformance", fit: "declared #{claim.claim_type} mapping",
            required_inputs: [ claim.source_reference, claim.target_reference ], limitations: "Correspondence evidence is bounded to the declared mapping.", applicable: true)
        end
      end

      def semantic_check
        Check.new(producer: "semantic_audit", fit: "independent source-grounded assessment", required_inputs: [ obligation.external_identity ],
          limitations: "Semantic assessment is selected only when its bounded source inputs are available.", applicable: obligation.external_identity.present?)
      end

      def formal_check
        applicable = model.is_a?(Hash) && model["module"].present? && model["config"].present?
        Check.new(producer: "formal_verification", fit: "declared TLA+ model", required_inputs: model ? [ model["module"], model["config"] ].compact : [],
          limitations: applicable ? "TLC assesses the declared model, not undocumented behavior." : "No declared TLA+ module/config pair.", applicable:)
      end
    end
  end
end
