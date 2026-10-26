# frozen_string_literal: true

# Bounded sweep for delivery handoffs that stopped progressing (#4619).
#
# The sweep runs on a cron for every active account and on the relevant
# lifecycle events (an agent run reaching a terminal status), so a missed
# event is repaired by the next periodic pass. Concurrency is limited to one
# performing sweep so overlapping invocations cannot stack.
#
# `QueueStalls::Sweep` owns the detection, the deduplication and the
# delegation to the existing recovery services; this job only schedules the
# sweep and records its result.
# @spec QUEUE-DIAG-004 @spec QUEUE-DIAG-006
class QueueStallsSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "queue_stalls_sweep"
  )

  # Bounds the fleet-wide pass so one invocation cannot sweep an unbounded
  # number of accounts.
  MAX_ACCOUNTS = 50

  def perform(account_id: nil, project_id: nil)
    TenantContext.with_system_access do
      accounts_for(account_id).each do |account|
        sweep(account, project_id)
      end
    end
  end

  private

  def accounts_for(account_id)
    if account_id
      [ Account.active.find_by(id: account_id) ].compact
    else
      Account.active.order(:id).limit(MAX_ACCOUNTS).to_a
    end
  end

  def sweep(account, project_id)
      project = project_id ? Project.find_by(id: project_id, account_id: account.id) : nil
      return if project_id && project.nil?

    result = QueueStalls::Sweep.call(account: account, project: project)

    Rails.logger.info(
      message: "queue_stalls.sweep_completed",
      account_id: account.id,
      project_id: project_id,
      **result.to_h
    )
  end
end
