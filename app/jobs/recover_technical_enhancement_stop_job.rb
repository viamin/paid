# frozen_string_literal: true

# Delayed, idempotent claim for one technically stopped enhancement run.
# @spec ISSUE-ENHANCEMENT-021
class RecoverTechnicalEnhancementStopJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    enqueue_limit: 1,
    key: -> { "recover_technical_enhancement_stop_#{arguments.first}" }
  )

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run

    IssueEnhancements::TechnicalStopRecovery.call(agent_run:)
  end
end
