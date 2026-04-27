# frozen_string_literal: true

module ChatSessions
  # Closes idle chat sessions that have exceeded their timeout.
  # Scheduled to run every 5 minutes via GoodJob cron.
  class IdleReaperJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: "chat_sessions_idle_reaper"
    )

    def perform
      reaped = 0

      TenantContext.with_system_access do
        ChatSession.idle_expired.find_each do |session|
          reap_session(session)
          reaped += 1
        end
      end

      Rails.logger.info(
        message: "chat_session.idle_reaper_complete",
        reaped_count: reaped
      ) if reaped > 0
    end

    private

    def reap_session(session)
      TenantContext.with(session.account) do
        session.update!(status: "idle")
        ChatSessions::Close.call(chat_session: session.reload)
      end
    rescue => e
      Rails.logger.error(
        message: "chat_session.idle_reaper_failed",
        chat_session_id: session.id,
        error: e.message
      )
    end
  end
end
