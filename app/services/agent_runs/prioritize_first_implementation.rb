# frozen_string_literal: true

module AgentRuns
  # Records an operator's scheduling intent for a still-authorized first attempt.
  # @spec QUEUE-TIER-010
  class PrioritizeFirstImplementation
    def self.call(...) = new(...).call

    def self.eligible?(agent_run:) = new(agent_run:, actor: nil).eligible?

    def initialize(agent_run:, actor:)
      @agent_run = agent_run
      @actor = actor
    end

    def call
      agent_run.with_lock do
        authorize!
        return false unless eligible?

        agent_run.update!(operator_coding_priority_requested_at: Time.current,
          operator_first_implementation_priority_requested_at: Time.current)
        Audit::RecordEvent.call(action: "agent_run.first_implementation_priority_requested", actor:, subject: agent_run,
          metadata: { issue_id: agent_run.issue_id, original_trigger_type: agent_run.trigger_type,
            execution_origin: agent_run.execution_origin })
        ProcessRunQueueJob.perform_later
      end
      true
    end

    def eligible?
      return false unless unclaimed_automatic_first_attempt?
      return false if agent_run.operator_coding_priority_requested_at.present?
      return false if agent_run.rate_limited_until&.future?
      return false if agent_run.project.quality_paused?
      return false unless source_still_eligible?

      no_preceding_implementation?
    end

    private

    attr_reader :agent_run, :actor

    def authorize!
      return if actor && actor.account_id == agent_run.project.account_id &&
        ProjectPolicy.new(actor, agent_run.project).run_agent?

      raise Pundit::NotAuthorizedError, "Not authorized to prioritize a first implementation"
    end

    def unclaimed_automatic_first_attempt?
      agent_run.status == "queued" && unclaimed_execution? &&
        agent_run.auto_pick? && agent_run.trigger_type == "automatic" &&
        agent_run.goal == "create_pr" && agent_run.execution_origin == "paid_native" &&
        agent_run.issue_id.present? && agent_run.source_pull_request_number.blank? &&
        agent_run.continuation_request_id.blank?
    end

    def unclaimed_execution?
      agent_run.temporal_workflow_id.blank? && agent_run.started_at.blank? &&
        agent_run.container_id.blank? && agent_run.runner_handle.blank? &&
        agent_run.worktree_path.blank? && agent_run.service_container_ids.blank? &&
        agent_run.worktree.nil?
    end

    def source_still_eligible?
      Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_for_dequeue?(
        agent_run.project, agent_run.issue_id, excluding_run_id: agent_run.id
      )
    end

    def no_preceding_implementation?
      !agent_run.issue.agent_runs.where(goal: "create_pr")
        .where("created_at < :created_at OR (created_at = :created_at AND id < :id)",
          created_at: agent_run.created_at, id: agent_run.id).exists?
    end
  end
end
