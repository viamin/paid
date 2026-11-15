# frozen_string_literal: true

module AgentRuns
  # Shared scheduling and atomic-claim mechanics for retry policies. Policies
  # retain their own eligibility rules and successor shape.
  # @spec MANUAL-RUN-RETRY-001 MANUAL-RUN-RETRY-005 MANUAL-RUN-RETRY-008 MANUAL-RUN-RETRY-009
  # @spec AGENT-RETRY-014 AGENT-RETRY-017
  class RetryAttempt
    Result = Data.define(:outcome, :reason, :agent_run, :successor) do
      def claimed? = outcome == :claimed
      def scheduled? = outcome == :scheduled
      def dispatch? = outcome.in?([ :claimed, :existing_active_run ])
    end

    def initialize(policy:, decision_point:)
      @policy = policy
      @decision_point = decision_point
    end

    def schedule(agent_run:, job_class:, delay:)
      assessment = policy.assess(agent_run)
      return record_skip(agent_run, assessment) unless assessment.eligible?

      job_class.set(wait: delay.call(assessment.attempt)).perform_later(agent_run.id, assessment.attempt)
      Result.new(:scheduled, :scheduled, agent_run, nil)
    end

    def claim(agent_run_id:, attempt: nil)
      result = AgentRun.transaction do
        agent_run = AgentRun.lock.find_by(id: agent_run_id)
        next Result.new(:skipped, :missing_run, nil, nil) unless agent_run

        assessment = policy.assess(agent_run, attempt: attempt || policy.next_attempt(agent_run))
        next record_skip(agent_run, assessment) unless assessment.eligible?

        successor = policy.build_successor!(agent_run, assessment.attempt)
        next record_reason(agent_run, :not_admitted, assessment.attempt) unless successor
        agent_run.retry!(
          decision_point: decision_point,
          signals: retry_signals(assessment.attempt),
          result: retry_result(successor, assessment.attempt)
        )
        Result.new(:claimed, :retry_claimed, agent_run, successor)
      end
      result
    rescue ActiveRecord::RecordNotUnique => error
      raise unless policy.duplicate_active_run_conflict?(error)

      agent_run = AgentRun.find_by(id: agent_run_id)
      return Result.new(:skipped, :missing_run, nil, nil) unless agent_run

      return policy.handle_duplicate_active_run!(agent_run, attempt || policy.next_attempt(agent_run), error: error) if policy.respond_to?(:handle_duplicate_active_run!)

      record_reason(agent_run, :active_lid_planning_run, attempt || policy.next_attempt(agent_run))
    end

    private

    attr_reader :policy, :decision_point

    def record_skip(agent_run, assessment)
      if policy.respond_to?(:handle_ineligible!)
        handled = policy.handle_ineligible!(agent_run, assessment, decision_point: decision_point)
        return handled if handled
      end

      record_reason(agent_run, assessment.reason, assessment.attempt)
    end

    def record_reason(agent_run, reason, attempt)
      OrchestrationDecision.record(
        project: agent_run.project,
        agent_run: agent_run,
        decision_point: decision_point,
        action: retry_action,
        status: "noop",
        signals: retry_signals(attempt).merge(reason: reason.to_s),
        result: { reason: reason.to_s }
      )
      Result.new(:skipped, reason, agent_run, nil)
    end

    def retry_signals(attempt)
      return policy.retry_signals(attempt) if policy.respond_to?(:retry_signals)

      { attempt: attempt, max_attempts: policy.maximum_attempts }
    end

    def retry_result(successor, attempt)
      return policy.retry_result(successor, attempt) if policy.respond_to?(:retry_result)

      { new_agent_run_id: successor.id, reason: "retry_claimed" }
    end

    def retry_action
      return policy.retry_action if policy.respond_to?(:retry_action)

      "manual_failed_run_auto_retry"
    end
  end
end
