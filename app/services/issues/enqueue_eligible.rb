# frozen_string_literal: true

module Issues
  class EnqueueEligible
    def self.call(...)
      new(...).call
    end

    def initialize(issue, project:, skip_project_gate: false, no_runner_retry_count: 0)
      @issue = issue
      @project = project
      @skip_project_gate = skip_project_gate
      @no_runner_retry_count = no_runner_retry_count
    end

    def call
      unless skip_project_gate || Issues::AutoPickProjectGate.call(project)
        log_project_deferred
        return nil
      end

      unless eligible?
        log_ineligible
        return nil
      end

      goal = seeded_goal
      intended_agent_type = RunnerSupport.intended_agent_type(
        preferred_agent_type: project.model_preferences["preferred_agent_type"]
      )

      run = blocking_runs(goal).find_or_create_by!(project: project, issue: issue, goal: goal) do |agent_run|
        agent_run.agent_type = intended_agent_type
        agent_run.status = "queued"
        agent_run.trigger_type = "automatic"
        agent_run.auto_pick = true
      end

      if run.previously_new_record?
        log_created(run)
      else
        log_existing(run)
      end

      run
    rescue ActiveRecord::RecordNotUnique => e
      message = e.cause&.message || e.message
      raise unless message&.include?("idx_agent_runs_unique_active_issue")

      goal = seeded_goal
      run = blocking_runs(goal).find_by(project: project, issue: issue, goal: goal)
      if run
        log_existing(run)
        run
      else
        nil
      end
    end

    private

    attr_reader :issue, :project
    attr_reader :skip_project_gate, :no_runner_retry_count

    def eligible?
      Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_scope(project)
        .where(id: issue.id)
        .exists?
    end

    def seeded_goal
      project.auto_enhance_enabled? ? "analyze_issue" : "create_pr"
    end

    def blocking_runs(goal)
      AgentRun.where(status: AgentRun::AUTO_PICK_BLOCKING_STATUSES, goal: goal)
    end

    def log_created(run)
      Rails.logger.info(log_context("enqueue_eligible.created", agent_run_id: run.id))
    end

    def log_existing(run)
      Rails.logger.info(log_context("enqueue_eligible.existing", agent_run_id: run.id))
    end

    def log_ineligible
      Rails.logger.info(log_context("enqueue_eligible.ineligible"))
    end

    def log_project_deferred
      Rails.logger.info(log_context("enqueue_eligible.project_deferred"))
    end

    def log_context(message, extra = {})
      {
        message: message,
        project_id: project.id,
        issue_id: issue.id,
        issue_number: issue.github_number
      }.merge(extra)
    end
  end
end
