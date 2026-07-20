# frozen_string_literal: true

FactoryBot.define do
  factory :preview_session do
    project
    branch_name { "feature/preview" }
    container_id { "container-abc123" }
    sequence(:tunnel_port) { |n| 8200 + (n % 90) }
    status { "active" }
    expires_at { 30.minutes.from_now }

    trait :ready do
      status { "ready" }
    end

    trait :provisioning do
      status { "provisioning" }
      tunnel_port { nil }
      container_id { nil }
    end

    trait :stopped do
      status { "stopped" }
    end

    trait :failed do
      status { "failed" }
    end

    trait :expired do
      status { "active" }
      expires_at { 5.minutes.ago }
    end

    trait :without_port do
      tunnel_port { nil }
    end
  end
end
