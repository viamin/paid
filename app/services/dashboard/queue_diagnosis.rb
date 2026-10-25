# frozen_string_literal: true

module Dashboard
  # Explains an empty queue from the same candidate and scheduler relations the
  # dashboard already uses. It deliberately does not initiate recovery: semantic
  # reconciliation belongs to the bounded partial-closeout path, never a render.
  class QueueDiagnosis
    Result = Struct.new(
      :state, :eligible_count, :queued_count, :active_count, :blockers,
      :next_action, :assessed_at, :covered,
      keyword_init: true
    ) do
      def covered? = covered
    end

    CACHE_TTL = 10.seconds

    def self.call(...) = new(...).call

    def initialize(user:)
      @user = user
    end

    # @spec AUTO-PICK-QUEUE-017
    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { assess }
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid => error
      Rails.logger.warn(message: "dashboard.queue_diagnosis_unavailable", account_id: user.account_id, error_class: error.class.name)
      unknown_result
    end

    private

    attr_reader :user

    def assess
      breakdowns = EligibilityBreakdown.call(user: user)
      eligible_count = breakdowns.sum(&:eligible)
      project_ids = visible_project_ids
      queued_count = queued_runs(project_ids).count
      active_count = active_runs(project_ids).count
      blockers = blockers_for(breakdowns)

      Result.new(
        state: state_for(eligible_count:, queued_count:, active_count:, blockers:),
        eligible_count:, queued_count:, active_count:, blockers:,
        next_action: next_action_for(eligible_count:, active_count:, blockers:),
        assessed_at: Time.current,
        covered: true
      )
    end

    def state_for(eligible_count:, queued_count:, active_count:, blockers:)
      return :policy_paused if policy_paused?
      return :queued unless queued_count.zero?
      return :active_work if active_count.positive? && eligible_count.zero?
      return :runnable_unseeded if eligible_count.positive?
      return :held if blockers.any?

      :healthy
    end

    def next_action_for(eligible_count:, active_count:, blockers:)
      return "Resume the paused project or scheduler." if policy_paused?
      return "Refresh this queue after active work completes." if active_count.positive?
      return "Run the normal eligible-work seed; admission controls remain in effect." if eligible_count.positive?
      return "Open Inbox to inspect each hold and its supported action." if blockers.any?

      "No waiting backlog was found. Refresh to reassess."
    end

    def blockers_for(breakdowns)
      [
        blocker(:needs_input, breakdowns.sum(&:needs_input), "Open Inbox"),
        blocker(:manual_review, breakdowns.sum(&:manual_review), "Open Inbox"),
        blocker(:skip_label, breakdowns.sum(&:skip_label), "Review project admission policy"),
        blocker(:dependency, breakdowns.sum(&:other_excluded), "Open Inbox")
      ].compact
    end

    def blocker(kind, count, action)
      return if count.zero?

      { kind:, count:, action: }
    end

    def policy_paused?
      return true if user.account.scheduler_paused_at.present?

      Project.where(id: visible_project_ids, auto_pick_enabled: true)
        .where("scheduler_paused_at IS NOT NULL OR quality_paused_at IS NOT NULL")
        .exists?
    end

    def visible_project_ids
      @visible_project_ids ||= begin
        scope = Project.where(account_id: user.account_id, created_by_id: user.id)
        scope = scope.or(Project.where(account_id: user.account_id, created_by_id: nil)) if AgentRun.orphaned_project_owner?(user)
        scope.ids
      end
    end

    def queued_runs(project_ids)
      AgentRun.schedulable_queued_with_priority(mode: queue_fairness_mode)
        .where(project_id: project_ids)
        .except(:select, :order)
    end

    def active_runs(project_ids)
      AgentRun.active.where(project_id: project_ids)
    end

    def queue_fairness_mode
      @queue_fairness_mode ||= user.account.tenant_setting!.resolved_queue_fairness_mode
    end

    def unknown_result
      Result.new(
        state: :unknown, eligible_count: nil, queued_count: nil, active_count: nil,
        blockers: [], next_action: "Refresh this queue; diagnosis coverage is unavailable.",
        assessed_at: nil, covered: false
      )
    end

    def cache_key
      "dashboard/queue_diagnosis/#{user.account_id}/#{user.id}/#{Dashboard::CacheVersion.current(user.account, scope: Dashboard::CacheVersion::LISTS_SCOPE)}"
    end
  end
end
