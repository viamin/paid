# frozen_string_literal: true

FactoryBot.define do
  factory :issue do
    project

    sequence(:github_issue_id) { |n| 1_000_000 + n }
    sequence(:github_number) { |n| n }
    sequence(:title) { |n| "Issue #{n}" }
    body { "This is the issue body" }
    github_creator_login { "viamin" }
    github_state { "open" }
    paid_state { "new" }
    github_created_at { 1.day.ago }
    github_updated_at { Time.current }

    trait :closed do
      github_state { "closed" }
    end

    trait :pull_request do
      is_pull_request { true }
      pr_review_phase { "ready" }
    end

    trait :planning do
      paid_state { "planning" }
    end

    trait :in_progress do
      paid_state { "in_progress" }
    end

    trait :completed do
      paid_state { "completed" }
    end

    trait :failed do
      paid_state { "failed" }
    end

    trait :needs_input do
      paid_state { "needs_input" }
    end

    trait :recommend_close do
      paid_state { "recommend_close" }
    end

    trait :with_labels do
      labels { [ "paid:planning", "bug", "enhancement" ] }
    end

    trait :sub_issue do
      parent_issue { association :issue, project: project }
    end
  end
end
