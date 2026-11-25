# frozen_string_literal: true

module PartialCloseouts
  # Queues a recovery request once and records its acceptance without claiming work.
  class RequestSourceClosureRecovery
    Result = Data.define(:status, :event) do
      def queued? = status == :queued
      def queued_without_audit? = status == :queued_without_audit
      def enqueue_failed? = status == :enqueue_failed
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, actor:, boundary:)
      @agent_run = agent_run
      @actor = actor
      @boundary = boundary
    end

    # @spec PARTIAL-CLOSEOUT-064
    def call
      job = SourceClosureRecoveryJob.perform_later(agent_run.id, operator_id: actor.id)
      return Result.new(status: :enqueue_failed, event: nil) unless job && job.successfully_enqueued?

      record_accepted_request(job)
    end

    private

    attr_reader :actor, :agent_run, :boundary

    def record_accepted_request(job)
      Result.new(status: :queued, event: record_event(job))
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.error(message: "source_closure_recovery.audit_record_failed", agent_run_id: agent_run.id,
        actor_id: actor.id, boundary:, error_class: error.class.name, error_message: error.message)
      Result.new(status: :queued_without_audit, event: nil)
    end

    def record_event(job)
      Audit::RecordEvent.call(action: "agent_run.source_closure_recovery_requested", actor:, subject: agent_run,
        metadata: metadata_for(job))
    end

    def metadata_for(job)
      recovery = agent_run.reconciliation.to_h.fetch(SourceClosureRecovery::KEY, {})
      {
        agent_run_id: agent_run.id,
        project_name: agent_run.project.name,
        branch_name: recovery["branch_name"] || agent_run.branch_name,
        result_commit_sha: agent_run.result_commit_sha,
        source_closure_commit_sha: recovery["commit_sha"] || agent_run.result_commit_sha,
        request_phase: "requested",
        request_boundary: boundary,
        queue_job_id: job.job_id
      }
    end
  end
end
