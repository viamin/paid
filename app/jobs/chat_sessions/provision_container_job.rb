# frozen_string_literal: true

module ChatSessions
  # Provisions a chat session's workspace container in the background so the
  # first inline message is never blocked on container readiness (RDR-037).
  #
  # Enqueued by ChatSessions::Create when the session requests a container
  # (container_capability: "pending") and eager provisioning is enabled. The
  # job runs asynchronously on a GoodJob worker thread; Create returns the
  # session immediately so the user can begin chatting inline while the
  # container warms up. When provisioning succeeds the session transitions to
  # "ready" and the capability change is broadcast to the chat stream so the UI
  # and the agent's tool surface update without losing conversation history.
  class ProvisionContainerJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :default

    # Container provisioning can take 30-60s (image layer pulls, clone). Bound
    # it so a stuck provision fails loudly instead of pinning a worker thread.
    self.perform_timeout = 5.minutes

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: -> { "chat_sessions_provision_#{arguments.first[:chat_session_id]}" }
    )

    discard_on ActiveRecord::RecordNotFound

    def perform(chat_session_id:)
      chat_session = ChatSession.find(chat_session_id)
      return unless chat_session.container_pending? || chat_session.container_provisioning?

      Containers::ProvisionForChat.call(chat_session: chat_session)
      broadcast_capability(chat_session.reload)
    rescue Containers::ProvisionForChat::ProvisionError, Docker::Error::DockerError => e
      # ProvisionForChat already transitions capability to "failed" and cleans
      # up the volumes it created; surface the failure to the chat stream and
      # the structured log so the agent loop can fall back to inline-only tools.
      chat_session.reload
      log("failed", chat_session_id:, error: e.message)
      broadcast_capability(chat_session)
    end

    private

    def tenant_account
      TenantContext.with_system_access do
        ChatSession.find_by(id: arguments.first[:chat_session_id])&.account
      end
    end

    def broadcast_capability(chat_session)
      ActionCable.server.broadcast("chat_session:#{chat_session.id}", {
        type: "capability_changed",
        container_capability: chat_session.container_capability,
        container_ready_at: chat_session.container_ready_at
      })
    end

    def log(action, **metadata)
      Rails.logger.error(
        message: "chat_session.provision_container_job.#{action}",
        **metadata
      )
    end
  end
end
