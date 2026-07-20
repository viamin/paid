# frozen_string_literal: true

FactoryBot.define do
  factory :preview_session do
    project { association :project }
    account { project.account }
    branch_name { "main" }
    framework { "rails" }
    status { "pending" }
    expires_at { 30.minutes.from_now }

    trait :provisioning do
      status { "provisioning" }
    end

    trait :ready do
      status { "ready" }
      sequence(:tunnel_port) { |n| 8200 + (n % 90) }
      container_id { "preview-abc123" }
      last_active_at { Time.current }
    end

    trait :expired do
      status { "ready" }
      sequence(:tunnel_port) { |n| 8300 + (n % 90) }
      expires_at { 1.minute.ago }
    end

    trait :stopped do
      status { "stopped" }
    end

    trait :failed do
      status { "failed" }
      error_message { "boom" }
    end

    trait :without_port do
      tunnel_port { nil }
    end
  end
end
