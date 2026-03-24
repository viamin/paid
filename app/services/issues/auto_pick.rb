# frozen_string_literal: true

module Issues
  # Selects the next unblocked, eligible issue for a project and creates
  # a queued agent run for it. Used when the run queue is empty and the
  # system has capacity, keeping agents productive without manual intervention.
  #
  # Guards (checked before issue selection):
  # - Project must not have any active/queued agent runs (default; the
  #   scheduler can override this via +allow_concurrent_runs: true+ to
  #   fill idle owner capacity across projects)
  # - Project must not have open PRs needing attention (finish before start)
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
    PAID_GENERATED_LABEL = "paid-generated"
    PAID_READY_LABEL = "paid-ready"

    def initialize(project, allow_concurrent_runs: false)
      @project = project
      @allow_concurrent_runs = allow_concurrent_runs
    end

    def call
      return nil unless @project.auto_pick_enabled?
      return nil if project_has_active_runs? && !@allow_concurrent_runs
      return nil if project_has_prs_needing_attention?

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

    # Returns true if the project already has any active or queued agent
    # runs. By default limits auto-pick to one concurrent run per project
    # so agents focus on finishing work before starting new issues. The
    # scheduler bypasses this guard via +allow_concurrent_runs+ when
    # distributing idle capacity across projects.
    def project_has_active_runs?
      AgentRun.where(project: @project, status: %w[queued pending running]).exists?
    end

    # Returns true if the project has open pull requests that still need
    # Paid's attention. Performs up to two lightweight EXISTS-style queries
    # (leveraging the GIN labels index) instead of loading PR records into Ruby:
    #
    # Blocking rules:
    # - failed PRs always block (need investigation)
    # - in_progress PRs block unless fully handed off (paid-generated +
    #   paid-ready labels and out of draft/restarted phase)
    def project_has_prs_needing_attention?
      base = Issue.where(
        project: @project,
        is_pull_request: true,
        github_state: "open",
        paid_state: %w[in_progress failed]
      )

      # Failed PRs always block — check first for a fast short-circuit.
      return true if base.where(paid_state: "failed").exists?

      # In-progress PRs block unless handed off: both labels present and
      # not in a draft/restarted review phase.
      handed_off = base
        .where(paid_state: "in_progress")
        .where("labels @> ?::jsonb", [ PAID_GENERATED_LABEL, PAID_READY_LABEL ].to_json)
        .where.not(pr_review_phase: %w[draft restarted])

      base.where(paid_state: "in_progress")
        .where.not(id: handed_off)
        .exists?
    end

    def find_next_eligible_issue
      scope = Issue.ready_for_work(@project)
        .where(paid_state: %w[new planning failed])
        .where.not(id: issues_with_active_runs)
        .where(source: "github")

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
      # Exclude issues that have any of the EXCLUDED_LABELS in their
      # JSONB labels column. Uses @> (contains) per label, which is
      # compatible with ActiveRecord's bind-parameter syntax (the ?|
      # operator conflicts with ActiveRecord's ? placeholder).
      EXCLUDED_LABELS.reduce(scope) do |s, label|
        s.where.not("labels @> ?::jsonb", [ label ].to_json)
      end
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
