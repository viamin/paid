# frozen_string_literal: true

module LayeredVerification
  module Findings
    class Record
      # @spec LAYERED-VERIFY-017
      def self.call(...) = new(...).call

      def initialize(obligation:, agent_run:, check_result:, correspondence_claim_type:, cause_signature:, details:)
        @obligation = obligation
        @agent_run = agent_run
        @check_result = check_result
        @correspondence_claim_type = correspondence_claim_type
        @cause_signature = cause_signature
        @details = details.deep_stringify_keys
      end

      def call
        finding = LayeredVerificationFinding.find_or_initialize_by(identity)
        finding.assign_attributes(attributes) if finding.new_record?
        finding.agent_run = agent_run if finding.new_record?
        finding.save!
        finding.observations.find_or_create_by!(check_result:, agent_run:) { |observation| observation.provenance = provenance }
        finding
      end

      private

      attr_reader :agent_run, :cause_signature, :check_result, :correspondence_claim_type, :details, :obligation

      def identity
        { project: obligation.project, obligation:, correspondence_claim_type:, cause_signature: }
      end

      def attributes
        {
          status: "open",
          source_passages: details.fetch("source_passages", []),
          claims: details.fetch("claims", []),
          observed_behavior: details.fetch("observed_behavior", "Correspondence evidence contradicts this obligation."),
          question: details.fetch("question", "Which authoritative interpretation should govern this scope?"),
          options: details.fetch("options", []),
          consequences: details.fetch("consequences", []),
          owner_actions: details.fetch("owner_actions", [ "Review evidence", "Request a separately authorized repair", "Defer with a reason" ])
        }
      end

      def provenance
        { "input_revision" => check_result.input_revision, "recorded_at" => Time.current.iso8601 }
      end
    end
  end
end
