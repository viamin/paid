# frozen_string_literal: true

FactoryBot.define do
  factory :container_pool_entry do
    project
    status { "warm" }
    sequence(:container_id) { |n| "pool-container-#{n}" }
    sequence(:workspace_volume) { |n| "paid-pool-workspace-#{n}" }
    image { Containers::Provision::DEFAULTS[:image] }
    network { "paid_agent" }
    warmed_at { Time.current }

    trait :warming do
      status { "warming" }
      container_id { nil }
      warmed_at { nil }
    end

    trait :claimed do
      status { "claimed" }
      agent_run { association :agent_run, project: project }
      claimed_at { Time.current }
    end

    trait :errored do
      status { "error" }
      last_error { "provision failed" }
    end
  end
end
