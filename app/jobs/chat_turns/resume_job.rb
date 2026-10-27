# frozen_string_literal: true

module ChatTurns
  class ResumeJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(chat_turn_id:, actor_id:)
      turn = ChatTurn.includes(:chat_session, :user_message).find(chat_turn_id)
      actor = turn.chat_session.account.users.find(actor_id)
      ChatTurns::Resume.new(turn:, actor:, stream_message_id: SecureRandom.uuid).call
    end

    def tenant_account
      TenantContext.with_system_access { ChatTurn.find_by(id: arguments.first&.dig(:chat_turn_id))&.chat_session&.account }
    end
  end
end
