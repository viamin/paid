# frozen_string_literal: true

module Dashboard
  # Explains an empty queue from the same eligibility projection that feeds the
  # dashboard breakdown. This is intentionally query-only: recovery belongs to
  # event handlers and the bounded eligibility sweep, never a page render.
  class QueueDiagnosis
    Snapshot = Data.define(
      :state, :eligible_count, :queued_count, :active_count, :excluded_count,
      :project_count, :refreshed_at, :next_action, :error_class
    )

    def self.call(...)
      new(...).call
    end

    def initialize(user:)
      @user = user
    end

    # @spec QUEUE-DIAGNOSIS-001 QUEUE-DIAGNOSIS-002 QUEUE-DIAGNOSIS-003
    # @spec QUEUE-DIAGNOSIS-004 QUEUE-DIAGNOSIS-005
    def call
      breakdowns = EligibilityBreakdown.call(user: user)
      snapshot_for(breakdowns)
    rescue ActiveRecord::ActiveRecordError, RedisClient::Error => error
      unknown_snapshot(error)
    end

    private

    attr_reader :user

    def snapshot_for(breakdowns)
      project_ids = breakdowns.map { |breakdown| breakdown.project.id }
      counts = run_counts(project_ids)
      eligible_count = breakdowns.sum(&:eligible)
      excluded_count = breakdowns.sum { |breakdown| breakdown.total_open - breakdown.eligible }

      Snapshot.new(
        state: state_for(project_ids:, eligible_count:, excluded_count:, **counts),
        eligible_count:, excluded_count:, project_count: project_ids.size,
        refreshed_at: Time.current, next_action: next_action_for(project_ids:, eligible_count:, excluded_count:, **counts),
        **counts, error_class: nil
      )
    end

    def run_counts(project_ids)
      scope = AgentRun.where(project_id: project_ids)
      { queued_count: scope.where(status: "queued").count, active_count: scope.active.count }
    end

    def state_for(project_ids:, eligible_count:, excluded_count:, queued_count:, active_count:)
      return :resource_or_policy_paused if project_ids.empty? && paused_auto_pick_projects?
      return :runnable_work_not_seeded if eligible_count.positive? && queued_count.zero?
      return :healthy_active_work if active_count.positive? && eligible_count.zero? && queued_count.zero?
      return :genuine_holds if eligible_count.zero? && excluded_count.positive?

      :idle
    end

    def next_action_for(project_ids:, eligible_count:, excluded_count:, queued_count:, active_count:)
      return "Resume the paused project when its policy permits work." if project_ids.empty? && paused_auto_pick_projects?
      return "The bounded eligibility sweep will seed this runnable work; refresh after it runs." if eligible_count.positive? && queued_count.zero?
      return "Active work is progressing; there is no waiting backlog." if active_count.positive? && eligible_count.zero? && queued_count.zero?
      return "Review the actionable Inbox entries for dependencies or human decisions." if eligible_count.zero? && excluded_count.positive?

      "No runnable or active work is currently visible."
    end

    def paused_auto_pick_projects?
      Project.where(account_id: user.account_id, created_by_id: visible_owner_ids, auto_pick_enabled: true, active: true)
        .where.not(scheduler_paused_at: nil).exists? || user.account.scheduler_paused_at.present?
    end

    def visible_owner_ids
      owner_ids = [ user.id ]
      owner_ids << nil if AgentRun.orphaned_project_owner?(user)
      owner_ids
    end

    def unknown_snapshot(error)
      Snapshot.new(
        state: :unknown, eligible_count: nil, queued_count: nil, active_count: nil,
        excluded_count: nil, project_count: nil, refreshed_at: Time.current,
        next_action: "Refresh this panel after the diagnosis service recovers.", error_class: error.class.name
      )
    end
  end
end
