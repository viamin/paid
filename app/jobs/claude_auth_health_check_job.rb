# frozen_string_literal: true

class ClaudeAuthHealthCheckJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "claude_auth_health_check"
  )

  def perform
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    accounts_checked = 0
    runners_checked = 0
    invalid = 0
    expiring = 0
    errors = 0
    host_forwarded_status_by_runner_key = {}

    Account.find_each do |account|
      health = Runners::AuthHealth.call(
        account: account,
        host_forwarded_status_by_runner_key: host_forwarded_status_by_runner_key
      )
      next if health.empty?

      accounts_checked += 1
      runners_checked += health.size
      invalid += health.count(&:invalid?)
      expiring += health.count(&:expiring_soon?)
    rescue => e
      errors += 1
      Rails.logger.error(
        message: "claude_auth.health_check.account_failed",
        account_id: account.id,
        error: e.message
      )
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    Rails.logger.info(
      message: "claude_auth.health_check.completed",
      accounts_checked: accounts_checked,
      runners_checked: runners_checked,
      invalid_runners: invalid,
      expiring_runners: expiring,
      accounts_errored: errors,
      duration_ms: duration_ms
    )
  end
end
