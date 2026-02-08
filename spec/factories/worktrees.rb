# frozen_string_literal: true

FactoryBot.define do
  factory :worktree do
    project
    agent_run { association :agent_run, project: project }
    sequence(:branch_name) { |n| "paid/paid-agent-#{n}-#{SecureRandom.hex(6)}" }
    path { "/var/paid/workspaces/#{project.account_id}/#{project.id}/worktrees/#{branch_name.tr('/', '-')}" }
    base_commit { "0123456789abcdef0123456789abcdef01234567" }
    status { "active" }
    pushed { false }

    trait :active do
      status { "active" }
    end

    trait :cleaned do
      status { "cleaned" }
      cleaned_at { Time.current }
    end

    trait :cleanup_failed do
      status { "cleanup_failed" }
    end

    trait :pushed do
      pushed { true }
    end

    trait :stale do
      created_at { 25.hours.ago }
    end

    trait :without_agent_run do
      agent_run { nil }
    end
  end
end
