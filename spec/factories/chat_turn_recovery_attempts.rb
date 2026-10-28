# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn_recovery_attempt do
    chat_turn
    account { chat_turn.account }
    requested_by { chat_turn.initiated_by }
    source_revision { chat_turn.lock_version }
  end
end
