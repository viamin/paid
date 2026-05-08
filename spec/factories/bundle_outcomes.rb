# frozen_string_literal: true

FactoryBot.define do
  factory :bundle_outcome do
    configuration_bundle
    agent_run
    quality_score { 0.85 }
    duration_seconds { 120 }
    cost_cents { 50 }
    tokens_used { 5000 }
    success { true }
    metrics { {} }
  end
end
