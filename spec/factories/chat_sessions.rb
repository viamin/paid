# frozen_string_literal: true

FactoryBot.define do
  factory :chat_session do
    account
    created_by { association :user, account: account }
    status { "active" }
    container_capability { "none" }
    clone_manifest { [] }

    trait :with_project do
      project { association :project, account: account }
    end

    trait :idle do
      status { "idle" }
    end

    trait :closed do
      status { "closed" }
    end

    trait :active do
      status { "active" }
    end

    trait :archived do
      status { "archived" }
    end

    trait :workspace do
      container_capability { "ready" }
      container_requested_at { 5.minutes.ago }
      container_ready_at { 1.minute.ago }
      container_id { "abc123" }
      workspace_volume { "vol_abc123" }
    end
  end
end
