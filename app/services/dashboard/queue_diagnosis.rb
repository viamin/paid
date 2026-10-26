# frozen_string_literal: true

module Dashboard
  # A read-only explanation for an empty queue preview. Recovery remains with
  # the existing async enqueue and hold-reassessment paths; rendering must not
  # inspect repositories or change delivery state.
  class QueueDiagnosis
    Result = Data.define(
      :state, :eligible_count, :queued_count, :active_count, :held_count,
      :paused_count, :rendered_count, :assessed_at, :next_action
    )

    def self.call(...)
      new(...).call
    end

    def initialize(user:, rendered_runs:)
      @user = user
      @rendered_runs = rendered_runs
    end

    # @spec EAGER-QUEUE-DIAG-001 EAGER-QUEUE-DIAG-002
    def call
      facts = Facts.new(user: user, rendered_runs: rendered_runs).call
      State.new(facts).result
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid => error
      Rails.logger.warn(message: "dashboard.queue_diagnosis_unavailable", account_id: user.account_id, error_class: error.class.name)
      unknown_result
    end

    private

    attr_reader :rendered_runs, :user

    def unknown_result
      Result.new(
        state: :unknown, eligible_count: nil, queued_count: nil,
        active_count: nil, held_count: nil, paused_count: nil,
        rendered_count: rendered_runs.size, assessed_at: nil, next_action: :refresh
      )
    end

    class Facts
      def initialize(user:, rendered_runs:)
        @user = user
        @rendered_runs = rendered_runs
      end

      def call
        project_ids = visible_project_ids
        breakdowns = EligibilityBreakdown.call(user: user)
        {
          eligible_count: breakdowns.sum(&:eligible),
          held_count: breakdowns.sum { |breakdown| held_count_for(breakdown) },
          queued_count: queued_count(project_ids),
          active_count: active_count(project_ids),
          paused_count: paused_count,
          rendered_count: rendered_runs.size,
          assessed_at: Time.current
        }
      end

      private

      attr_reader :rendered_runs, :user

      def visible_project_ids
        scope = Project.where(account_id: user.account_id, created_by_id: user.id)
        scope = scope.or(Project.where(account_id: user.account_id, created_by_id: nil)) if AgentRun.orphaned_project_owner?(user)
        scope.ids
      end

      def queued_count(project_ids)
        AgentRun.schedulable_queued_with_priority.where(project_id: project_ids).reselect(:id).count
      end

      def active_count(project_ids)
        AgentRun.capacity_inflight.where(project_id: project_ids).reselect(:id).count
      end

      def paused_count
        Project.where(account_id: user.account_id, created_by_id: visible_owner_ids, auto_pick_enabled: true)
          .where("scheduler_paused_at IS NOT NULL OR quality_paused_at IS NOT NULL OR paused = TRUE")
          .count
      end

      def visible_owner_ids
        [ user.id, *(AgentRun.orphaned_project_owner?(user) ? [ nil ] : []) ]
      end

      def held_count_for(breakdown)
        breakdown.needs_input + breakdown.manual_review + breakdown.skip_label + breakdown.other_excluded
      end
    end

    class State
      def initialize(facts)
        @facts = facts
      end

      def result
        Result.new(**facts, state: state, next_action: next_action)
      end

      private

      attr_reader :facts

      def state
        return :refresh_mismatch if facts[:rendered_count].zero? && facts[:queued_count].positive?
        return :runnable_unseeded if facts[:eligible_count].positive? && facts[:queued_count].zero?
        return :active_work if facts[:active_count].positive? && facts[:queued_count].zero?
        return :held if facts[:held_count].positive? && facts[:queued_count].zero?
        return :paused if facts[:paused_count].positive?

        :empty
      end

      def next_action
        return :refresh if state.in?([ :refresh_mismatch, :runnable_unseeded ])
        return :inbox if state == :held
        return :project_settings if state == :paused

        :none
      end
    end
  end
end
