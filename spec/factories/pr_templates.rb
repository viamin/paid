# frozen_string_literal: true

FactoryBot.define do
  factory :pr_template do
    account
    project { nil }
    user { nil }
    sequence(:name) { |n| "template-#{n}" }
    pr_type { "default" }
    body { "## Summary\n\n{{description}}\n\n## Test Plan\n\n- [ ] Tests pass" }
    description { nil }
    position { 0 }
    enabled { true }

    trait :project_level do
      project
      account { project.account }
    end

    trait :user_level do
      user
      account { user.account }
    end

    trait :feature do
      pr_type { "feature" }
    end

    trait :bugfix do
      pr_type { "bugfix" }
    end

    trait :hotfix do
      pr_type { "hotfix" }
    end

    trait :disabled do
      enabled { false }
    end
  end
end
