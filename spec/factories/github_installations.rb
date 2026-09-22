# frozen_string_literal: true

FactoryBot.define do
  factory :github_installation do
    account
    sequence(:github_installation_id) { |n| 10_000_000 + n }
    account_login { "test-org" }
    target_type { "Organization" }
    repository_selection { "selected" }
    accessible_repositories { [ { "full_name" => "test-org/repo", "id" => 123 } ] }
    repositories_synced_at { Time.current }

    trait :covering_project do
      transient do
        project { nil }
      end
      accessible_repositories do
        target_project = project
        if target_project
          [ { "full_name" => target_project.full_name, "id" => target_project.github_id } ]
        else
          [ { "full_name" => "test-org/repo", "id" => 123 } ]
        end
      end
      account_login do
        target_project = project
        target_project ? target_project.owner : "test-org"
      end
    end

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
