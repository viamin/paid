# frozen_string_literal: true

FactoryBot.define do
  factory :service_container do
    account
    image { "postgres:16" }
    sequence(:name) { |n| "postgres-#{n}" }
    port { 5432 }
    env { { "POSTGRES_USER" => "agent", "POSTGRES_PASSWORD" => "agent", "POSTGRES_DB" => "agent_test" } }
    status { "stopped" }

    after(:build) do |service_container|
      account = service_container.account || build(:account)
      service_container.account = account
      admin_user_ids = AccountMembership.where(account: account, role: [ :admin, :owner ]).select(:user_id)
      unless UserSetting.where(user_id: admin_user_ids).where.not(allowed_service_images: nil).exists?
        user = create(:user, account: account)
        user.add_role(:admin, account)
        create(:user_setting, user: user)
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
