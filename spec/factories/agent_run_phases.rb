# frozen_string_literal: true

FactoryBot.define do
  factory :agent_run_phase do
    agent_run
    phase_key { "run_agent" }
    phase_group { "agent" }
    status { "completed" }
    started_at { 5.minutes.ago }
    finished_at { 3.minutes.ago }
    duration_seconds { 120 }
    metadata { {} }
  end
end
