# frozen_string_literal: true

# Recovers one source-closure assessment that could not complete after the
# agent's work was pushed.
#
# The job never re-runs coding and never mints a replacement AgentRun: it
# re-assesses the exact pushed revision and, only after a successful current
# assessment, continues with pull-request publication and the closeout steps.
# @spec PARTIAL-CLOSEOUT-043 @spec PARTIAL-CLOSEOUT-045
class RecoverSourceClosureAssessmentJob < ApplicationJob
  queue_as :maintenance

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run

    result = PartialCloseouts::SourceClosureRecovery.call(agent_run: agent_run)
    Rails.logger.info(
      message: "partial_closeout.recovery_completed",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      status: result.status
    )
  end
end
