# frozen_string_literal: true

module Dashboard
  # Explains an empty queue from scheduler-owned facts. This is deliberately a
  # read model: recovery and semantic assessment stay in their bounded jobs.
  # @spec AUTO-PICK-QUEUE-014
  class QueueDiagnosis
    Result = Data.define(
      :status, :project_ids, :open_count, :eligible_count, :queued_count,
      :active_count, :held_count, :error
    )

    def self.call(...) = new(...).call

    def initialize(user:)
      @user = user
    end

    def call
      projects = visible_projects
      counts = scheduler_counts(projects)
      eligible = eligible_count(projects)
      build_result(projects, counts, eligible)
    rescue ActiveRecord::ActiveRecordError => error
      unknown_result(error)
    end

    private

    attr_reader :user

    def visible_projects
      Project.where(
        account_id: user.account_id,
        created_by_id: visible_owner_ids,
        auto_pick_enabled: true,
        active: true
      ).to_a
    end

    def visible_owner_ids
      [ user.id, *(AgentRun.orphaned_project_owner?(user) ? [ nil ] : []) ]
    end

    def scheduler_counts(projects)
      ids = projects.map(&:id)
      runs = AgentRun.where(project_id: ids)
      {
        queued: AgentRun.schedulable_queued_with_priority.where(project_id: ids).except(:select, :order).count,
        active: runs.where(status: AgentRun::ACTIVE_STATUSES).count
      }
    end

    def eligible_count(projects)
      feasibility = Runners::TierFeasibility.new
      projects.sum do |project|
        Automation::Strategies::AutoPick::DefaultCandidateSource
          .eligible_scope(project, tier_feasibility: feasibility).count
      end
    end

    def build_result(projects, counts, eligible)
      open_count = Issue.where(project: projects, github_state: "open", is_pull_request: false).count
      status = diagnosis_status(projects, counts, eligible, open_count)
      Result.new(
        status:, project_ids: projects.map(&:id), open_count:, eligible_count: eligible,
        queued_count: counts[:queued], active_count: counts[:active],
        held_count: [ open_count - eligible, 0 ].max, error: nil
      )
    end

    def diagnosis_status(projects, counts, eligible, open_count)
      return :paused if deliberately_paused?(projects)
      return :backend_queued if counts[:queued].positive?
      return :runnable_unseeded if eligible.positive?
      return :active_work if counts[:active].positive?
      return :held if open_count.positive?

      :healthy
    end

    def deliberately_paused?(projects)
      user.account.scheduler_paused? || projects.any? { |project| project.scheduler_paused? || project.quality_paused? }
    end

    def unknown_result(error)
      Rails.logger.warn(
        message: "dashboard.queue_diagnosis_unavailable",
        account_id: user.account_id,
        user_id: user.id,
        error_class: error.class.name,
        error: error.message
      )
      Result.new(status: :unknown, project_ids: [], open_count: 0, eligible_count: 0,
        queued_count: 0, active_count: 0, held_count: 0, error: error.message)
    end
  end
end
