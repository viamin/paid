# frozen_string_literal: true

# Periodic health check that validates all active GitHub tokens against the
# GitHub API. Runs daily via GoodJob cron to catch tokens that have been
# revoked or expired externally.
#
# Differs from GithubTokenValidationJob (single-token, user-triggered) in that:
# - It iterates all active tokens, skipping recently validated ones
# - Transient API errors do NOT mark tokens as failed (only auth errors do)
# - Includes structured logging and metrics for batch monitoring
class GithubTokenHealthCheckJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "github_token_health_check"
  )

  RECENTLY_VALIDATED_THRESHOLD = 24.hours

  def perform
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    checked = 0
    failed = 0
    skipped = 0
    errors = 0

    GithubToken.active.find_each do |token|
      if recently_validated?(token)
        skipped += 1
        next
      end

      checked += 1
      check_token(token) ? nil : (failed += 1)
    rescue => e
      errors += 1
      Rails.logger.error(
        message: "github_token.health_check.unexpected_error",
        github_token_id: token.id,
        error: e.message
      )
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    Rails.logger.info(
      message: "github_token.health_check.completed",
      tokens_checked: checked,
      tokens_failed: failed,
      tokens_skipped: skipped,
      tokens_errored: errors,
      duration_ms: duration_ms
    )
  end

  private

  def recently_validated?(token)
    token.validated? && token.updated_at > RECENTLY_VALIDATED_THRESHOLD.ago
  end

  def check_token(token)
    token.mark_validating!

    result = token.validate_with_github!
    token.mark_validated!

    Rails.logger.info(
      message: "github_token.health_check.token_valid",
      github_token_id: token.id,
      login: result[:login]
    )

    true
  rescue GithubClient::AuthenticationError => e
    token.mark_validation_failed!("Token has been revoked or expired: #{e.message}")
    Rails.logger.warn(
      message: "github_token.health_check.token_revoked",
      github_token_id: token.id,
      error: e.message
    )
    false
  rescue GithubClient::RateLimitError, GithubClient::ApiError => e
    # Transient GitHub errors should not mark the token as failed.
    # Restore to pending so it gets retried next cycle.
    token.update!(validation_status: "pending", validation_error: nil)
    Rails.logger.warn(
      message: "github_token.health_check.transient_error",
      github_token_id: token.id,
      error: e.message
    )
    true
  end
end
