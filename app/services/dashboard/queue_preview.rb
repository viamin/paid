# frozen_string_literal: true

module Dashboard
  class QueuePreview
    Entry = Struct.new(:position, :run, :waiting_reason, keyword_init: true)

    NEXT_UP = "Next up"
    WAITING_FOR_CAPACITY = "Waiting for capacity"
    WAITING_FOR_PROJECT_SLOT = "Waiting for project slot"
    LOWER_PRIORITY = "Lower priority"
    BUDGET_EXCEEDED = "Budget exceeded"

    # Cap on the number of rows fetched from the queue. This limits the
    # single snapshot query rather than controlling a loop, so there is no
    # N+1 concern. The cap exists to keep the result set reasonable; when
    # the user's visible runs are all beyond this window we show a
    # truncation notice rather than silently dropping them.
    MAX_SCAN = 200

    def self.call(...)
      new(...).call
    end

    def initialize(user:, limit: 20)
      @user = user
      @limit = limit
    end

    def call
      return [] if visible_project_ids.empty?

      snapshot = fetch_snapshot
      visible_runs = snapshot.select { |run| visible_project_ids.include?(run.project_id) }
      preload_associations(visible_runs)

      entries = []
      earlier_runs = []

      snapshot.each do |run|
        if visible_project_ids.include?(run.project_id) && entries.size < limit
          entries << Entry.new(
            position: entries.size + 1,
            run:,
            waiting_reason: waiting_reason_for(run, earlier_runs)
          )
        end

        earlier_runs << run
      end

      entries
    end

    private

    attr_reader :user, :limit

    def visible_project_ids
      @visible_project_ids ||= begin
        scope = Project.where(account_id: user.account_id, created_by_id: user.id)
        if AgentRun.orphaned_project_owner?(user)
          scope = scope.or(Project.where(account_id: user.account_id, created_by_id: nil))
        end

        scope.ids
      end
    end

    # Fetch the ordered snapshot in a single query instead of iterating
    # peek_next_queued_run one-at-a-time. This uses the raw QUEUE_ORDER
    # rather than the fair-queue round-robin reordering that
    # next_queued_run_from applies; for a read-only preview the scheduler
    # consideration order is more informative and avoids up to 3 queries
    # per iteration.
    def fetch_snapshot
      AgentRun.schedulable_queued_with_priority
              .reorder(*AgentRun::QUEUE_ORDER)
              .limit(MAX_SCAN)
              .to_a
    end

    def preload_associations(runs)
      ActiveRecord::Associations::Preloader.new(
        records: runs,
        associations: [ :issue, { project: :cost_budgets } ]
      ).call
      AgentRun.preload_source_pull_requests(runs)
    end

    def waiting_reason_for(run, earlier_runs)
      return BUDGET_EXCEEDED if budget_exceeded?(run)
      return WAITING_FOR_CAPACITY if user_at_capacity?(run, earlier_runs)
      return LOWER_PRIORITY if earlier_runs.any? { |candidate| candidate.queue_priority.to_i < run.queue_priority.to_i }
      return WAITING_FOR_PROJECT_SLOT if waiting_for_project_slot?(run, earlier_runs)

      # First run in line with free capacity — ready to be picked up.
      NEXT_UP
    end

    def budget_exceeded?(run)
      project_budgets(run.project).any? do |budget|
        next false if budget.budget_type == "per_run"
        next false if budget_period_expired?(budget)

        budget.hard_stop? && budget.hard_stop_exceeded?
      end
    end

    def project_budgets(project)
      @project_budgets ||= {}
      @project_budgets[project.id] ||= project.cost_budgets.to_a
    end

    def budget_period_expired?(budget)
      case budget.budget_type
      when "daily"
        budget.period_started_at.present? && budget.period_started_at < Time.current.beginning_of_day
      when "monthly"
        budget.period_started_at.present? && budget.period_started_at < Time.current.beginning_of_month
      else
        false
      end
    end

    def user_at_capacity?(run, earlier_runs)
      capacity = owner_capacity(run.project_owner_user_id)
      queued_ahead = earlier_runs.count { |candidate| candidate.project_owner_user_id == run.project_owner_user_id }

      capacity[:active] + queued_ahead >= capacity[:max]
    end

    def owner_capacity(owner_id)
      @owner_capacity ||= {}
      @owner_capacity[owner_id] ||= begin
        owner = owner_id == user.id ? user : User.includes(:account, :settings).find(owner_id)

        {
          active: AgentRun.active_count_for_user(owner),
          max: owner.account.tenant_max_concurrent_runs(owner.settings.max_concurrent_runs)
        }
      end
    end

    def waiting_for_project_slot?(run, earlier_runs)
      return false unless truthy_queue_attribute?(run.fair_queue_across_projects)
      return false unless run.project_owner_user_id

      # Only flag as a project-slot wait when an earlier run from a
      # *different* project of the same owner at the same priority tier
      # exists. Without the project_id check, a single-project owner
      # would incorrectly see "Waiting for project slot" on their second
      # queued run even though no cross-project rotation is happening.
      earlier_runs.any? do |candidate|
        candidate.project_owner_user_id == run.project_owner_user_id &&
          candidate.queue_priority.to_i == run.queue_priority.to_i &&
          candidate.project_id != run.project_id
      end
    end

    def truthy_queue_attribute?(value)
      value == true || %w[1 t true].include?(value.to_s)
    end
  end
end
