# frozen_string_literal: true

FactoryBot.define do
  factory :provider do
    user
    provider_key { "cursor" }
    enabled_for_agent_runs { true }
    enabled_for_fallback { true }
    config { {} }
  end
end
