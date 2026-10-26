# frozen_string_literal: true

module Dashboard
  # Explains an empty scheduler preview without treating it as evidence that a
  # project has no work. The eligibility breakdown remains the sole authority
  # for candidate eligibility; this class only relates that result to the
  # scheduler's queued and active run scopes.
  class QueueDiagnosis
    Result = Struct.new(
      :state, :action, :eligible_count, :queued_count, :active_count, :held_count, :observed_at,
      keyword_init: true
    )

    def self.call(...) = new(...).call

    def initialize(user:, breakdowns: nil, paused_projects: [])
      @user = user
      @breakdowns = breakdowns
      @paused_projects = paused_projects
    end

    # @spec AUTO-PICK-QUEUE-014
    def call
      breakdowns = @breakdowns || EligibilityBreakdown.call(user: user)
      build_result(breakdowns)
    rescue ActiveRecord::ActiveRecordError => error
      unknown_result(error)
    end

    private

    attr_reader :user

    def build_result(breakdowns)
      counts = Counts.new(breakdowns, paused_projects: @paused_projects)
      queued = queued_count(counts.project_ids)
      active = active_count(counts.project_ids)
      Result.new(
        state: state_for(counts, queued:, active:),
        action: action_for(counts, queued:),
        eligible_count: counts.eligible,
        queued_count: queued,
        active_count: active,
        held_count: counts.held,
        observed_at: Time.current
      )
    end

    def state_for(counts, queued:, active:)
      return :runnable_unseeded if counts.eligible.positive? && queued.zero?
      return :healthy_active_work if active.positive? && counts.eligible.zero? && queued.zero?
      return :paused if counts.paused.positive?
      return :held if counts.held.positive?

      :empty
    end

    def action_for(counts, queued:)
      return :wait_for_auto_pick_sweep if counts.eligible.positive? && queued.zero?
      return :review_eligibility if counts.paused.positive?
      return :review_eligibility if counts.held.positive?

      :none
    end

    def queued_count(project_ids)
      return 0 if project_ids.empty?

      AgentRun.schedulable_queued_with_priority.where(project_id: project_ids).count
    end

    def active_count(project_ids)
      return 0 if project_ids.empty?

      AgentRun.capacity_inflight.where(project_id: project_ids).count
    end

    def unknown_result(error)
      Rails.logger.warn(
        message: "dashboard.queue_diagnosis_unavailable",
        account_id: user.account_id,
        error_class: error.class.name,
        error: error.message
      )
      Result.new(state: :unknown, action: :refresh, observed_at: Time.current)
    end

    class Counts
      attr_reader :eligible, :held, :paused, :project_ids

      def initialize(breakdowns, paused_projects:)
        @eligible = breakdowns.sum(&:eligible)
        @held = breakdowns.sum { |breakdown| held_count_for(breakdown) }
        @paused = paused_projects.count(&:auto_pick_enabled?)
        @project_ids = breakdowns.map { |breakdown| breakdown.project.id }
      end

      private

      def held_count_for(breakdown)
        breakdown.needs_input + breakdown.skip_label + breakdown.manual_review + breakdown.other_excluded
      end
    end
  end
end
