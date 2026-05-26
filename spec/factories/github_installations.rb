# frozen_string_literal: true

FactoryBot.define do
  factory :github_installation do
    account
    sequence(:github_installation_id) { |n| 10_000_000 + n }
    account_login { "test-org" }
    target_type { "Organization" }
    repository_selection { "selected" }
    accessible_repositories { [ { "full_name" => "test-org/repo", "id" => 123 } ] }

    trait :suspended do
      suspended_at { Time.current }
    end

    trait :revoked do
      revoked_at { Time.current }
    end

    trait :all_repos do
      repository_selection { "all" }
    end

    trait :user_target do
      target_type { "User" }
      account_login { "test-user" }
    end
  end
end
