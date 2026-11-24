# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Carries forward a prior check result the admission impact snapshot marked
    # reusable instead of recomputing it, so its evidence still affects this
    # audit's coverage and report. Append-only: this records a new row for the
    # current run that references the reused result.
    # @spec LAYERED-VERIFY-019
    class RecordReuse
      REUSE_LIMITATION = "Reuses prior evidence whose dependency impact on this audit is demonstrably absent."
      PRODUCER = "formal_verification"

      def self.call(...) = new(...).call

      def initialize(obligation:, agent_run:, metadata:)
        @obligation = obligation
        @agent_run = agent_run
        @metadata = metadata.to_h
      end

      def call
        obligation.with_lock do
          reused = reusable_result
          return unless reused && reusable_now?(reused)

          LayeredVerificationCheckResult.create!(result_attributes(reused))
          true
        end
      end

      private

      attr_reader :agent_run, :metadata, :obligation

      def reusable_result
        reused_ids = Array(metadata.dig("impact", "reused_check_result_ids")).map(&:to_i)
        return if reused_ids.empty?
        return if recorded_for_this_run?

        LayeredVerificationCheckResult.where(obligation:, id: reused_ids, producer: PRODUCER)
          .where.not(agent_run_id: agent_run.id).order(:id).last
      end

      def recorded_for_this_run?
        LayeredVerificationCheckResult.where(agent_run:, obligation:, producer: PRODUCER).exists?
      end

      def reusable_now?(result)
        return false unless metadata.fetch("input_revisions").fetch(obligation.id.to_s) == obligation.external_revision

        Invalidation.new(obligations: [], target_revision: metadata["target_revision"],
          dependencies: metadata.fetch("dependencies", {})).reusable?(result)
      end

      def result_attributes(reused)
        {
          obligation:, agent_run:, producer: PRODUCER,
          execution_state: reused.execution_state, obligation_coverage: reused.obligation_coverage,
          input_revision:, evidence_ref: reused.evidence_ref,
          evidence_summary: reused.evidence_summary, cause_signature: reused.cause_signature,
          agent_reported: { "selected_check" => PRODUCER },
          recorder_verified: { "reused_result_id" => reused.id },
          cost: {}, limitations: "Reuses check result ##{reused.id}. #{REUSE_LIMITATION}"
        }
      end

      def input_revision
        { "target_revision" => metadata["target_revision"], "code" => metadata["target_revision"],
          "external_revision" => metadata.fetch("input_revisions").fetch(obligation.id.to_s),
          "dependencies" => metadata.fetch("dependencies", {}) }.compact
      end
    end
  end
end
