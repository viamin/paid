# frozen_string_literal: true

FactoryBot.define do
  factory :explicit_preference do
    account
    user { association :user, account: }
    recorded_by { user }
    scope { "user" }
    statement { "I prefer concise technical explanations." }
  end
end
