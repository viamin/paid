# frozen_string_literal: true

module AgentPlanningHolds
  # Bounded backstop for planning holds whose issue closed before the
  # Issue close/reopen hooks existed (or whose close event was missed, e.g. a
  # webhook gap). The event-driven hooks on Issue cover the normal path; this
  # sweep only re-reads persisted holds so the existing backlog (and any
  # future gap) eventually clears without operator action.
  #
  # A hold recorded before its issue synchronized locally has no `issue_id`
  # yet; it is swept by remote issue number within its own project so a
  # closure is not missed solely because local sync lagged the GitHub write.
  # @spec CONFIDENCE-DELIVERY-019
  class SweepClosedIssues
    DEFAULT_BATCH_SIZE = 200

    def self.call(...) = new(...).call

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      @batch_size = batch_size
    end

    def call
      reconciled = 0
      (linked_pending_holds + unlinked_pending_holds).each do |hold|
        reconciled += 1 if reconcile(hold)
      end
      reconciled
    end

    private

    attr_reader :batch_size

    def reconcile(hold)
      AgentPlanningHolds::Reconcile.call(hold:)
      true
    rescue => e
      Rails.logger.error(
        message: "agent_planning_holds.closed_issue_sweep_reconcile_failed",
        hold_id: hold.id,
        error: e.message
      )
      false
    end

    def linked_pending_holds
      AgentPlanningHold.where(status: AgentPlanningHold::PENDING_STATUSES)
        .joins(:issue).where(issues: { github_state: "closed" })
        .limit(batch_size)
    end

    def unlinked_pending_holds
      AgentPlanningHold.where(status: AgentPlanningHold::PENDING_STATUSES, issue_id: nil)
        .where(<<~SQL.squish)
          EXISTS (
            SELECT 1 FROM issues
            WHERE issues.project_id = agent_planning_holds.project_id
              AND issues.github_number = agent_planning_holds.remote_issue_number
              AND issues.github_state = 'closed'
          )
        SQL
        .limit(batch_size)
    end
  end
end
