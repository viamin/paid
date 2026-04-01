# frozen_string_literal: true

# Shared cancellation logic for controllers that cancel agent runs.
# Handles external cleanup, row-level pessimistic locking to prevent race conditions,
# and redirect with appropriate flash messaging.
#
# Used by Projects::AgentRunsController and DashboardController.
module AgentRunCancellable
  extend ActiveSupport::Concern

  private

  def cancel_agent_run(agent_run, redirect_path:)
    unless agent_run.active?
      redirect_to redirect_path, status: :see_other, notice: "Agent run is no longer active."
      return
    end

    begin
      AgentRuns::Cancel.call(agent_run: agent_run, skip_status_update: true)
    rescue StandardError => e
      Rails.logger.error(
        message: "agent_execution.cancel_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error_message: e.message
      )
      redirect_to redirect_path, status: :see_other, alert: "Unable to cancel agent run. Please try again."
      return
    end

    cancelled = false

    # with_lock calls reload(lock: true), so agent_run is freshly
    # loaded inside the block — safe against races where the run
    # finishes between the external cancellation and this status update.
    agent_run.with_lock do
      if agent_run.active?
        agent_run.cancel!
        cancelled = true
      end
    end

    if cancelled
      redirect_to redirect_path, status: :see_other, notice: "Agent run cancelled."
    else
      redirect_to redirect_path, status: :see_other, notice: "Agent run finished before it could be cancelled."
    end
  end
end
