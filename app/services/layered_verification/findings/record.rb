# frozen_string_literal: true

module LayeredVerification
  module Findings
    class Record
      # @spec LAYERED-VERIFY-017
      def self.call(...) = new(...).call

      def initialize(project:, obligation:, correspondence_claim:, cause_signature:, check_result:, attributes:)
        @project = project
        @obligation = obligation
        @correspondence_claim = correspondence_claim
        @cause_signature = cause_signature
        @check_result = check_result
        @attributes = attributes
      end

      def call
        finding = find_or_create
        finding.record_observation!(check_result:)
        finding
      end

      private

      attr_reader :attributes, :cause_signature, :check_result, :correspondence_claim, :obligation, :project

      def find_or_create
        LayeredVerificationFinding.find_or_create_by!(identity) do |finding|
          finding.assign_attributes(attributes)
          finding.originating_audit_run = check_result.agent_run
        end
      end

      def identity
        {
          project:, obligation:, correspondence_claim_type: correspondence_claim.claim_type,
          cause_signature:
        }
      end
    end
  end
end
