# frozen_string_literal: true

module Dashboard
  # Explains an empty preview from the scheduler's canonical inputs. This is a
  # read model: recovery remains in AutoPickEligibilitySweepJob so a dashboard
  # request never starts an agent, sync, or external mutation.
  # @spec QUEUE-DIAGNOSIS-001 QUEUE-DIAGNOSIS-002
  class QueueDiagnosis
    Item = Data.define(:issue, :kind, :owners)
    Result = Data.define(
      :project, :state, :eligible_count, :queued_count, :active_count,
      :items, :next_action, :assessed_at
    )

    def self.call(...) = new(...).call

    def initialize(user:)
      @user = user
    end

    def call
      visible_projects.map { |project| diagnose(project) }
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn(message: "dashboard.queue_diagnosis_unavailable", error_class: error.class.name)
      [ Result.new(project: nil, state: :unknown, eligible_count: 0, queued_count: 0, active_count: 0,
        items: [], next_action: :refresh, assessed_at: Time.current) ]
    end

    private

    attr_reader :user

    def visible_projects
      scope = Project.where(account_id: user.account_id, created_by_id: owner_ids, auto_pick_enabled: true, active: true)
      scope.includes(:account).order(:id)
    end

    def owner_ids
      ids = [ user.id ]
      ids << nil if AgentRun.orphaned_project_owner?(user)
      ids
    end

    def diagnose(project)
      counts = queue_counts(project)
      return result(project, :resource_or_policy_pause, counts, [], :resume_project) if paused?(project)
      return result(project, :resource_or_policy_pause, counts, [], :review_automation_policy) unless Issues::AutoPickProjectGate.call(project)

      eligible = eligible_issues(project)
      holds = blocking_items(project)
      return result(project, :human_or_dependency_hold, counts, holds, :open_inbox) if holds.any?
      return result(project, :runnable_unseeded, counts, eligible.map { |issue| Item.new(issue, :runnable, []) }, :wait_for_eligibility_sweep) if eligible.any? && counts[:queued].zero?
      return result(project, :healthy_active_work, counts, [], :none) if counts[:active].positive? && eligible.empty?

      result(project, :healthy_no_waiting_backlog, counts, [], :none)
    end

    def queue_counts(project)
      {
        queued: AgentRun.queued.where(project: project).count,
        active: AgentRun.capacity_inflight.where(project: project).count
      }
    end

    def eligible_issues(project)
      Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project).limit(20).to_a
    end

    def blocking_items(project)
      needs_input = project.issues.where(github_state: "open", is_pull_request: false, paid_state: "needs_input")
        .where.not(needs_input_questions: [ nil, [] ]).limit(20).to_a
      needs_input.map { |issue| Item.new(issue, :needs_input, []) }
    end

    def paused?(project)
      project.scheduler_paused_at.present? || project.quality_paused_at.present? || project.account.scheduler_paused_at.present?
    end

    def result(project, state, counts, items, next_action)
      Result.new(
        project:, state:, eligible_count: items.count { |item| item.kind == :runnable },
        queued_count: counts[:queued], active_count: counts[:active], items:, next_action:, assessed_at: Time.current
      )
    end
  end
end
