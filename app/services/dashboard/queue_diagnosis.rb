# frozen_string_literal: true

module Dashboard
  # Read-only explanation for an empty Upcoming Queue. Recovery remains in the
  # event and sweep paths so a dashboard request can never start agent work.
  class QueueDiagnosis
    Result = Struct.new(:state, :eligible_count, :queued_count, :active_count, :entries, :next_action, :error, keyword_init: true)
    Entry = Struct.new(:issue, :blockers, :next_action, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(user:)
      @user = user
    end

    # @spec EAGER-QUEUE-017 EAGER-QUEUE-018
    def call
      return policy_pause_result if visible_projects.any? && paused_projects.size == visible_projects.size

      breakdowns = EligibilityBreakdown.call(user: user)
      eligible = breakdowns.sum(&:eligible)
      queued = visible_runs.where(status: "queued").count
      active = visible_runs.active.count

      return result(:active_work, eligible:, queued:, active:) if eligible.zero? && queued.zero? && active.positive?
      return unseeded_result(breakdowns, eligible:, queued:, active:) if eligible.positive? && queued.zero? && active.zero?
      return held_result(eligible:, queued:, active:) if eligible.zero? && queued.zero? && active.zero? && held_entries.any?

      result(:healthy_empty, eligible:, queued:, active:)
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn(message: "dashboard.queue_diagnosis_unavailable", account_id: user.account_id, error: error.message)
      Result.new(state: :unknown, eligible_count: nil, queued_count: nil, active_count: nil, entries: [], next_action: :refresh, error: error.message)
    end

    private

    attr_reader :user

    def result(state, eligible:, queued:, active:, entries: [], next_action: nil)
      Result.new(state:, eligible_count: eligible, queued_count: queued, active_count: active, entries:, next_action:)
    end

    def policy_pause_result
      result(:policy_paused, eligible: 0, queued: visible_runs.where(status: "queued").count,
        active: visible_runs.active.count, next_action: :resume_project)
    end

    def unseeded_result(breakdowns, eligible:, queued:, active:)
      entries = breakdowns.flat_map do |breakdown|
        eligible_issues(breakdown.project).map { |issue| Entry.new(issue:, blockers: [], next_action: :wait_for_eligibility_sweep) }
      end
      result(:runnable_unseeded, eligible:, queued:, active:, entries:, next_action: :wait_for_eligibility_sweep)
    end

    def held_result(eligible:, queued:, active:)
      result(:held, eligible:, queued:, active:, entries: held_entries, next_action: :inspect_inbox)
    end

    def held_entries
      @held_entries ||= visible_projects.flat_map do |project|
        Issue.where(project:, github_state: "open", is_pull_request: false).includes(:issue_dependencies).filter_map do |issue|
          blockers = issue.issue_dependencies.filter_map { |dependency| "dependency:#{dependency.depends_on_issue_id}" }
          next if blockers.empty?

          Entry.new(issue:, blockers:, next_action: :resolve_dependency)
        end
      end
    end

    def eligible_issues(project)
      Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project).to_a
    end

    def paused_projects
      @paused_projects ||= visible_projects.select { |project| project.scheduler_paused_at? || project.account.scheduler_paused_at? || project.quality_paused_at? }
    end

    def visible_projects
      @visible_projects ||= Project.includes(:account).where(account_id: user.account_id, created_by_id: visible_owner_ids, auto_pick_enabled: true, active: true).to_a
    end

    def visible_owner_ids
      ids = [ user.id ]
      ids << nil if AgentRun.orphaned_project_owner?(user)
      ids
    end

    def visible_runs
      AgentRun.joins(:project).where(projects: { id: visible_projects.map(&:id) })
    end
  end
end
