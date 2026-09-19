# frozen_string_literal: true

module Activities
  # Runs the staged Find → Verify → Synthesize review pipeline (#3898) for a
  # review-goal run. Wraps +Reviews::Verification::Pipeline+ with the
  # cross-cutting activity concerns the workflow expects:
  #
  # - transitions the agent run into +running+ before the pipeline starts
  #   (so the rest of the platform sees a live run, not a queued one);
  # - records a +verified_review+ phase in the +agent+ phase_group so the
  #   run's phase timeline reflects the pilot path the same way the
  #   containerized +run_agent+ phase does, and marks the phase +failed+
  #   with the error class when the pipeline raises;
  # - emits one structured system agent-run log with the metrics summary
  #   (counts and outcome only — no paths, patches, summaries, or comment
  #   bodies, REVIEW-VERIFY-009);
  # - enqueues the next eligible run so the queue keeps moving once the
  #   review run finishes.
  #
  # @spec REVIEW-VERIFY-009
  class RunVerifiedReviewActivity < BaseActivity
    activity_name "RunVerifiedReview"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      agent_run.start!

      phase_metadata = {}
      track_phase(
        agent_run_id: agent_run_id,
        phase_key: "verified_review",
        phase_group: "agent",
        agent_run: agent_run,
        metadata: phase_metadata
      ) do
        pipeline_result = run_pipeline(agent_run)
        phase_metadata.merge!(phase_metadata_for(pipeline_result))
        record_metrics_log(agent_run, pipeline_result)
        ProcessRunQueueJob.perform_later

        pipeline_result.merge(agent_run_id: agent_run_id)
      end
    end

    private

    def run_pipeline(agent_run)
      Reviews::Verification::Pipeline.call(
        agent_run: agent_run,
        github_client: agent_run.project.client,
        poster: Reviews::Verification::PostTrackedReview
      )
    end

    # Phase metadata mirrors the pilot's metrics summary — counts and
    # outcome only, never repository content (REVIEW-VERIFY-009).
    def phase_metadata_for(pipeline_result)
      metrics = pipeline_result[:metrics] || {}
      {
        outcome: pipeline_result[:outcome],
        candidates: metrics[:candidates],
        verdicts: metrics[:verdicts],
        confirmed_groups: metrics[:confirmed_groups],
        comments_posted: pipeline_result[:comments_posted]
      }.compact
    end

    def record_metrics_log(agent_run, pipeline_result)
      agent_run.log!("system", "verified_review completed: #{phase_metadata_for(pipeline_result).to_json}")
    end
  end
end
