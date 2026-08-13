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
  #
  # @spec CHAT-CONTAINER-PROVISIONING-002
  # @spec CHAT-CONTAINER-PROVISIONING-003
  # @spec CHAT-CONTAINER-PROVISIONING-004
  # @spec CHAT-CONTAINER-PROVISIONING-006
  class ProvisionContainerJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :low_priority

    # Container provisioning can take 30-60s (image layer pulls, clone). Bound
    # it so a stuck provision fails loudly instead of pinning a worker thread.
    self.perform_timeout = 5.minutes

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: -> { self.class.concurrency_key_for(arguments.first[:account_id]) }
    )

    discard_on ActiveRecord::RecordNotFound

    def self.concurrency_key_for(account_id)
      "chat_sessions_provision_account_#{account_id}"
    end

    def perform(chat_session_id:, account_id: nil)
      chat_session = ChatSession.find(chat_session_id)
      return unless chat_session.container_pending? || chat_session.container_provisioning?

      ChatSessions::ProvisionWorkspace.call(chat_session: chat_session.reload)
    rescue ChatSessions::ProvisionWorkspace::RestoreFailed
      # Recovered to the stopped state and surfaced to the user by ProvisionWorkspace.
    rescue Containers::ProvisionForChat::ProvisionError, Docker::Error::DockerError => e
      handle_provision_failure(chat_session_id, e)
    rescue ActiveRecord::RecordNotFound
      raise
    rescue StandardError => e
      handle_provision_failure(chat_session_id, e)
      raise
    ensure
      enqueue_next_pending_session(account_id || chat_session&.account_id, exclude_chat_session_id: chat_session_id)
    end

    private

    def tenant_account
      TenantContext.with_system_access do
        ChatSession.find_by(id: arguments.first[:chat_session_id])&.account
      end
    end

    def handle_provision_failure(chat_session_id, error)
      chat_session = ChatSession.find_by(id: chat_session_id)
      return unless chat_session

      log("failed", chat_session_id:, error: error.message)
      ChatSessions::BroadcastCapabilityState.call(chat_session: chat_session.reload)
    end

    def log(action, **metadata)
      Rails.logger.error(
        message: "chat_session.provision_container_job.#{action}",
        **metadata
      )
    end

    def enqueue_next_pending_session(account_id, exclude_chat_session_id:)
      return if account_id.blank?

      ChatSessions::ReenqueuePendingProvisionJob.perform_later(
        account_id: account_id,
        exclude_chat_session_id: exclude_chat_session_id
      )
    rescue GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError
      nil
    end
  end
end
