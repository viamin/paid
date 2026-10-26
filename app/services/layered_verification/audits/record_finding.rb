# frozen_string_literal: true

module LayeredVerification
  module Audits
    class RecordFinding
      # @spec LAYERED-VERIFY-015, LAYERED-VERIFY-017
      def self.call(...) = new(...).call
      def initialize(check_result:, cause_signature:, details: {}) = (@check_result = check_result; @cause_signature = cause_signature; @details = details)
      def call
        finding = LayeredVerificationFinding.find_or_create_by!(project: check_result.obligation.project, obligation: check_result.obligation, correspondence_claim: check_result.correspondence_claim, correspondence_claim_type: check_result.correspondence_claim&.claim_type || "none", cause_signature:) { |row| row.details = details }
        finding.observations.find_or_create_by!(check_result:)
        finding
      end
      private
      attr_reader :check_result, :cause_signature, :details
    end
  end
end
