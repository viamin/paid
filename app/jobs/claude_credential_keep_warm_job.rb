# frozen_string_literal: true

# Periodic keep-warm job for host-forwarded Claude subscription credentials
# (RDR-041 Phase 3).
#
# Detects when the host `.credentials.json` is near expiry and attempts a
# refresh-token exchange via `AgentHarness::Authentication.exchange_refresh_token`
# (viamin/agent-harness#265). The rotated credential is written back to the
# source directory under a serializing file lock — the same
# `with_claude_auth_lock` pattern used at provision-preflight time.
#
# When the upstream exchange API is not yet available, the job logs and exits
# cleanly so future runs keep trying once the gem ships.
#
# This job runs independently of any provision flow and is designed to keep
# credentials warm between runs, so containers provisioned shortly after the
# job fires get a fresh token rather than an about-to-expire one.
class ClaudeCredentialKeepWarmJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "claude_credential_keep_warm"
  )

  def perform
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    unless AgentHarness::Authentication.respond_to?(:exchange_refresh_token)
      Rails.logger.info(
        message: "claude_credential.keep_warm.exchange_unsupported",
        note: "viamin/agent-harness#265 not yet available; keep-warm exchange skipped"
      )
      return
    end

    provision = Containers::Provision.new
    unless provision.send(:claude_subscription_auth?)
      Rails.logger.info(message: "claude_credential.keep_warm.no_subscription_auth")
      return
    end

    unless provision.send(:claude_credentials_near_expiry?)
      Rails.logger.info(
        message: "claude_credential.keep_warm.not_near_expiry",
        expiry: provision.send(:claude_native_credential_expiry)
      )
      return
    end

    refreshed = provision.send(:refresh_claude_credentials_if_near_expiry!)

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    Rails.logger.info(
      message: "claude_credential.keep_warm.completed",
      refreshed: refreshed,
      duration_ms: duration_ms
    )
  end
end
