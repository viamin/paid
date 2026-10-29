# frozen_string_literal: true

module Dashboard
  class EligibilityBreakdown
    CACHE_TTL = 15.seconds
    ProjectBreakdown = Struct.new(
      :project, :total_open, :eligible, :needs_input,
      :skip_label, :completed, :in_progress, :manual_review, :other_excluded,
      :queued, :active, :paused, :unseeded, :held_issues, :dependency_cycles, :diagnostic_state,
      keyword_init: true
    )

    def self.call(...)
      new(...).call
    end

    def initialize(user:)
      @user = user
    end

    def call
      return [] if auto_pick_projects.empty?

      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build }
    end

    private

    attr_reader :user

    def build
      # One tier-feasibility resolver for the whole pass. Feasibility
      # depends only on the owner's runner configuration, so projects sharing an
      # owner share one resolution; resolving it per project would re-read the
      # same configuration once per repo (#4556).
      tier_feasibility = Runners::TierFeasibility.new
      projects = auto_pick_projects
      handoff_counts = handoff_counts_by_project(projects)
      inputs = projects.to_h { |project| [ project.id, breakdown_inputs(project, tier_feasibility) ] }
      excluded = inputs.values.map { |input| input.fetch(:excluded) }.reduce(&:or)
      held_issues = HeldWorkDetails.call(excluded:, projects:)
      dependency_cycles = dependency_cycles_by_project(projects)
      projects.map do |project|
        breakdown_for(
          project,
          input: inputs.fetch(project.id),
          handoff_counts: handoff_counts,
          held_issues: held_issues.fetch(project.id, []),
          dependency_cycles: dependency_cycles.fetch(project.id, [])
        )
      end
    end

    # Preload everything the per-project gate and breakdown touch so a dashboard
    # with many auto-pick repos doesn't devolve into an N+1:
    #   - +account+ and +created_by+ feed +Issues::AutoPickProjectGate#effective_owner+
    #     (created_by is used directly; account backs the orphaned fallback).
    #   - +created_by.user_setting+ and +account.tenant_setting+ feed
    #     +#count_skip_labeled+ via +Project#effective_auto_pick_skip_labels+,
    #     which walks owner -> tenant when neither the project nor owner sets
    #     skip labels.
    def auto_pick_projects
      @auto_pick_projects ||= Project
        .includes(account: :tenant_setting, created_by: :user_setting)
        .where(
          account_id: user.account_id,
          created_by_id: visible_owner_ids,
          auto_pick_enabled: true,
          active: true
        )
        .select { |p| Issues::AutoPickProjectGate.call(p) || deliberately_paused?(p) }
    end

    # @spec OPERATOR-INBOX-002D QUEUE-HANDOFF-001 QUEUE-HANDOFF-002 QUEUE-HANDOFF-003
    def breakdown_inputs(project, tier_feasibility)
      open = Issue.where(project: project, github_state: "open", is_pull_request: false)
      eligible_scope = Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_scope(project, tier_feasibility: tier_feasibility)
      excluded = open.where.not(id: eligible_scope.select(:id))
      row = excluded.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE paid_state = 'in_progress')"),
        Arel.sql("COUNT(*) FILTER (WHERE paid_state = 'completed')"),
        Arel.sql("COUNT(*) FILTER (WHERE paid_state IN ('new','planning','failed','analyzed'))")
      ) || [ 0, 0, 0, 0 ]
      { eligible_count: eligible_scope.count, excluded:, row: }
    end

    # @spec OPERATOR-INBOX-002D QUEUE-HANDOFF-001 QUEUE-HANDOFF-002 QUEUE-HANDOFF-003
    def breakdown_for(project, input:, handoff_counts:, held_issues:, dependency_cycles:)
      eligible_count = input.fetch(:eligible_count)
      excluded = input.fetch(:excluded)
      excluded_total, in_progress, completed, analyzable = input.fetch(:row)

      needs_input = excluded.where(paid_state: "needs_input").count
      manual_review = excluded.where(paid_state: "manual_review").count
      skip_label = count_skip_labeled(excluded, analyzable, project)
      other = excluded_total - needs_input - in_progress - completed - manual_review - skip_label
      queued, active, paused = handoff_counts.fetch(project.id, [ 0, 0, 0 ])
      unseeded = eligible_count
      ProjectBreakdown.new(
        project: project,
        total_open: eligible_count + excluded_total,
        eligible: eligible_count,
        needs_input: needs_input, skip_label: skip_label,
        completed: completed, in_progress: in_progress,
        manual_review: manual_review,
        other_excluded: other,
        queued: queued,
        active: active,
        paused: paused,
        unseeded: unseeded,
        held_issues: held_issues,
        dependency_cycles: dependency_cycles,
        diagnostic_state: diagnostic_state(
          project:, unseeded:, queued:, active:, paused:, total_open: eligible_count + excluded_total
        )
      )
    end

    def dependency_cycles_by_project(projects)
      result = projects.index_with { [] }
      projects_by_id = projects.index_by(&:id)
      DependencyCycleOccurrence.active.where(account: user.account).find_each do |occurrence|
        Array(occurrence.details["project_ids"]).each do |project_id|
          project = projects_by_id[project_id]
          result.fetch(project) << occurrence if project
        end
      end
      result.transform_keys(&:id)
    end

    # Candidate eligibility is specific to open issues. Scheduler facts are
    # deliberately broader: the queue preview also shows manual and PR runs.
    def handoff_counts_by_project(projects)
      counts = AgentRun.where(project_id: projects, status: %w[queued running paused])
        .group(:project_id, :status)
        .count

      projects.to_h do |project|
        [ project.id, [ "queued", "running", "paused" ].map { |status| counts.fetch([ project.id, status ], 0) } ]
      end
    end

    # @spec QUEUE-HANDOFF-003
    def diagnostic_state(project:, unseeded:, queued:, active:, paused:, total_open:)
      return :paused if deliberately_paused?(project)
      return :paused if paused.positive?
      return :runnable_not_seeded if unseeded.positive?
      return :waiting if queued.positive?
      return :active_work if active.positive?
      return :held if total_open.positive?

      :idle
    end

    def deliberately_paused?(project)
      project.scheduler_paused? || project.quality_paused? || project.paused? || project.account.scheduler_paused?
    end

    def count_skip_labeled(excluded_scope, analyzable_count, project)
      return 0 if analyzable_count.zero?

      labels = project.effective_auto_pick_skip_labels
      return 0 if labels.empty?

      excluded_scope.where(paid_state: %w[new planning failed analyzed])
        .where(
          <<~SQL.squish,
            EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(issues.labels) AS label(value)
              WHERE LOWER(label.value) IN (?)
            )
          SQL
          labels.map(&:downcase)
        )
        .count
    end

    def visible_owner_ids
      owner_ids = [ user.id ]
      owner_ids << nil if AgentRun.orphaned_project_owner?(user)
      owner_ids
    end

    def cache_key
      "dashboard/eligibility_breakdown/#{user.account_id}/#{user.id}/" \
        "#{Dashboard::CacheVersion.current(user.account, scope: Dashboard::CacheVersion::LISTS_SCOPE)}"
    end
  end
end
