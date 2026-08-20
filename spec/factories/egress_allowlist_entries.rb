# frozen_string_literal: true

FactoryBot.define do
  factory :egress_allowlist_entry do
    account
    project { nil }
    sequence(:host_pattern) { |n| "host#{n}.example.com" }
    scheme { nil }
    port { nil }
    enabled { true }
    source_kind { "tenant" }
    reason { "internal package registry" }

    trait :account_level do
      project { nil }
    end

    trait :project_level do
      project { association :project, account: account }
    end

    trait :disabled do
      enabled { false }
      disabled_at { Time.current }
    end

    trait :with_scheme do
      scheme { "https" }
    end

    trait :with_port do
      port { 8443 }
    end

    trait :wildcard do
      sequence(:host_pattern) { |n| "*.packages#{n}.example.com" }
    end
  end
end
