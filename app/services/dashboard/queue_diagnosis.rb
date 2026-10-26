# frozen_string_literal: true

module Dashboard
  # Read-only explanation of why a visible auto-pick queue has no waiting
  # work. Recovery belongs to the periodic auto-pick sweep; rendering this
  # projection must never reconcile holds, call an LLM, or mutate GitHub.
  # @spec QUEUE-DIAGNOSIS-001 @spec QUEUE-DIAGNOSIS-002 @spec QUEUE-DIAGNOSIS-003
  class QueueDiagnosis
    Entry = Data.define(:issue, :blockers, :last_assessed_at, :next_action)
    Result = Data.define(:state, :eligible_count, :queued_count, :active_count, :entries, :recovery_action) do
      def unknown? = state == :unknown
    end

    ENTRY_LIMIT = 20

    def self.call(...) = new(...).call

    def initialize(user:)
      @user = user
    end

    def call
      breakdowns = EligibilityBreakdown.call(user: user)
      project_ids = breakdowns.map { |breakdown| breakdown.project.id }
      counts = counts_for(project_ids)
      Result.new(
        state: state_for(breakdowns, counts),
        eligible_count: breakdowns.sum(&:eligible),
        queued_count: counts[:queued],
        active_count: counts[:active],
        entries: entries_for(breakdowns, counts),
        recovery_action: recovery_action_for(breakdowns, counts)
      )
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn(message: "dashboard.queue_diagnosis_unavailable", account_id: user.account_id, error_class: error.class.name)
      unavailable_result
    end

    private

    attr_reader :user

    def counts_for(project_ids)
      return { queued: 0, active: 0 } if project_ids.empty?

      runs = AgentRun.where(project_id: project_ids)
      { queued: runs.where(status: "queued").count, active: runs.active.count }
    end

    def state_for(breakdowns, counts)
      return :waiting_work if counts[:queued].positive?
      return :healthy_active_work if counts[:active].positive?
      return :runnable_unseeded if breakdowns.sum(&:eligible).positive?
      return :resource_or_policy_paused if paused?(breakdowns)
      return :held if breakdowns.sum(&:total_open).positive?

      :healthy_empty
    end

    def entries_for(breakdowns, counts)
      return [] unless counts.values.all?(&:zero?)

      if breakdowns.sum(&:eligible).positive?
        eligible_entries(breakdowns)
      elsif breakdowns.sum(&:total_open).positive?
        held_entries(breakdowns)
      else
        []
      end
    end

    def eligible_entries(breakdowns)
      feasibility = Runners::TierFeasibility.new
      breakdowns.flat_map do |breakdown|
        Automation::Strategies::AutoPick::DefaultCandidateSource
          .eligible_scope(breakdown.project, tier_feasibility: feasibility).limit(ENTRY_LIMIT).map do |issue|
          Entry.new(issue:, blockers: [], last_assessed_at: issue.updated_at, next_action: "Wait for the bounded auto-pick sweep")
        end
      end.first(ENTRY_LIMIT)
    end

    def held_entries(breakdowns)
      Issue.where(project_id: breakdowns.map { |breakdown| breakdown.project.id }, github_state: "open", is_pull_request: false)
        .includes(issue_dependencies: :depends_on_issue).order(updated_at: :desc).limit(ENTRY_LIMIT).map do |issue|
        Entry.new(issue:, blockers: blockers_for(issue), last_assessed_at: issue.updated_at, next_action: "Inspect the listed blocker")
      end
    end

    def blockers_for(issue)
      blockers = issue.issue_dependencies.filter_map do |dependency|
        "Dependency ##{dependency.depends_on_issue.github_number}" if dependency.depends_on_issue&.github_state == "open"
      end
      hold = FeatureIntents::IssueHold.call(issue: issue)
      blockers << hold.message if hold
      blockers.presence || [ "Admission controls currently exclude this issue" ]
    end

    def paused?(breakdowns)
      return false if breakdowns.empty?

      breakdowns.all? { |breakdown| breakdown.project.quality_paused_at.present? } || user.account.scheduler_paused_at.present?
    end

    def recovery_action_for(breakdowns, counts)
      return "Refresh diagnosis" if counts.nil?
      return "Review queued runs" if counts[:queued].positive?
      return "Monitor active work" if counts[:active].positive?
      return "Resume the project or scheduler" if paused?(breakdowns)
      return "The bounded auto-pick sweep will seed eligible work" if breakdowns.sum(&:eligible).positive?
      return "Resolve the listed blockers or use the Inbox" if breakdowns.sum(&:total_open).positive?

      "No action needed"
    end

    def unavailable_result
      Result.new(state: :unknown, eligible_count: nil, queued_count: nil, active_count: nil, entries: [], recovery_action: "Refresh diagnosis")
    end
  end
end
