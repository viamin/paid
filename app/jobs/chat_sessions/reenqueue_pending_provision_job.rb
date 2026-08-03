# frozen_string_literal: true

module ChatSessions
  # Retries account-scoped background provisioning enqueue when the primary
  # provisioning job's concurrency gate rejects a new session at create time.
  #
  # @spec CHAT-CONTAINER-PROVISIONING-001
  # @spec CHAT-CONTAINER-PROVISIONING-006
  class ReenqueuePendingProvisionJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :low_priority

    retry_on GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError,
      wait: 2.seconds,
      attempts: 10

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: -> { self.class.concurrency_key_for(arguments.first[:account_id]) }
    )

    def self.concurrency_key_for(account_id)
      "chat_sessions_reenqueue_pending_account_#{account_id}"
    end

    def perform(account_id:, exclude_chat_session_id: nil)
      chat_session = next_pending_session(account_id:, exclude_chat_session_id:)
      return unless chat_session

      ChatSessions::ProvisionContainerJob.perform_later(
        chat_session_id: chat_session.id,
        account_id: account_id
      )
    end

    private

    def tenant_account
      TenantContext.with_system_access { Account.find_by(id: arguments.first[:account_id]) }
    end

    def next_pending_session(account_id:, exclude_chat_session_id:)
      scope = ChatSession.where(account_id:, container_capability: "pending")
      scope = scope.where.not(id: exclude_chat_session_id) if exclude_chat_session_id.present?

      scope.order(:container_requested_at, :created_at).first
    end
  end
end
