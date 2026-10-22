# frozen_string_literal: true

module ChatInvestigations
  # Reserves capacity under the project row lock, which serializes the usage
  # snapshot with all active investigation reservations.
  class Start
    Result = Data.define(:investigation) do
      delegate :awaiting_authorization?, :queued?, to: :investigation
    end

    def self.call(...)
      new(...).call
    end

    def initialize(question:, actor:, kind:, prompt:, estimated_cost_cents: 0)
      @question = question
      @actor = actor
      @kind = kind
      @prompt = prompt
      @estimated_cost_cents = estimated_cost_cents.to_i
    end

    def call
      project.with_lock { Result.new(create_investigation) }.tap do |result|
        ChatInvestigations::Broadcast.call(result.investigation)
        enqueue(result)
      end
    end

    private

    attr_reader :actor, :estimated_cost_cents, :kind, :prompt, :question

    def project
      question.project
    end

    def create_investigation
      ChatInvestigation.create!(investigation_attributes.merge(reservation_attributes))
    end

    def investigation_attributes
      {
        account: question.account,
        project:,
        chat_session: question.chat_session,
        clarifying_question_progress: question,
        created_by: actor,
        kind:,
        prompt:,
        estimated_cost_cents:
      }
    end

    def reservation_attributes
      return { status: "awaiting_authorization", metadata: { "authorization_required" => authorization_reason } } unless reservable?

      { status: "queued", reserved_cost_cents: estimated_cost_cents }
    end

    def reservable?
      execution_allowed? && budget_allowed?
    end

    def execution_allowed?
      !ExecutionControl.enabled.where(scope: "global").exists? &&
        !ExecutionControl.enabled.where(scope: "account", account: project.account).exists? &&
        !ExecutionControl.enabled.where(scope: "project", project:).exists?
    end

    def budget_allowed?
      rollover_expired_periods
      shared_budgets.all? { |budget| available_cents(budget) >= estimated_cost_cents } &&
        per_run_budgets.all? { |budget| budget.effective_limit_cents >= estimated_cost_cents }
    end

    def shared_budgets
      project.cost_budgets.hard_stop.where(budget_type: %w[daily monthly]).lock.to_a
    end

    def per_run_budgets
      project.cost_budgets.hard_stop.per_run.lock.to_a
    end

    def rollover_expired_periods
      shared_budgets.each(&:rollover_if_period_expired!)
    end

    def available_cents(budget)
      budget.effective_limit_cents - budget.current_usage_cents - active_reservations
    end

    def active_reservations
      ChatInvestigation.active.where(project:).sum(:reserved_cost_cents)
    end

    def authorization_reason
      return "Execution is currently disabled by policy." unless execution_allowed?
      return "The investigation exceeds the remaining project budget." unless budget_allowed?

      "Additional authorization is required."
    end

    def enqueue(result)
      ChatInvestigations::RunJob.perform_later(result.investigation.id) if result.queued?
    end
  end
end
