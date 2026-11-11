# frozen_string_literal: true

FactoryBot.define do
  factory :work_item do
    association :account
    provider { "linear" }
    resource_type { "issue" }
    sequence(:external_id) { |n| "issue-#{n}" }
    title { "Ticket title" }
    last_synced_at { Time.current }

    trait :with_native_project do
      native_project_id { "linear-project-1" }
      native_project_name { "Roadmap" }
    end
  end

  factory :work_item_project_mapping do
    association :account
    provider { "linear" }
    sequence(:native_project_id) { |n| "linear-project-#{n}" }
    native_project_name { "Roadmap" }
    assignment_mode { "current_and_future" }
  end

  factory :work_item_assignment do
    account
    work_item { create(:work_item, account:) }
    project { create(:project, account:) }
    provenance { "manual" }
  end

  factory :trusted_provider_identity do
    association :account
    provider { "linear" }
    identity_type { "user" }
    sequence(:external_id) { |n| "linear-user-#{n}" }
  end

  factory :provider_identity_mapping do
    account
    user { create(:user, account:) }
    provider { "linear" }
    sequence(:external_id) { |n| "linear-user-#{n}" }
  end

  factory :work_item_lifecycle_mapping do
    association :account
    provider { "linear" }
    native_state { "Todo" }
    paid_state { "open" }
  end
end
