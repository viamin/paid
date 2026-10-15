# frozen_string_literal: true

module Projects
  module Readiness
    # Admits one explicitly requested bootstrap run from current readiness
    # evidence. UI and tool callers share this boundary so neither can bypass
    # the readiness, budget, or unfinished-run safeguards.
    # @spec PROJECT-READINESS-007
    class Bootstrap
      NotReadyError = Class.new(StandardError)
      ActiveRunError = Class.new(StandardError)
      BudgetExceededError = Class.new(StandardError)
      NoRunnableRunnerError = Class.new(StandardError)

      def self.call(...)
        new(...).call
      end

      def initialize(project:, user:)
        @project = project
        @user = user
      end

      def call
        check_budget!
        run = project.with_lock { create_run! }
        ProcessRunQueueJob.perform_later
        run
      rescue ActiveRecord::RecordNotUnique => error
        raise unless active_bootstrap_constraint?(error)

        raise ActiveRunError, "A bootstrap attempt is already in progress for this project."
      end

      private

      attr_reader :project, :user

      def check_budget!
        return if CostBudgets::Check.call(project)[:allowed]

        raise BudgetExceededError, "Your project's AI budget has been reached. Please adjust your budget settings or try again later."
      end

      def create_run!
        raise NotReadyError, "This project no longer needs bootstrap setup." unless project.tdd_readiness_blocked?
        raise ActiveRunError, "A bootstrap attempt is already in progress for this project." if active_run_exists?

        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "bootstrap_readiness")
        raise NoRunnableRunnerError, "No runnable runner could be resolved for this project." unless runner_id && agent_type

        run = AgentRun.create!(
          project:,
          initiating_user: user,
          runner_id:,
          agent_type:,
          custom_prompt: BuildBootstrapPrompt.call(project:),
          goal: "bootstrap_readiness",
          review_depth_snapshot: project.effective_review_depth,
          trigger_type: "manual",
          status: "queued"
        )
        run
      end

      def active_run_exists?
        project.agent_runs.where(goal: "bootstrap_readiness", status: AgentRun::DEDUP_BLOCKING_STATUSES).exists?
      end

      def active_bootstrap_constraint?(error)
        (error.cause&.message || error.message).include?("idx_agent_runs_unique_active_bootstrap_readiness")
      end
    end
  end
end
