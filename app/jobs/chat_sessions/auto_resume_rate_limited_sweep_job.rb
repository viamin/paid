# frozen_string_literal: true

module ChatSessions
  # Finds chat sessions whose runner rate-limit pause (CHAT-API-017,
  # ChatSessions::MarkRateLimited) has elapsed and enqueues
  # ChatSessions::ResumeRateLimitedJob for each, so the message that hit the
  # rate limit is resent without the user having to do anything. Scheduled to
  # run every 5 minutes via GoodJob cron.
  #
  # Accounts that opted out via TenantSetting#chat_auto_resume_rate_limited
  # are skipped entirely — their sessions stay parked until the user resends
  # manually.
  class AutoResumeRateLimitedSweepJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: "chat_sessions_auto_resume_rate_limited_sweep"
    )

    def perform
      enqueued = 0

      TenantContext.with_system_access do
        ChatSession.rate_limited_due.find_each do |chat_session|
          next unless chat_session.auto_resume_rate_limited?

          ChatSessions::ResumeRateLimitedJob.perform_later(chat_session_id: chat_session.id)
          enqueued += 1
        end
      end

      Rails.logger.info(message: "chat_session.auto_resume_rate_limited_sweep_complete", enqueued_count: enqueued) if enqueued > 0
    end
  end
end
