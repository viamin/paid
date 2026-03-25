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
  # - Not labeled with excluded labels (planning, research, waiting,
  #   tracking, epic)
  # - Not a parent/tracking issue (has sub-issues)
  # - Ordered by priority: issues in partially-complete dependency trees
  #   first, then by unblock count (how many open issues depend on this
  #   one), then by github_number ascending as tiebreaker
  #
  # Returns the created AgentRun or nil if no eligible issue is found.
  class AutoPick
    EXCLUDED_LABELS = %w[planning research waiting tracking epic].freeze
    PAID_GENERATED_LABEL = "paid-generated"
    PAID_READY_LABEL = "paid-ready"

    # Returns the IDs of issues currently eligible for auto-picking,
    # based on per-issue criteria only (ignores transient project-level
    # guards like active runs or PRs needing attention).
    def self.eligible_issue_ids(project)
      new(project).send(:eligible_issue_scope).pluck(:id).to_set
    end

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

    def eligible_issue_scope
      scope = Issue.ready_for_work(@project)
        .where(paid_state: %w[new planning failed])
        .where.not(id: issues_with_active_runs)
        .where(source: Issue::GITHUB_SOURCE)
        .where.not(id: parent_issue_ids)

      trusted_usernames = Array(@project.allowed_github_usernames).presence
      scope = scope.where(github_creator_login: trusted_usernames) if trusted_usernames

      exclude_labeled_issues(scope)
    end

    def find_next_eligible_issue
      eligible_issue_scope
        .joins(priority_joins)
        .order(
          Arel.sql("COALESCE(started_trees.in_started_tree, 0) DESC"),
          Arel.sql("COALESCE(unblock_counts.unblock_count, 0) DESC"),
          Arel.sql("issues.github_number ASC")
        )
        .first
    end

    def issues_with_active_runs
      AgentRun.where(project: @project, status: %w[queued pending running])
        .where.not(issue_id: nil)
        .select(:issue_id)
    end

    # IDs of issues that are parents (have at least one sub-issue).
    # These are tracking/rollup issues, not actionable work.
    def parent_issue_ids
      Issue.where(project: @project)
        .where.not(parent_issue_id: nil)
        .distinct
        .select(:parent_issue_id)
    end

    # Precomputed LEFT JOINs for priority ordering. Uses subqueries
    # evaluated once (not per-row) so Postgres can plan efficiently.
    # All project_id values are quoted via connection.quote to prevent
    # SQL injection regardless of future changes to the call site.
    def priority_joins
      pid = Issue.connection.quote(@project.id)

      <<~SQL.squish
        LEFT JOIN (#{tree_progress_subquery(pid)}) started_trees
          ON started_trees.issue_id = issues.id
        LEFT JOIN (#{unblock_count_subquery(pid)}) unblock_counts
          ON unblock_counts.issue_id = issues.id
      SQL
    end

    # Returns issue IDs that are in a "started tree": at least one
    # sibling dependency (another issue blocking the same downstream
    # issue) is already closed. Only considers in-project, non-PR,
    # open downstream issues to avoid cross-project or closed-tree skew.
    def tree_progress_subquery(pid)
      <<~SQL.squish
        SELECT DISTINCT id1.depends_on_issue_id AS issue_id,
               1 AS in_started_tree
          FROM issue_dependencies id1
         INNER JOIN issues downstream
            ON downstream.id = id1.issue_id
           AND downstream.github_state = 'open'
           AND downstream.is_pull_request = FALSE
           AND downstream.project_id = #{pid}
         INNER JOIN issue_dependencies id2
            ON id2.issue_id = id1.issue_id
           AND id2.depends_on_issue_id != id1.depends_on_issue_id
         INNER JOIN issues sibling
            ON sibling.id = id2.depends_on_issue_id
           AND sibling.github_state = 'closed'
           AND sibling.is_pull_request = FALSE
           AND sibling.project_id = #{pid}
      SQL
    end

    # Count of open, non-PR issues that directly depend on each issue.
    def unblock_count_subquery(pid)
      <<~SQL.squish
        SELECT issue_dependencies.depends_on_issue_id AS issue_id,
               COUNT(*) AS unblock_count
          FROM issue_dependencies
         INNER JOIN issues dep_issues
            ON dep_issues.id = issue_dependencies.issue_id
           AND dep_issues.github_state = 'open'
           AND dep_issues.is_pull_request = FALSE
           AND dep_issues.project_id = #{pid}
         GROUP BY issue_dependencies.depends_on_issue_id
      SQL
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
