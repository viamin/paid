# frozen_string_literal: true

FactoryBot.define do
  factory :issue do
    project

    sequence(:github_issue_id) { |n| 1_000_000 + n }
    sequence(:github_number) { |n| n }
    sequence(:title) { |n| "Issue #{n}" }
    body { "This is the issue body" }
    github_state { "open" }
    labels { [] }
    paid_state { "new" }
    github_created_at { 1.day.ago }
    github_updated_at { Time.current }

    trait :closed do
      github_state { "closed" }
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

    trait :with_labels do
      labels { [ "paid:planning", "bug", "enhancement" ] }
    end

    trait :sub_issue do
      parent_issue { association :issue, project: project }
    end
  end
end
