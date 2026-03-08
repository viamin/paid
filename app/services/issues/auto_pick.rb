# frozen_string_literal: true

module Issues
  # Selects the next unblocked, eligible issue for a project and creates
  # a queued agent run for it. Used when the run queue is empty and the
  # system has capacity, keeping agents productive without manual intervention.
  #
  # Selection criteria:
  # - Open, non-PR issues with all dependencies satisfied
  # - No existing active (queued/pending/running) agent run
  # - Not labeled with excluded labels (planning, research, waiting)
  # - Ordered by github_number ascending (lowest/oldest first)
  #
  # Returns the created AgentRun or nil if no eligible issue is found.
  class AutoPick
    EXCLUDED_LABELS = %w[planning research waiting].freeze

    def initialize(project)
      @project = project
    end

    def call
      return nil unless @project.auto_pick_enabled?

      issue = find_next_eligible_issue
      return nil unless issue

      agent_run = create_agent_run(issue)

      Rails.logger.info(
        message: "auto_pick.issue_selected",
        project_id: @project.id,
        issue_id: issue.id,
        issue_number: issue.github_number,
        agent_run_id: agent_run.id
      )

      agent_run
    rescue ActiveRecord::RecordNotUnique => e
      message = e.cause&.message || e.message
      raise unless message&.include?("idx_agent_runs_unique_active_issue")

      # Another process already created a run for this issue.
      # Re-query for the existing active/queued run so callers can use it.
      existing_run = AgentRun.find_by(
        project: @project,
        issue: issue,
        status: %w[queued pending running]
      )

      if existing_run
        Rails.logger.info(
          message: "auto_pick.duplicate_existing_run",
          project_id: @project.id,
          issue_id: issue&.id,
          agent_run_id: existing_run.id
        )
        existing_run
      else
        Rails.logger.info(
          message: "auto_pick.duplicate_skipped",
          project_id: @project.id,
          issue_id: issue&.id
        )
        nil
      end
    end

    private

    def find_next_eligible_issue
      scope = Issue.ready_for_work(@project)
        .where(paid_state: %w[new planning failed])
        .where.not(id: issues_with_active_runs)

      trusted_usernames = Array(@project.allowed_github_usernames).presence
      scope = scope.where(github_creator_login: trusted_usernames) if trusted_usernames

      exclude_labeled_issues(scope)
        .order(github_number: :asc)
        .first
    end

    def issues_with_active_runs
      AgentRun.where(project: @project, status: %w[queued pending running])
        .where.not(issue_id: nil)
        .select(:issue_id)
    end

    def exclude_labeled_issues(scope)
      # Use a single JSONB label-existence predicate so PostgreSQL can
      # leverage the GIN index on issues.labels for open non-PR issues.
      labels_array_literal = "{#{EXCLUDED_LABELS.join(",")}}"
      scope.where("NOT (labels ?| ?::text[])", labels_array_literal)
    end

    def create_agent_run(issue)
      AgentRun.create!(
        project: @project,
        issue: issue,
        agent_type: resolve_agent_type,
        status: "queued",
        trigger_type: "automatic"
      )
    end

    def resolve_agent_type
      settings = AgentRuns::UserSettingsResolver.call(project: @project, strict: false)
      return "claude_code" unless settings

      provider_key = settings.default_agent_provider
      provider_key == "claude" ? "claude_code" : provider_key
    end
  end
end
