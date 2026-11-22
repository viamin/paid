# frozen_string_literal: true

# Executes bounded artifact-only reassessment; it intentionally does not create
# an AgentRun or enter an agent execution workflow.
# @spec AUTO-MERGE-011
class ReassessConflictRepairScopeJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default
  good_job_control_concurrency_with perform_limit: 1, key: -> { "reassess_conflict_repair_scope_#{arguments.first}" }

  def perform(agent_run_id, requested_by_id: nil)
    run = AgentRun.find_by(id: agent_run_id)
    return unless run

    ConflictRepairs::ReassessScope.call(agent_run: run, requested_by: User.find_by(id: requested_by_id))
  end
end
