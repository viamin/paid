# frozen_string_literal: true

module Issues
  class EnqueueEligible
    def self.call(...)
      new(...).call
    end

    def initialize(issue, project:)
      @issue = issue
      @project = project
    end

    def call
      unless eligible?
        log_ineligible
        return nil
      end

      goal = seeded_goal
      provider = resolve_provider(goal)
      unless provider
        log_no_provider
        return nil
      end

      run = blocking_runs.find_or_create_by!(project: project, issue: issue) do |agent_run|
        agent_run.provider = provider
        agent_run.agent_type = Provider.agent_type_for(provider.provider_key)
        agent_run.status = "queued"
        agent_run.trigger_type = "automatic"
        agent_run.auto_pick = true
        agent_run.goal = goal
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

      run = blocking_runs.find_by(project: project, issue: issue)
      if run
        log_existing(run)
        run
      else
        nil
      end
    end

    private

    attr_reader :issue, :project

    def eligible?
      Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_scope(project)
        .where(id: issue.id)
        .exists?
    end

    def resolve_provider(goal)
      provider_id, = AgentRuns::ProviderResolver.call(project: project, goal: goal)
      Provider.kept_only.find_by(id: provider_id) if provider_id
    end

    def seeded_goal
      project.auto_enhance_enabled? ? "analyze_issue" : "create_pr"
    end

    def blocking_runs
      AgentRun.where(status: AgentRun::AUTO_PICK_BLOCKING_STATUSES)
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

    def log_no_provider
      Rails.logger.warn(log_context("enqueue_eligible.no_provider"))
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
