# frozen_string_literal: true

module Dashboard
  class EligibilityBreakdown
    CACHE_TTL = 15.seconds

    ProjectBreakdown = Struct.new(
      :project, :total_open, :eligible, :needs_input,
      :skip_label, :completed, :in_progress, :manual_review, :other_excluded,
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
      auto_pick_projects.map { |project| breakdown_for(project) }
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
        .select { |p| Issues::AutoPickProjectGate.call(p) }
    end

    # @spec OPERATOR-INBOX-002D
    def breakdown_for(project)
      open = Issue.where(project: project, github_state: "open", is_pull_request: false)

      eligible_scope = Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project)
      eligible_count = eligible_scope.count

      # Count all non-eligible issues in a single conditional-aggregation query.
      excluded = open.where.not(id: eligible_scope.select(:id))
      row = excluded.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE paid_state = 'in_progress')"),
        Arel.sql("COUNT(*) FILTER (WHERE paid_state = 'completed')"),
        Arel.sql("COUNT(*) FILTER (WHERE paid_state IN ('new','planning','failed','analyzed'))")
      ) || [ 0, 0, 0, 0 ]
      excluded_total, in_progress, completed, analyzable = row

      needs_input = excluded.where(paid_state: "needs_input").count
      manual_review = excluded.where(paid_state: "manual_review").count
      skip_label = count_skip_labeled(excluded, analyzable, project)
      other = excluded_total - needs_input - in_progress - completed - manual_review - skip_label

      ProjectBreakdown.new(
        project: project,
        total_open: eligible_count + excluded_total,
        eligible: eligible_count,
        needs_input: needs_input, skip_label: skip_label,
        completed: completed, in_progress: in_progress,
        manual_review: manual_review,
        other_excluded: other
      )
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
