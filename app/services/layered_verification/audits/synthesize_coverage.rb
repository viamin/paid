# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017 @spec LAYERED-VERIFY-024
      def self.call(...)
        new(...).call
      end

      def initialize(obligation:, agent_run:, cause_signature:, source_passages:, observed_behavior:, check_limitations:, correspondence_claim: nil)
        @obligation = obligation
        @agent_run = agent_run
        @cause_signature = cause_signature
        @source_passages = source_passages
        @observed_behavior = observed_behavior
        @check_limitations = check_limitations
        @correspondence_claim = correspondence_claim
      end

      def call
        finding = existing_finding || build_finding
        return finding.record_observation!(agent_run:, observation: observation) if finding.persisted?

        finding.save!
        finding
      rescue ActiveRecord::RecordNotUnique
        existing_finding!.record_observation!(agent_run:, observation: observation)
      end

      private

      attr_reader :obligation, :agent_run, :cause_signature, :source_passages, :observed_behavior, :check_limitations, :correspondence_claim

      def existing_finding
        LayeredVerificationFinding.find_by(identity)
      end

      def existing_finding!
        LayeredVerificationFinding.find_by!(identity)
      end

      def identity
        { project: obligation.project, obligation:, correspondence_claim:, cause_signature:, status: "open" }
      end

      def build_finding
        LayeredVerificationFinding.new(identity.merge(
          agent_run:, source_passages:, observed_behavior:, check_limitations:, observation_history: [ observation ]
        ))
      end

      def observation
        { "agent_run_id" => agent_run.id, "source_passages" => source_passages, "observed_behavior" => observed_behavior, "check_limitations" => check_limitations, "recorded_at" => Time.current.iso8601 }
      end
    end
  end
end
