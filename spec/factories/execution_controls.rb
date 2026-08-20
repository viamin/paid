# frozen_string_literal: true

FactoryBot.define do
  factory :execution_control do
    scope { "global" }
    mode { "capacity" }
    enabled { false }
    metadata { {} }

    trait :global do
      scope { "global" }
    end

    trait :account_scope do
      scope { "account" }
      account
    end

    trait :project_scope do
      scope { "project" }
      project
    end

    trait :runner_scope do
      scope { "runner" }
      runner
    end

    trait :backend_scope do
      scope { "backend" }
      docker_host
    end

    trait :enabled do
      enabled { true }
      enabled_at { Time.current }
      reason { "Temporarily disabled" }
    end

    trait :emergency do
      mode { "emergency" }
    end
  end
end
