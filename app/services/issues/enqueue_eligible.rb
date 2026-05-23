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
      runner = resolve_runner(goal)
      unless runner
        retry_schedule = schedule_no_runner_retry
        log_no_runner(retry_schedule)
        return nil
      end

      run = blocking_runs(goal).find_or_create_by!(project: project, issue: issue, goal: goal) do |agent_run|
        agent_run.runner = runner
        agent_run.agent_type = Runner.agent_type_for(runner.runner_key)
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

    def resolve_runner(goal)
      runner_id, = AgentRuns::RunnerResolver.call(project: project, goal: goal)
      Runner.kept_only.find_by(id: runner_id) if runner_id
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

    def schedule_no_runner_retry
      Issues::ReenqueueEligibleJob.schedule_no_runner_retry(issue.id, no_runner_retry_count: no_runner_retry_count)
    end

    def log_no_runner(retry_schedule)
      Rails.logger.warn(
        log_context(
          "enqueue_eligible.no_runner",
          no_runner_retry_count: no_runner_retry_count,
          no_runner_retry_scheduled: retry_schedule.present?,
          next_no_runner_retry_count: retry_schedule&.fetch(:retry_count, nil),
          wait_seconds: retry_schedule&.fetch(:wait, nil)&.to_i,
          retries_exhausted: retry_schedule.blank?
        )
      )
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
