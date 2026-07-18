# frozen_string_literal: true

module PreviewSessions
  # Reaps expired preview sessions across all tenants (RDR-045).
  #
  # Scheduled to run every 5 minutes via GoodJob cron; complements the
  # opportunistic cleanup that runs from {Previews::Provision#start}.
  class ExpireJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: "preview_sessions_expire"
    )

    def perform
      reaped = 0

      TenantContext.with_system_access do
        PreviewSession.expiring_before(Time.current).find_each do |session|
          reaped += 1 if reap_session(session)
        end
      end

      Rails.logger.info(
        message: "preview_session.expire_complete",
        reaped_count: reaped
      ) if reaped > 0
    end

    private

    def reap_session(session)
      TenantContext.with(session.account) do
        Previews::Provision.new(project: session.project).stop(session: session)
      end
      true
    rescue => e
      Rails.logger.error(
        message: "preview_session.expire_failed",
        preview_session_id: session.id,
        error: e.message
      )
      false
    end
  end
end
