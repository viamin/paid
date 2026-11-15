# frozen_string_literal: true

module AgentRuns
  # Shared scheduling and atomic-claim mechanics for retry policies. Policies
  # retain their own eligibility rules and successor shape.
  # @spec MANUAL-RUN-RETRY-001 MANUAL-RUN-RETRY-005 MANUAL-RUN-RETRY-008 MANUAL-RUN-RETRY-009
  class RetryAttempt
    DEFAULT_DECISION_ACTION = "manual_failed_run_auto_retry"

    # A policy's build_successor! raises this when ordinary use-case admission
    # refused between the locked re-assessment and successor construction; the
    # claim records it as a durable no-op instead of an unhandled error.
    class AdmissionRefused < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("retry admission refused: #{reason}")
      end
    end

    Result = Data.define(:outcome, :reason, :agent_run, :successor) do
      def claimed? = outcome == :claimed
      def scheduled? = outcome == :scheduled
    end

    def initialize(policy:, decision_point:, action: DEFAULT_DECISION_ACTION)
      @policy = policy
      @decision_point = decision_point
      @action = action
    end

    def schedule(agent_run:, job_class:, delay:)
      assessment = policy.assess(agent_run)
      return record_skip(agent_run, assessment) unless assessment.eligible?

      job_class.set(wait: delay.call(assessment.attempt)).perform_later(agent_run.id, assessment.attempt)
      Result.new(:scheduled, :scheduled, agent_run, nil)
    end

    def claim(agent_run_id:, attempt:)
      result = AgentRun.transaction do
        agent_run = AgentRun.lock.find_by(id: agent_run_id)
        next Result.new(:skipped, :missing_run, nil, nil) unless agent_run

        assessment = policy.assess(agent_run, attempt: attempt)
        next record_skip(agent_run, assessment) unless assessment.eligible?

        successor = policy.build_successor!(agent_run, attempt)
        agent_run.retry!(
          decision_point: decision_point,
          signals: retry_signals(attempt),
          result: { new_agent_run_id: successor.id, reason: "retry_claimed" }
        )
        Result.new(:claimed, :retry_claimed, agent_run, successor)
      end
      result
    rescue AgentRuns::RetryAttempt::AdmissionRefused => error
      agent_run = AgentRun.find_by(id: agent_run_id)
      return Result.new(:skipped, :missing_run, nil, nil) unless agent_run

      record_reason(agent_run, error.reason, attempt)
    rescue ActiveRecord::RecordNotUnique => error
      raise unless policy.duplicate_active_run_conflict?(error)

      agent_run = AgentRun.find_by(id: agent_run_id)
      return Result.new(:skipped, :missing_run, nil, nil) unless agent_run

      record_reason(agent_run, duplicate_conflict_reason, attempt)
    end

    private

    attr_reader :action, :decision_point, :policy

    def duplicate_conflict_reason
      return policy.duplicate_conflict_reason if policy.respond_to?(:duplicate_conflict_reason)

      :active_lid_planning_run
    end

    def record_skip(agent_run, assessment)
      record_reason(agent_run, assessment.reason, assessment.attempt)
    end

    def record_reason(agent_run, reason, attempt)
      OrchestrationDecision.record(
        project: agent_run.project,
        agent_run: agent_run,
        decision_point: decision_point,
        action: action,
        status: "noop",
        signals: retry_signals(attempt).merge(reason: reason.to_s),
        result: { reason: reason.to_s }
      )
      Result.new(:skipped, reason, agent_run, nil)
    end

    def retry_signals(attempt)
      { attempt: attempt, max_attempts: policy.maximum_attempts }
    end
  end
end
