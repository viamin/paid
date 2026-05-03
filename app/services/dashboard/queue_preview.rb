# frozen_string_literal: true

module Dashboard
  class QueuePreview
    Entry = Struct.new(:position, :run, :waiting_reason, keyword_init: true)

    WAITING_FOR_CAPACITY = "Waiting for capacity"
    WAITING_FOR_PROJECT_SLOT = "Waiting for project slot"
    LOWER_PRIORITY = "Lower priority"
    BUDGET_EXCEEDED = "Budget exceeded"

    def self.call(...)
      new(...).call
    end

    def initialize(user:, limit: 20)
      @user = user
      @limit = limit
    end

    def call
      return [] if visible_project_ids.empty?

      snapshot = AgentRun.peek_queued_runs
      visible_runs = snapshot.select { |run| visible_project_ids.include?(run.project_id) }.first(limit)
      preload_associations(visible_runs)

      visible_runs.each_with_index.map do |run, index|
        Entry.new(
          position: index + 1,
          run:,
          waiting_reason: waiting_reason_for(run, snapshot)
        )
      end
    end

    private

    attr_reader :user, :limit

    def visible_project_ids
      @visible_project_ids ||= user.created_projects.ids
    end

    def preload_associations(runs)
      ActiveRecord::Associations::Preloader.new(records: runs, associations: [ :project, :issue ]).call
    end

    def waiting_reason_for(run, snapshot)
      return BUDGET_EXCEEDED if budget_exceeded?(run)
      return WAITING_FOR_CAPACITY if user_at_capacity?(run.project.effective_owner || user)

      earlier_runs = snapshot.take_while { |candidate| candidate.id != run.id }

      return LOWER_PRIORITY if earlier_runs.any? { |candidate| candidate.queue_priority.to_i < run.queue_priority.to_i }
      return WAITING_FOR_PROJECT_SLOT if waiting_for_project_slot?(run, earlier_runs)

      WAITING_FOR_CAPACITY
    end

    def budget_exceeded?(run)
      !CostBudgets::Check.call(run.project, agent_run: run)[:allowed]
    end

    def user_at_capacity?(owner)
      capacity = owner_capacity(owner)
      capacity[:active] >= capacity[:max]
    end

    def owner_capacity(owner)
      @owner_capacity ||= {}
      @owner_capacity[owner.id] ||= {
        active: AgentRun.active_count_for_user(owner),
        max: owner.account.tenant_max_concurrent_runs(owner.settings.max_concurrent_runs)
      }
    end

    def waiting_for_project_slot?(run, earlier_runs)
      return false unless truthy_queue_attribute?(run.fair_queue_across_projects)

      earlier_runs.any? do |candidate|
        candidate.project_owner_user_id == run.project_owner_user_id &&
          candidate.queue_priority.to_i == run.queue_priority.to_i
      end
    end

    def truthy_queue_attribute?(value)
      value == true || %w[1 t true].include?(value.to_s)
    end
  end
end
