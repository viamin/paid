# frozen_string_literal: true

# Shared cancellation logic for controllers that cancel agent runs.
# Sets the cancelled status immediately and enqueues a background job
# for the slow cleanup (Temporal workflow cancellation + container teardown),
# so the web UI responds without blocking.
#
# Used by Projects::AgentRunsController and DashboardController.
module AgentRunCancellable
  extend ActiveSupport::Concern

  private

  def cancel_agent_run(agent_run, redirect_path:)
    unless agent_run.cancellable?
      redirect_to redirect_path, status: :see_other, notice: "Agent run is no longer active."
      return
    end

    cancelled = false

    agent_run.with_lock do
      if agent_run.cancellable?
        agent_run.cancel!
        cancelled = true
      end
    end

    if cancelled
      AgentRunCancellationJob.perform_later(agent_run.id)
      redirect_to redirect_path, status: :see_other, notice: "Agent run cancelled."
    else
      redirect_to redirect_path, status: :see_other, notice: "Agent run finished before it could be cancelled."
    end
  end
end
