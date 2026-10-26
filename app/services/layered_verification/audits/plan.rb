# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Plan
      # @spec LAYERED-VERIFY-008 @spec LAYERED-VERIFY-009
      DEFAULT_CHECKS = %w[linkage_freshness behavioral_testing].freeze

      def self.call(...) = new(...).call

      def initialize(obligation:)
        @obligation = obligation
      end

      def call
        { selected: selected, omitted: omitted }
      end

      private

      attr_reader :obligation

      def selected
        DEFAULT_CHECKS.map { |producer| entry(producer, "Checks current links and exercised behavior within the declared scope.") } + model_checks
      end

      def omitted
        (LayeredVerificationCheckResult::PRODUCERS - selected.map { |check| check[:producer] }).map do |producer|
          entry(producer, "Not selected: this obligation has no declared artifact or failure mode requiring it.")
        end
      end

      def model_checks
        claims = obligation.correspondence_claims.where(claim_type: %w[business_to_model model_to_code])
        return [] if claims.empty?

        [ entry("formal_verification", "Selected because declared business-to-model or model-to-code correspondence exists.") ]
      end

      def entry(producer, rationale)
        { producer:, rationale:, limitations: "Selection is bounded to the obligation's declared scope and available artifacts." }
      end
    end
  end
end
