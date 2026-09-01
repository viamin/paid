# frozen_string_literal: true

# Synthesizes and indexes a session-summary knowledge artifact for a
# completed agent run. Enqueued from the temporal completion activities so
# the (LLM-latency) synthesis never blocks agent-run completion itself.
#
# @spec SESSION-SUMMARY-001
class CaptureAgentRunSessionSummaryJob < ApplicationJob
  queue_as :knowledge

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run

    Knowledge::SessionSummaries::Capture.call(agent_run: agent_run)
  rescue => e
    Rails.logger.warn(
      message: "knowledge.session_summary_capture_failed",
      agent_run_id: agent_run_id,
      error_class: e.class.name,
      error: e.message
    )
  end
end
