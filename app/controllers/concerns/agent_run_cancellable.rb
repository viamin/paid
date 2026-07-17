# frozen_string_literal: true

# Shared cancellation logic for controllers that cancel agent runs.
# Sets the cancelled status immediately and enqueues a background job
# for the slow cleanup (Temporal workflow cancellation + container teardown),
# so the web UI responds without blocking.
module AgentRunCancellable
  extend ActiveSupport::Concern

  private

  def record_run_audit_event(action, agent_run)
    Audit::RecordEvent.call(
      action: action,
      actor: current_user,
      subject: agent_run,
      metadata: {
        agent_run_id: agent_run.id,
        project_name: agent_run.project&.name
      }
    )
  rescue StandardError => e
    Rails.logger.error(
      message: "audit.record_failed",
      action: action,
      error_class: e.class.name,
      error_message: e.message
    )
  end

  def cancel_agent_run(agent_run, redirect_path:)
    result = cancel_agent_run_result(agent_run)
    redirect_to redirect_path, status: :see_other, notice: result.message
  end

  def cancel_agent_run_result(agent_run)
    return CancellationResult.new(:inactive, "Agent run is no longer active.") unless agent_run.cancellable?

    cancelled = false

    agent_run.with_lock do
      if agent_run.cancellable?
        agent_run.cancel!
        cancelled = true
      end
    end

    if cancelled
      AgentRunCancellationJob.perform_later(agent_run.id)
      record_run_audit_event("agent_run.cancelled", agent_run)
      CancellationResult.new(:cancelled, "Agent run cancelled.")
    else
      CancellationResult.new(:finished, "Agent run finished before it could be cancelled.")
    end
  end

  CancellationResult = Struct.new(:status, :message, keyword_init: false) do
    def cancelled?
      status == :cancelled
    end
  end
end
