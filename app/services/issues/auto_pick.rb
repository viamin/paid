# frozen_string_literal: true

module Issues
  # Selects the next unblocked, eligible issue for a project and creates
  # a queued agent run for it. Used by queue seeding to surface latent
  # auto-pick work ahead of time so spare capacity can be consumed
  # without waiting for another project scan.
  #
  # Guards (checked before issue selection):
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
    NoRunnableProviderError = Class.new(StandardError)

    EXCLUDED_LABELS = %w[planning research waiting tracking epic].freeze
    PAID_READY_LABEL = "paid-ready"

    # SQL ILIKE patterns used to pre-filter potential tracker issues before
    # applying the full Ruby-level Issue::TRACKER_PATTERN check. Each pattern
    # must be a *superset* of its TRACKER_PATTERN counterpart so that no
    # tracker escapes the prefilter (e.g. "remaining%work" covers any
    # whitespace variant that `remaining\s+work` would match).
    TRACKER_SQL_PATTERNS = [ "%tracker%", "%remaining%work%", "%completion%criteria%", "%phase%tracker%", "%meta%issue%" ].freeze

    # Returns the Set of issue IDs from +displayed_issues+ that are
    # currently eligible for auto-picking (per-issue criteria only;
    # ignores transient project-level guards like active runs or PRs
    # needing attention).  Scoping to the displayed issues helps limit
    # query cost and focuses results on the currently displayed subset.
    def self.eligible_issue_ids(displayed_issues)
      return Set.new if displayed_issues.empty?

      displayed_ids = displayed_issues.map(&:id)
      project = displayed_issues.first.project
      build_eligible_scope(project)
        .where(id: displayed_ids)
        .pluck(:id)
        .to_set
    end

    # Builds the base eligible-issue scope for a project. Shared by
    # +eligible_issue_ids+ (class method) and +find_next_eligible_issue+
    # (instance method) so both callers go through the same public API.
    def self.build_eligible_scope(project)
      scope = Issue.ready_for_work(project)
        .where(paid_state: %w[new planning failed])
        .where.not(id: AgentRun.where(project: project, status: %w[queued pending running]).where.not(issue_id: nil).select(:issue_id))
        .where(source: Issue::GITHUB_SOURCE)
        .where.not(id: Issue.where(project: project).where.not(parent_issue_id: nil).distinct.select(:parent_issue_id))

      trusted_usernames = Array(project.allowed_github_usernames).presence
      scope = scope.where(github_creator_login: trusted_usernames) if trusted_usernames

      scope = EXCLUDED_LABELS.reduce(scope) do |s, label|
        s.where.not("labels @> ?::jsonb", [ label ].to_json)
      end

      # Exclude tracker/meta issues that still have open referenced issues.
      # Trackers are pickable only once every issue referenced in their body
      # is closed (per collaborator feedback).
      blocked_ids = tracker_ids_blocked_by_open_references(project)
      scope = scope.where.not(id: blocked_ids) if blocked_ids.present?

      scope
    end

    # Identifies tracker issues whose body references other issues that are
    # still open. Uses a SQL pre-filter (ILIKE) to narrow candidates, then
    # applies the full Ruby-side TRACKER_PATTERN and reference parsing.
    # Only queries open/closed state for issue numbers actually referenced
    # by tracker candidates (not all project issues).
    def self.tracker_ids_blocked_by_open_references(project)
      open_issues = Issue.where(project: project, github_state: "open", is_pull_request: false)

      ilike_conditions = TRACKER_SQL_PATTERNS.flat_map.with_index do |_, i|
        [ "title ILIKE :t#{i}", "body ILIKE :t#{i}" ]
      end
      params = TRACKER_SQL_PATTERNS.each_with_index.to_h do |pattern, i|
        [ :"t#{i}", pattern ]
      end

      candidates = open_issues.where(ilike_conditions.join(" OR "), **params)
        .select(:id, :github_number, :title, :body)
      return [] if candidates.empty?

      # Collect all referenced numbers from tracker candidates, excluding
      # self-references, then query only those numbers' open states.
      refs_by_issue = candidates.filter_map do |issue|
        next unless issue.tracker_issue?

        refs = issue.body_referenced_issue_numbers - [ issue.github_number ]
        [ issue.id, refs ] if refs.present?
      end
      return [] if refs_by_issue.empty?

      all_referenced_numbers = refs_by_issue.flat_map(&:last).uniq
      open_referenced = Issue.where(
        project: project, github_state: "open",
        is_pull_request: false, github_number: all_referenced_numbers
      ).pluck(:github_number).to_set

      refs_by_issue.filter_map do |issue_id, refs|
        issue_id if refs.any? { |num| open_referenced.include?(num) }
      end
    end

    def initialize(project)
      @project = project
    end

    def call
      return nil unless @project.auto_pick_enabled?
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
    rescue NoRunnableProviderError => e
      Rails.logger.warn(
        message: "auto_pick.no_runnable_provider",
        project_id: @project.id,
        error: e.message
      )
      nil
    end

    private

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
        .where("labels @> ?::jsonb", [ @project.generated_label_name, PAID_READY_LABEL ].to_json)
        .where.not(pr_review_phase: %w[draft restarted])

      base.where(paid_state: "in_progress")
        .where.not(id: handed_off)
        .exists?
    end

    def eligible_issue_scope
      self.class.build_eligible_scope(@project)
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

    def create_agent_run(issue)
      provider = resolve_provider
      raise NoRunnableProviderError, "No runnable provider could be resolved for this project." unless provider

      AgentRun.create!(
        project: @project,
        issue: issue,
        provider: provider,
        agent_type: Provider.agent_type_for(provider.provider_key),
        status: "queued",
        trigger_type: "automatic",
        auto_pick: true
      )
    end

    def resolve_provider
      owner = @project.effective_owner
      return unless owner

      settings = AgentRuns::UserSettingsResolver.call(project: @project, strict: false)
      return Provider.ensure_default_for(owner) unless settings

      Provider.for_identifier(settings.user, settings.default_provider_identifier) || Provider.ensure_default_for(settings.user)
    end
  end
end
