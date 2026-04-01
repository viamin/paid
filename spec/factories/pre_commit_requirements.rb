# frozen_string_literal: true

FactoryBot.define do
  factory :pre_commit_requirement do
    account
    project { nil }
    user { nil }
    sequence(:name) { |n| "check-#{n}" }
    command { "bin/lint" }
    check_type { "shell_command" }
    failure_behavior { "block" }
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

    trait :with_auto_fix do
      failure_behavior { "auto_fix" }
      fix_command { "bin/lint -a" }
    end

    trait :warn_only do
      failure_behavior { "warn" }
    end

    trait :disabled do
      enabled { false }
    end

    trait :test_suite do
      check_type { "test_suite" }
      command { "bin/rspec" }
    end

    trait :coverage do
      check_type { "coverage" }
      command { "bin/coverage-check" }
    end

    trait :security_scan do
      check_type { "security_scan" }
      command { "bin/brakeman" }
    end
  end
end
