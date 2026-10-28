# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    account { chat_session.account }
    initiated_by { chat_session.created_by }
    status { "pending" }
    stream_id { SecureRandom.uuid }
    last_activity_at { Time.current }

    trait :with_user_message do
      after(:create) do |turn|
        message = create(:chat_message, chat_session: turn.chat_session,
          content: "Please inspect the failure",
          metadata: { "stream_message_id" => turn.stream_id })
        turn.update!(user_message: message)
      end
    end
  end
end
