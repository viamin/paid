# frozen_string_literal: true

module Dashboard
  # @spec QUEUE-DELIVERY-DIAGNOSIS-001 QUEUE-DELIVERY-DIAGNOSIS-002 QUEUE-DELIVERY-DIAGNOSIS-003
  # Read-only explanation of the facts behind an empty queue projection. Recovery
  # belongs to the event and sweep paths; this object must stay safe for renders.
  class QueueDiagnosis
    Candidate = Data.define(:issue, :provenance)
    Snapshot = Data.define(:state, :open_count, :candidate_count, :queued_count, :active_count, :candidates, :action, :error)

    def self.call(...) = new(...).call

    def initialize(user:, rendered_count:)
      @user = user
      @rendered_count = rendered_count
    end

    def call
      breakdowns = EligibilityBreakdown.call(user: user)
      project_ids = visible_project_ids
      candidates = candidate_entries(breakdowns)
      candidate_count = breakdowns.sum(&:eligible)
      queued_count = AgentRun.where(project_id: project_ids, status: "queued").count
      active_count = AgentRun.capacity_inflight.where(project_id: project_ids).count

      Snapshot.new(
        state: state_for(breakdowns, candidate_count, queued_count, active_count),
        open_count: breakdowns.sum(&:total_open),
        candidate_count: candidate_count,
        queued_count: queued_count,
        active_count: active_count,
        candidates: candidates,
        action: action_for(breakdowns, candidate_count, queued_count, active_count),
        error: nil
      )
    rescue ActiveRecord::ActiveRecordError => error
      unknown(error)
    end

    private

    attr_reader :user, :rendered_count

    def visible_project_ids
      scope = Project.where(account_id: user.account_id, created_by_id: user.id)
      scope = scope.or(Project.where(account_id: user.account_id, created_by_id: nil)) if AgentRun.orphaned_project_owner?(user)
      scope.ids
    end

    def candidate_entries(breakdowns)
      feasibility = Runners::TierFeasibility.new
      breakdowns.flat_map do |breakdown|
        Automation::Strategies::AutoPick::DefaultCandidateSource
          .eligible_scope(breakdown.project, tier_feasibility: feasibility)
          .order(:github_number)
          .limit(20)
          .map { |issue| Candidate.new(issue:, provenance: "Eligible under current admission controls; awaiting queue seeding.") }
      end
    end

    def state_for(breakdowns, candidate_count, queued_count, active_count)
      return :rendered_stale if queued_count.positive? && rendered_count.zero?
      return :runnable_unseeded if candidate_count.positive? && queued_count.zero? && active_count.zero?
      return :healthy_active_work if active_count.positive? && candidate_count.zero?
      return :policy_or_resource_pause if paused_project_exists?
      return :configured_hold if breakdowns.sum(&:total_open).positive? && candidate_count.zero?

      :healthy_idle
    end

    def action_for(breakdowns, candidate_count, queued_count, active_count)
      return "Refresh the queue preview; scheduler rows exist but are not in this projection." if queued_count.positive? && rendered_count.zero?
      return "The periodic eligibility sweep will seed eligible work; inspect the listed candidates if it does not." if candidate_count.positive? && queued_count.zero? && active_count.zero?
      return "Active work is progressing; there is no additional eligible backlog." if active_count.positive? && candidate_count.zero?
      return "Review the project pause or automation policy before resuming work." if paused_project_exists?
      return "Inspect dependency and Inbox holds for the affected project." if breakdowns.sum(&:total_open).positive?

      "No automatic work is currently waiting."
    end

    def paused_project_exists?
      Project.where(id: visible_project_ids).where.not(scheduler_paused_at: nil).exists? ||
        Project.where(id: visible_project_ids).where.not(quality_paused_at: nil).exists? ||
        user.account.scheduler_paused?
    end

    def unknown(error)
      Rails.logger.warn(message: "dashboard.queue_diagnosis.unavailable", account_id: user.account_id, error_class: error.class.name)
      Snapshot.new(state: :unknown, open_count: nil, candidate_count: nil, queued_count: nil, active_count: nil,
        candidates: [], action: "Refresh the diagnosis after the data source recovers.", error: error.class.name)
    end
  end
end
