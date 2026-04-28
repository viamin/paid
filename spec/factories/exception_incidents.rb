# frozen_string_literal: true

FactoryBot.define do
  factory :exception_incident do
    account
    sequence(:fingerprint) { |n| Digest::SHA256.hexdigest("exception-#{n}")[0, 32] }
    exception_class { "RuntimeError" }
    message { "Something went wrong" }
    backtrace { "/app/services/knowledge/collector_runner.rb:95:in `collect'" }
    subsystem { "knowledge" }
    severity { "p2" }
    action_taken { "logged" }
    status { "open" }
    last_occurred_at { Time.current }

    trait :p1 do
      severity { "p1" }
    end

    trait :with_project do
      project { association :project, account: account }
    end

    trait :issue_filed do
      action_taken { "issue_filed" }
      github_issue_url { "https://github.com/owner/repo/issues/42" }
      github_issue_number { 42 }
    end

    trait :resolved do
      status { "resolved" }
      resolved_at { Time.current }
    end
  end
end
