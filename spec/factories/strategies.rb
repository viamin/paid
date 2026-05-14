# frozen_string_literal: true

FactoryBot.define do
  factory :strategy do
    sequence(:slug) { |n| "issue.execution-#{n}" }
    sequence(:name) { |n| "Strategy #{n}" }
    decision_type { "issue_execution" }
    status { "active" }
    selection_rules { { "task_type" => "issue", "repository_size" => "any" } }

    trait :global do
      account { nil }
      project { nil }
    end

    trait :for_account do
      account { association :account, strategy: :create }
      project { nil }
    end

    trait :for_project do
      project { association :project, strategy: :create }
      account { project.account }
    end

    trait :draft do
      status { "draft" }
    end

    trait :archived do
      status { "archived" }
    end

    trait :with_version do
      after(:create) do |strategy|
        reviewer = create(:user, account: strategy.account || create(:account))
        version = strategy.create_version!(
          content: {
            "decomposition_approach" => "single",
            "max_parallel_agents" => 1,
            "retry_policy" => { "type" => "exponential", "attempts" => 3 }
          },
          provenance: { "source" => "seed" },
          promotion_state: "active",
          created_by: "seed",
          promoted_at: Time.current,
          promoted_by_user: reviewer
        )
        strategy.update!(current_version: version)
      end
    end
  end
end
