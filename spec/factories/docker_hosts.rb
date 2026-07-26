# frozen_string_literal: true

FactoryBot.define do
  factory :docker_host do
    account
    sequence(:identifier) { |n| "host_#{n}" }
    sequence(:display_name) { |n| "Host #{n}" }
    backend_type { "remote" }
    endpoint { "tcp://docker.example.test:2376" }
    callback_url { "https://paid.example.test/health/services" }
    image_tag { "paid-agent:latest" }
    enabled { true }
    fallback_eligible { true }
    manual_concurrency_limit { 4 }
    readiness_status { "ready" }
    image_status { "ready" }
    required_network_status { "ready" }

    trait :local do
      backend_type { "local" }
      endpoint { nil }
    end

    trait :disabled do
      enabled { false }
      readiness_status { "disabled" }
    end
  end
end
