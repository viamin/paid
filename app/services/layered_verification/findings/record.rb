# frozen_string_literal: true

module LayeredVerification
  module Findings
    # Records a finding from a check result, deduplicating repeated
    # observations of the same unresolved cause.
    #
    # Identity is (project, obligation, correspondence claim type, cause
    # signature). A repeated audit that reproduces the same identity attaches
    # a new observation to the existing unresolved finding instead of creating
    # a second Inbox entry. Two findings are never merged on textual
    # similarity alone: only an identical cause signature merges them.
    #
    # @spec LAYERED-VERIFY-017
    class Record
      INDEPENDENT_CLAIM_TYPE = "independent"

      def self.call(...)
        new(...).call
      end

      def initialize(project:, obligation:, check_result:, agent_run: nil)
        @project = project
        @obligation = obligation
        @check_result = check_result
        @agent_run = agent_run || check_result.agent_run
      end

      def call
        existing = existing_finding
        return attach_observation(existing) if existing

        create_finding
      end

      private

      attr_reader :agent_run, :check_result, :obligation, :project

      def create_finding
        LayeredVerificationFinding.create!(
          project: project,
          obligation: obligation,
          agent_run: agent_run,
          correspondence_claim_type: claim_type,
          cause_signature: cause_signature,
          status: "open",
          question: question,
          options: options,
          owner_actions: Checks::CorrespondenceAssessment::OWNER_ACTIONS,
          source_passages: source_passages,
          observed_behavior: observed_behavior,
          limitations: limitations,
          external_revision: obligation.external_revision,
          observations: [ observation ]
        )
      end

      def attach_observation(finding)
        finding.update!(observations: finding.observations + [ observation ])
        finding
      end

      def existing_finding
        project.layered_verification_findings
          .where(
            obligation_id: obligation.id,
            correspondence_claim_type: claim_type,
            cause_signature: cause_signature
          )
          .where.not(status: "resolved")
          .first
      end

      def observation
        {
          "recorded_at" => Time.current.iso8601,
          "agent_run_id" => agent_run&.id,
          "check_result_id" => check_result.id,
          "excerpt" => observed_behavior.truncate(500)
        }
      end

      def summary
        @summary ||= check_result.evidence_summary.deep_stringify_keys
      end

      def claim_type
        check_result.correspondence_claim&.claim_type || INDEPENDENT_CLAIM_TYPE
      end

      def cause_signature
        summary["cause_signature"].presence || "check-#{check_result.id}"
      end

      def question
        summary["question"].presence || Checks::CorrespondenceAssessment::DEFAULT_QUESTION
      end

      def options
        Array(summary["options"])
      end

      def source_passages
        Array(summary["cited_source_passages"])
      end

      def observed_behavior
        summary["observed_behavior"].presence || "The check recorded no observed behavior."
      end

      def limitations
        check_result.limitations.presence || "The check stated no further limitation."
      end
    end
  end
end
