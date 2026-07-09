# frozen_string_literal: true

module Dashboard
  class EligibilityBreakdown
    CACHE_TTL = 15.seconds

    ProjectBreakdown = Struct.new(
      :project, :total_open, :eligible, :needs_input,
      :skip_label, :completed, :in_progress, :other_excluded,
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

    def auto_pick_projects
      @auto_pick_projects ||= Project
        .includes(:account)
        .where(account_id: user.account_id, created_by_id: user.id,
               auto_pick_enabled: true, active: true)
        .reject { |p| p.scheduler_paused? || p.quality_paused? || p.account&.scheduler_paused? }
    end

    def breakdown_for(project)
      open = Issue.where(project: project, github_state: "open", is_pull_request: false)

      eligible_ids = Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_scope(project).pluck(:id).to_set

      # Count all non-eligible issues in a single conditional-aggregation query.
      excluded = open.where.not(id: eligible_ids)
      row = excluded.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE paid_state = 'needs_input')"),
        Arel.sql("COUNT(*) FILTER (WHERE paid_state = 'in_progress')"),
        Arel.sql("COUNT(*) FILTER (WHERE paid_state = 'completed')"),
        Arel.sql("COUNT(*) FILTER (WHERE paid_state IN ('new','planning','failed','analyzed'))")
      ) || [ 0, 0, 0, 0, 0 ]
      excluded_total, needs_input, in_progress, completed, analyzable = row

      skip_label = count_skip_labeled(excluded, analyzable, project)
      other = excluded_total - needs_input - in_progress - completed - skip_label

      ProjectBreakdown.new(
        project: project,
        total_open: eligible_ids.size + excluded_total,
        eligible: eligible_ids.size,
        needs_input: needs_input, skip_label: skip_label,
        completed: completed, in_progress: in_progress,
        other_excluded: other
      )
    end

    def count_skip_labeled(excluded_scope, analyzable_count, project)
      return 0 if analyzable_count.zero?

      labels = project.effective_auto_pick_skip_labels
      return 0 if labels.empty?

      excluded_scope.where(paid_state: %w[new planning failed analyzed])
        .pluck(:labels)
        .count { |issue_labels| (Array(issue_labels).map(&:downcase) & labels).any? }
    end

    def cache_key
      "dashboard/eligibility_breakdown/#{user.account_id}/#{user.id}/" \
        "#{Dashboard::CacheVersion.current(user.account, scope: Dashboard::CacheVersion::LISTS_SCOPE)}"
    end
  end
end
