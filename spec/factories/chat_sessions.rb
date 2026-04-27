# frozen_string_literal: true

FactoryBot.define do
  factory :chat_session do
    account
    created_by { association :user, account: account }
    status { "active" }
    mode { "api" }

    trait :with_project do
      project { association :project, account: account }
    end

    trait :idle do
      status { "idle" }
    end

    trait :closed do
      status { "closed" }
    end

    trait :archived do
      status { "archived" }
    end

    trait :workspace do
      mode { "workspace" }
      container_id { "abc123" }
      workspace_volume { "vol_abc123" }
    end
  end
end
