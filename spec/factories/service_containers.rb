# frozen_string_literal: true

FactoryBot.define do
  factory :service_container do
    image { "postgres:16" }
    sequence(:name) { |n| "postgres-#{n}" }
    port { 5432 }
    env { { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => "agent", "POSTGRES_DB" => "agent_test" } }
    status { "stopped" }

    after(:build) do
      if UserSetting.where.not(allowed_service_images: nil).none?
        create(:user_setting)
      end
    end

    trait :running do
      status { "running" }
      docker_container_id { SecureRandom.hex(32) }
    end

    trait :redis do
      image { "redis:7-alpine" }
      sequence(:name) { |n| "redis-#{n}" }
      port { 6379 }
      env { {} }
    end

    trait :selenium do
      image { "selenium/standalone-chromium:latest" }
      sequence(:name) { |n| "selenium-#{n}" }
      port { 4444 }
      env { {} }
    end
  end
end
