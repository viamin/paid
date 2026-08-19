# frozen_string_literal: true

FactoryBot.define do
  factory :egress_allowlist_entry do
    account
    host_pattern { "api.example.com" }
    enabled { true }
    reason { "Package registry for the monorepo" }

    trait :disabled do
      enabled { false }
    end

    trait :wildcard do
      host_pattern { "*.packages.example.com" }
    end

    trait :project_scoped do
      project { association :project, account: account }
    end
  end
end
