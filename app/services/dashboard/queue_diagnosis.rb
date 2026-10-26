# frozen_string_literal: true

module Dashboard
  # Read-only explanation for an empty queue preview. Admission and recovery
  # remain owned by the candidate source and the periodic eligibility sweep.
  class QueueDiagnosis
    MAX_BLOCKERS = 20

    Blocker = Data.define(:issue, :kind, :owner, :message)
    Result = Data.define(
      :state, :eligible_count, :queued_count, :active_count, :blockers,
      :next_action, :assessed_at, :error
    )

    def self.call(...) = new(...).call

    def initialize(user:)
      @user = user
    end

    # @spec QUEUE-DIAGNOSIS-001 QUEUE-DIAGNOSIS-002 QUEUE-DIAGNOSIS-003 QUEUE-DIAGNOSIS-004 QUEUE-DIAGNOSIS-005
    def call
      return empty_result if projects.empty?

      build_result
    rescue StandardError => error
      Rails.logger.warn(
        message: "dashboard.queue_diagnosis_unavailable",
        account_id: user.account_id,
        user_id: user.id,
        error_class: error.class.name,
        error: error.message
      )
      unknown_result(error)
    end

    private

    attr_reader :user

    def build_result
      counts = queue_counts
      state = state_for(counts)
      Result.new(
        state:,
        **counts,
        blockers: state == :held ? blockers : [],
        next_action: action_for(state),
        assessed_at: Time.current,
        error: nil
      )
    end

    def queue_counts
      project_ids = projects.map(&:id)
      {
        eligible_count: eligible_count,
        queued_count: schedulable_queued_runs.where(project_id: project_ids).count,
        active_count: AgentRun.capacity_inflight.where(project_id: project_ids).count
      }
    end

    def state_for(counts)
      return :paused if paused_projects.any?
      return :held if blockers.any?
      return :runnable_unseeded if counts[:eligible_count].positive? && counts[:queued_count].zero? && counts[:active_count].zero?
      return :waiting_queue if counts[:queued_count].positive?
      return :healthy_active if counts[:active_count].positive?

      :empty
    end

    def eligible_count
      runnable_projects.sum do |project|
        Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project).count
      end
    end

    # QueuePreview uses the priority projection to order rows. Counting that
    # projection asks PostgreSQL to aggregate selected aliases, so use the
    # same admission predicates without its presentation-only select list.
    def schedulable_queued_runs
      AgentRun.queued.joins(project: :account)
        .where(accounts: { scheduler_paused_at: nil })
        .where(projects: { scheduler_paused_at: nil })
        .where("agent_runs.trigger_type = 'manual' OR projects.quality_paused_at IS NULL")
        .where("agent_runs.trigger_type = 'manual' OR projects.paused = FALSE")
    end

    def blockers
      @blockers ||= held_issues.flat_map { |issue| blockers_for(issue) }.first(MAX_BLOCKERS)
    end

    def held_issues
      Issue.where(project_id: projects.map(&:id), github_state: "open", is_pull_request: false)
        .includes(:issue_dependencies, :feature_intent_issues)
        .order(:id).limit(MAX_BLOCKERS).to_a
    end

    def blockers_for(issue)
      dependency_blockers(issue) + feature_blocker(issue)
    end

    def dependency_blockers(issue)
      issue.blocking_issues.limit(MAX_BLOCKERS).map do |owner|
        Blocker.new(issue:, kind: :dependency, owner:, message: "Blocked by ##{owner.github_number}")
      end
    end

    def feature_blocker(issue)
      hold = FeatureIntents::IssueHold.call(issue:)
      return [] unless hold

      [ Blocker.new(issue:, kind: :decision, owner: nil, message: hold.message) ]
    end

    def projects
      @projects ||= begin
        scope = Project.where(account_id: user.account_id, auto_pick_enabled: true, active: true)
        scope = scope.where(created_by_id: visible_owner_ids)
        scope.includes(:account, created_by: :user_setting).to_a
      end
    end

    def runnable_projects
      @runnable_projects ||= projects.reject { |project| paused?(project) }
        .select { |project| Issues::AutoPickProjectGate.call(project) }
    end

    def paused_projects
      @paused_projects ||= projects.select { |project| paused?(project) }
    end

    def paused?(project)
      project.account.scheduler_paused_at.present? || project.scheduler_paused_at.present? ||
        project.quality_paused_at.present? || project.paused?
    end

    def visible_owner_ids
      ids = [ user.id ]
      ids << nil if AgentRun.orphaned_project_owner?(user)
      ids
    end

    def action_for(state)
      {
        runnable_unseeded: "The eligibility sweep will retry seeding this work; refresh after it runs.",
        healthy_active: "No action needed while active work is progressing.",
        waiting_queue: "Queued work is waiting for scheduler capacity.",
        held: "Inspect the listed dependency or decision owner in the Inbox.",
        paused: "Resume the project or scheduler when the deliberate pause is ready to end.",
        empty: "No eligible or waiting work is visible for these projects."
      }.fetch(state)
    end

    def empty_result
      Result.new(state: :empty, eligible_count: 0, queued_count: 0, active_count: 0,
        blockers: [], next_action: action_for(:empty), assessed_at: Time.current, error: nil)
    end

    def unknown_result(error)
      Result.new(state: :unknown, eligible_count: nil, queued_count: nil, active_count: nil,
        blockers: [], next_action: "Refresh the dashboard after diagnostic coverage recovers.",
        assessed_at: Time.current, error: error.class.name)
    end
  end
end
