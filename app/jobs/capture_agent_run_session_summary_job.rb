# frozen_string_literal: true

# Synthesizes and indexes a session-summary knowledge artifact for a
# completed agent run. Enqueued from the temporal completion activities so
# the (LLM-latency) synthesis never blocks agent-run completion itself.
#
# @spec SESSION-SUMMARY-001
class CaptureAgentRunSessionSummaryJob < ApplicationJob
  queue_as :knowledge
  self.notification_subsystem = "knowledge"

  # Transient LLM/DB/sync failures should retry instead of silently dropping
  # the summary. retry_on's terminal block fires the notifier; re-raising
  # keeps GoodJob/ActiveJob's normal terminal-failure semantics so the
  # Capture service's RecordNotUnique repair path remains reachable.
  retry_on StandardError, wait: :polynomially_longer, attempts: 5 do |job, error|
    Rails.logger.warn(
      message: "knowledge.session_summary_capture_exhausted",
      agent_run_id: job.arguments.first,
      error_class: error.class.name,
      error: error.message
    )
    job.notify_terminal_failure(error)
    raise error
  end

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run

    Knowledge::SessionSummaries::Capture.call(agent_run: agent_run)
  end
end
