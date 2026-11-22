# frozen_string_literal: true

module AgentRuns
  # Records scheduling intent without changing a coding retry's authority.
  # @spec QUEUE-TIER-008
  class PrioritizeCodingRetry
    def self.call(...) = new(...).call

    def initialize(agent_run:, actor:)
      @agent_run = agent_run
      @actor = actor
    end

    def call
      agent_run.with_lock do
        authorize!
        return false unless eligible?

        agent_run.update!(operator_coding_priority_requested_at: Time.current)
        Audit::RecordEvent.call(action: "agent_run.coding_priority_requested", actor:, subject: agent_run,
          metadata: { continuation_request_id: agent_run.continuation_request_id,
            issue_id: agent_run.issue_id, original_trigger_type: agent_run.trigger_type })
        ProcessRunQueueJob.perform_later
      end
      true
    end

    private

    attr_reader :agent_run, :actor

    def authorize!
      return if actor && actor.account_id == agent_run.project.account_id &&
        ProjectPolicy.new(actor, agent_run.project).run_agent?

      raise Pundit::NotAuthorizedError, "Not authorized to prioritize a coding retry"
    end

    def eligible?
      return false unless agent_run.status == "queued" && agent_run.temporal_workflow_id.blank?
      return false unless agent_run.trigger_type == "automatic" && agent_run.goal == "create_pr"
      return false if agent_run.operator_coding_priority_requested_at.present?
      return false if agent_run.rate_limited_until&.future?

      agent_run.source_pull_request_number.present? || implementation_continuation? || automatic_root_retry?
    end

    def implementation_continuation?
      request = agent_run.continuation_request
      request&.open? && request.project_id == agent_run.project_id && request.issue_id == agent_run.issue_id &&
        request.evidence["continuation_mode"] == "implementation"
    end

    def automatic_root_retry?
      return false unless agent_run.auto_pick? && agent_run.issue

      failures = agent_run.issue.consecutive_auto_pick_failure_count
      cap = agent_run.project.effective_max_issue_runner_failures
      failures.positive? && (!cap&.positive? || failures < cap)
    end
  end
end
