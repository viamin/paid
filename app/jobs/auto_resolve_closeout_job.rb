# frozen_string_literal: true

# Closes an accepted source issue only after its report-only audit run is
# terminal. A missing or changed authority simply keeps the Inbox item open.
# @spec PROJECT-DELEGATION-009
class AutoResolveCloseoutJob < ApplicationJob
  queue_as :maintenance

  def perform(agent_run_id)
    run = AgentRun.find_by(id: agent_run_id)
    return unless run

    outcome = Issues::AutoResolveCloseout.call(agent_run: run)
    Rails.logger.info(message: "partial_closeouts.auto_resolve_finished",
      component: "agent_execution", project_id: run.project_id, issue_id: run.issue_id,
      agent_run_id: run.id, outcome: outcome)
  end
end
