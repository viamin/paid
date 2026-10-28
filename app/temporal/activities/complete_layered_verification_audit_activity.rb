# frozen_string_literal: true

module Activities
  # @spec LAYERED-VERIFY-010 LAYERED-VERIFY-024
  class CompleteLayeredVerificationAuditActivity < BaseActivity
    activity_name "CompleteLayeredVerificationAudit"

    def execute(input)
      agent_run = AgentRun.find(input[:agent_run_id])
      return result(agent_run, stored_coverage(agent_run)) if agent_run.finished?

      track_phase(agent_run_id: agent_run.id, phase_key: "complete_layered_verification_audit", phase_group: "post", agent_run:) do
        LayeredVerification::Audits::IngestResults.call(agent_run:)
        coverage = coverage_for(agent_run)
        store_coverage!(agent_run, coverage)
        completed = agent_run.complete!
        ProcessRunQueueJob.perform_later if completed
        result(agent_run, coverage)
      end
    end

    private

    def coverage_for(agent_run)
      LayeredVerification::Audits::SynthesizeCoverage.call(agent_run:)
        .transform_keys { |obligation| obligation.id.to_s }
    end

    def store_coverage!(agent_run, coverage)
      metadata = agent_run.external_metadata.deep_dup
      metadata.fetch("layered_verification")["coverage"] = coverage
      agent_run.update!(external_metadata: metadata)
    end

    def stored_coverage(agent_run)
      agent_run.external_metadata.dig("layered_verification", "coverage") || {}
    end

    def result(agent_run, coverage)
      { agent_run_id: agent_run.id, success: agent_run.successful?, coverage: }
    end
  end
end
