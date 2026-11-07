# frozen_string_literal: true

# @spec PROJECT-DELEGATION-007
FactoryBot.define do
    factory :project_delegation_pilot_metric, class: "ProjectDelegation::PilotMetric" do
    account { project.account }
    project
    posture { "bounded_delivery" }
    window_started_at { 30.days.ago }
    window_ended_at { 1.day.ago }
    completed_issues { 30 }
    total_issues { 32 }
    inbox_decisions { 12 }
    median_decision_seconds { 120.0 }
    p90_decision_seconds { 300.0 }
    completion_rate { 0.9375 }
    reversed_decisions { 0 }
    reversal_rate { 0.0 }
    revisions do
      {
        "intent_revision" => "sha256:#{Digest::SHA256.hexdigest("intent")}",
        "acceptance_revision" => "sha256:#{Digest::SHA256.hexdigest("acceptance")}",
        "evidence_revision" => "sha256:#{Digest::SHA256.hexdigest("evidence")}"
      }
    end
    reversals { [] }
    exclusions { {} }
    evidence { {} }

    trait :conservative do
      posture { "conservative" }
    end
  end
end
