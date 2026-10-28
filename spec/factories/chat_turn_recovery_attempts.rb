# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn_recovery_attempt do
    chat_turn
    actor { association :user, account: chat_turn.chat_session.account }
    requested_revision { chat_turn.revision }
    status { "queued" }
  end
end
