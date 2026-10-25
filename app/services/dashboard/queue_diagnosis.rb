# frozen_string_literal: true

module Dashboard
  # Explains an empty rendered queue without substituting a second candidate
  # query for scheduler admission. The candidate scope remains authoritative;
  # this service only compares that scope with persisted run state.
  class QueueDiagnosis
    SAMPLE_SIZE = 5
    ProjectState = Struct.new(:project, :eligible_count, :queued_count, :active_count, :open_count, :paused, keyword_init: true)
    Result = Struct.new(:state, :eligible_count, :queued_count, :active_count, :unseeded_issues,
      :project_states, :recovery_action, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(user:)
      @user = user
    end

    # @spec EAGER-QUEUE-017
    def call
      states, unseeded = visible_projects.map { |project| inspect(project) }.transpose
      states ||= []
      unseeded = Array(unseeded).flatten
      build_result(states, unseeded.first(SAMPLE_SIZE))
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn(message: "dashboard.queue_diagnosis.unavailable", account_id: user.account_id,
        user_id: user.id, error: error.class.name)
      Result.new(state: :unknown, eligible_count: 0, queued_count: 0, active_count: 0,
        unseeded_issues: [], project_states: [], recovery_action: "Refresh the dashboard after the queue data service recovers.")
    end

    private

    attr_reader :user

    def visible_projects
      Project.includes(:account).where(account_id: user.account_id, created_by_id: visible_owner_ids, active: true).to_a
    end

    def visible_owner_ids
      ids = [ user.id ]
      ids << nil if AgentRun.orphaned_project_owner?(user)
      ids
    end

    def inspect(project)
      return [ inactive_policy_state(project), [] ] unless project.auto_pick_enabled?
      return [ paused_state(project), [] ] if paused?(project)

      eligible = Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project)
      counts = run_counts(project)
      active_issue_ids = AgentRun.where(project:, status: AgentRun::UNFINISHED_STATUSES).where.not(issue_id: nil).select(:issue_id)
      unseeded = eligible.where.not(id: active_issue_ids).order(:github_number).limit(SAMPLE_SIZE).to_a

      [ ProjectState.new(project:, eligible_count: eligible.count, queued_count: counts.fetch("queued", 0),
          active_count: counts.except("queued").values.sum,
          open_count: Issue.where(project:, github_state: "open", is_pull_request: false).count, paused: false), unseeded ]
    end

    def paused?(project)
      project.scheduler_paused_at.present? || project.quality_paused_at.present? ||
        project.account.scheduler_paused_at.present?
    end

    def inactive_policy_state(project)
      ProjectState.new(project:, eligible_count: 0, queued_count: 0, active_count: 0, open_count: 0, paused: false)
    end

    def paused_state(project)
      counts = run_counts(project)
      ProjectState.new(project:, eligible_count: 0, queued_count: counts.fetch("queued", 0),
        active_count: counts.except("queued").values.sum,
        open_count: Issue.where(project:, github_state: "open", is_pull_request: false).count, paused: true)
    end

    def run_counts(project)
      AgentRun.where(project:, status: AgentRun::UNFINISHED_STATUSES).group(:status).count
    end

    def build_result(states, unseeded)
      eligible_count = states.sum(&:eligible_count)
      queued_count = states.sum(&:queued_count)
      active_count = states.sum(&:active_count)
      state = if unseeded.any?
        :runnable_unseeded
      elsif queued_count.positive?
        :backend_nonempty
      elsif active_count.positive?
        :active_work
      elsif states.any?(&:paused) && states.none? { |entry| !entry.paused && entry.open_count.positive? }
        :paused
      elsif states.any? { |entry| !entry.paused && entry.open_count.positive? }
        :held
      else
        :healthy
      end

      Result.new(state:, eligible_count:, queued_count:, active_count:, unseeded_issues: unseeded,
        project_states: states, recovery_action: recovery_action_for(state))
    end

    def recovery_action_for(state)
      case state
      when :runnable_unseeded
        "The automatic eligibility sweep will seed this work; refresh after its next run."
      when :active_work
        "Work is already active; wait for it to finish or inspect the active run."
      when :backend_nonempty
        "Refresh the queue preview; if it remains empty, inspect the queued run's admission state."
      when :held
        "Inspect dependencies and actionable Inbox decisions before changing admission policy."
      when :paused
        "An authorized operator must resume the affected project or policy before work can be admitted."
      else
        "No recovery action is currently required."
      end
    end
  end
end
