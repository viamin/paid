# frozen_string_literal: true

module Activities
  # Decides which review-goal pipeline a run should use (#3898). Lives in an
  # activity so the workflow itself stays query-free and the decision is made
  # with a fresh project config — the pilot flag may have changed between
  # queuing and execution. Returns +{ pipeline: "verified" }+ only when every
  # condition holds:
  #
  # - the run's goal is +review+ (other goals must continue to use the
  #   containerized agent);
  # - the project's +review_enabled?+ flag is on;
  # - the +paid_agent+ review method is enabled;
  # - the project's +paid_agent_independent_verification?+ pilot flag is on.
  #
  # Any other combination returns +{ pipeline: "container" }+, which keeps
  # the existing containerized reviewer in place.
  #
  # @spec REVIEW-VERIFY-001
  class ResolveReviewPipelineActivity < BaseActivity
    activity_name "ResolveReviewPipeline"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      project = agent_run.project

      pipeline = if eligible?(agent_run, project)
        "verified"
      else
        "container"
      end

      { pipeline: pipeline }
    end

    private

    def eligible?(agent_run, project)
      return false unless agent_run.goal == "review"
      return false unless project.review_enabled?
      return false unless project.review_method_enabled?("paid_agent")
      return false unless project.paid_agent_independent_verification?

      true
    end
  end
end
