# frozen_string_literal: true

FactoryBot.define do
  factory :project do
    account
    github_token { association :github_token, account: account }
    created_by { association :user, account: account }

    sequence(:name) { |n| "Project #{n}" }
    sequence(:github_id) { |n| 100_000_000 + n }
    sequence(:owner) { |n| "owner-#{n}" }
    sequence(:repo) { |n| "repo-#{n}" }
    default_branch { "main" }
    active { true }
    poll_interval_seconds { 60 }
    label_mappings { {} }
    allowed_github_usernames { [ "viamin" ] }

    trait :inactive do
      active { false }
    end

    trait :with_label_mappings do
      label_mappings do
        {
          "planning" => "paid:planning",
          "in_progress" => "paid:in-progress",
          "review" => "paid:review",
          "completed" => "paid:completed"
        }
      end
    end

    trait :with_metrics do
      total_cost_cents { 1500 }
      total_tokens_used { 50_000 }
    end

    trait :without_creator do
      created_by { nil }
    end

    trait :with_github_installation do
      github_token { nil }
      github_installation { association :github_installation, account: account }
    end

    trait :with_interop_settings do
      interop_settings do
        {
          "adoption_mode" => "advisory",
          "external_execution_sources" => {
            "cursor" => true
          }
        }
      end
    end
  end
end
