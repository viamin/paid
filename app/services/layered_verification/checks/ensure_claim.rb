# frozen_string_literal: true

module LayeredVerification
  module Checks
    # Returns the correspondence claim an audit checks against, creating the
    # missing one when the project has not declared that mapping yet.
    #
    # A claim is a statement to be checked, never evidence that the mapping
    # holds, so an audit-created claim records only the references it compared
    # and states plainly that the project declared no abstraction boundary or
    # assumption for that mapping.
    #
    # @spec LAYERED-VERIFY-007 @spec LAYERED-VERIFY-024
    class EnsureClaim
      UNDECLARED_BOUNDARY = "Not declared by the project for this mapping; the comparison used the stated scope directly."
      UNDECLARED_ASSUMPTION = "Not declared by the project for this mapping."

      def self.call(...)
        new(...).call
      end

      def initialize(obligation:, claim_type:, source_reference:, target_reference:)
        @obligation = obligation
        @claim_type = claim_type
        @source_reference = source_reference
        @target_reference = target_reference
      end

      def call
        declared || LayeredVerificationCorrespondenceClaim.create!(
          obligation: obligation,
          claim_type: claim_type,
          source_reference: source_reference,
          target_reference: target_reference,
          abstraction_boundaries: UNDECLARED_BOUNDARY,
          assumptions: UNDECLARED_ASSUMPTION
        )
      end

      private

      attr_reader :claim_type, :obligation, :source_reference, :target_reference

      def declared
        obligation.correspondence_claims.find_by(claim_type: claim_type)
      end
    end
  end
end
