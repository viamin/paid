# frozen_string_literal: true

FactoryBot.define do
  factory :preview_session do
<<<<<<< HEAD
    project { association :project }
    account { project.account }
    branch_name { "main" }
    framework { "rails" }
    status { "pending" }
=======
    project
    branch_name { "feature/preview" }
    container_id { "container-abc123" }
    sequence(:tunnel_port) { |n| 8200 + (n % 90) }
    status { "active" }
>>>>>>> origin/main
    expires_at { 30.minutes.from_now }

    trait :ready do
      status { "ready" }
<<<<<<< HEAD
      tunnel_port { 8200 }
      container_id { "preview-abc123" }
      last_active_at { Time.current }
    end

    trait :expired do
      status { "ready" }
      expires_at { 1.minute.ago }
=======
    end

    trait :provisioning do
      status { "provisioning" }
      tunnel_port { nil }
      container_id { nil }
>>>>>>> origin/main
    end

    trait :stopped do
      status { "stopped" }
    end

    trait :failed do
      status { "failed" }
<<<<<<< HEAD
      error_message { "boom" }
=======
    end

    trait :expired do
      status { "active" }
      expires_at { 5.minutes.ago }
    end

    trait :without_port do
      tunnel_port { nil }
>>>>>>> origin/main
    end
  end
end
