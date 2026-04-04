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
  # - No existing unfinished (queued/pending/running/paused) agent run
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
        .where.not(id: AgentRun.where(project: project, status: AgentRun::AUTO_PICK_BLOCKING_STATUSES).where.not(issue_id: nil).select(:issue_id))
        .where(source: [ Issue::GITHUB_SOURCE, Issue::SYNTHETIC_CODE_SCANNING_SOURCE ])
        .where.not(id: Issue.where(project: project).where.not(parent_issue_id: nil).distinct.select(:parent_issue_id))

      trusted_usernames = Array(project.allowed_github_usernames).presence
      scope = scope.where(github_creator_login: trusted_usernames) if trusted_usernames

      scope = EXCLUDED_LABELS.reduce(scope) do |s, label|
        s.where.not("labels @> ?::jsonb", [ label ].to_json)
      end

      # Exclude tracker/meta issues that still have open referenced issues.
      # Trackers are pickable only once every issue referenced in their body
      # is closed (per collaborator feedback). The ILIKE scan runs against
      # +scope+ (not all open issues) to limit query cost.
      blocked_ids = tracker_ids_blocked_by_open_references(scope, project)
      scope = scope.where.not(id: blocked_ids) if blocked_ids.present?

      scope
    end

    # Identifies tracker issues whose body references other issues that are
    # still open. Uses a SQL pre-filter (ILIKE) to narrow candidates, then
    # applies the full Ruby-side TRACKER_PATTERN and reference parsing.
    # Only queries open/closed state for issue numbers actually referenced
    # by tracker candidates (not all project issues).
    #
    # +candidate_scope+ is the already-filtered eligible-issue scope so the
    # ILIKE scan runs only against issues that passed earlier filters (labels,
    # paid_state, dependencies, etc.) rather than all open project issues.
    # If this still becomes expensive on repos with thousands of eligible
    # issues, consider a trigram GIN index on (title, body) or a persisted
    # `tracker_issue` boolean column.
    #
    # Blocking policy:
    # - Trackers with body references are blocked when ANY reference is open
    #   or unknown (not yet synced). Only direct references are checked — not
    #   transitive dependencies of those references. Transitive checking is
    #   deferred because the IssueDependency graph may be incomplete for
    #   body-referenced issues, and the direct-reference check already
    #   catches the motivating scenario (#615).
    # - Trackers with NO body references are conservatively blocked — they
    #   likely track work not enumerated as #NNN references, and auto-picking
    #   them risks premature selection (see #615).
    def self.tracker_ids_blocked_by_open_references(candidate_scope, project)
      ilike_conditions = TRACKER_SQL_PATTERNS.each_with_index.flat_map do |_, i|
        [ "title ILIKE :t#{i}", "body ILIKE :t#{i}" ]
      end
      params = TRACKER_SQL_PATTERNS.each_with_index.to_h do |pattern, i|
        [ :"t#{i}", pattern ]
      end

      candidates = candidate_scope.where(ilike_conditions.join(" OR "), **params)
        .select(:id, :github_number, :title, :body)
      return [] if candidates.empty?

      refs_by_issue = candidates.filter_map do |issue|
        next unless issue.tracker_issue?

        refs = issue.body_referenced_issue_numbers - [ issue.github_number ]
        [ issue.id, refs ]
      end
      return [] if refs_by_issue.empty?

      no_ref_ids = refs_by_issue.filter_map { |id, refs| id if refs.empty? }
      with_refs = refs_by_issue.select { |_, refs| refs.present? }
      return no_ref_ids if with_refs.empty?

      all_referenced_numbers = with_refs.flat_map(&:last).uniq

      # Fetch referenced issues (any state) to distinguish open, closed, and
      # unknown. Unknown (missing) references are treated as blocking to
      # avoid auto-picking trackers when sync is incomplete.
      referenced_states = Issue.where(
        project: project,
        is_pull_request: false,
        github_number: all_referenced_numbers
      ).pluck(:github_number, :github_state).to_h

      blocked_with_refs = with_refs.filter_map do |issue_id, refs|
        issue_id if refs.any? do |num|
          state = referenced_states[num]
          state.nil? || state == "open"
        end
      end

      no_ref_ids + blocked_with_refs
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
        status: AgentRun::AUTO_PICK_BLOCKING_STATUSES
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
