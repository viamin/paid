# frozen_string_literal: true

module AgentRuns
  # Records scheduling intent without replacing an audit's admission authority.
  # @spec QUEUE-TIER-007
  class PrioritizeAudit
    def self.call(...) = new(...).call

    def initialize(agent_run:, actor:)
      @agent_run = agent_run
      @actor = actor
    end

    def call
      agent_run.with_lock do
        authorize!
        return false unless eligible?

        agent_run.update!(operator_priority_requested_at: Time.current)
        Audit::RecordEvent.call(action: "agent_run.audit_priority_requested", actor:, subject: agent_run,
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

      raise Pundit::NotAuthorizedError, "Not authorized to request acceptance audit priority"
    end

    def eligible?
      return false unless agent_run.status == "queued" && UnclaimedExecution.eligible?(agent_run)
      return false unless agent_run.trigger_type == "automatic" && agent_run.goal == "analyze_issue"
      return false if agent_run.operator_priority_requested_at.present?

      request = agent_run.continuation_request
      request&.open? && request.project_id == agent_run.project_id && request.issue_id == agent_run.issue_id &&
        request.evidence["continuation_mode"] == "acceptance_audit"
    end
  end
end
