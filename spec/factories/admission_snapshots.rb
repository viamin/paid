# frozen_string_literal: true

FactoryBot.define do
  factory :admission_snapshot do
    account
    project { association :project, account: account }
    issue { association :issue, project: project }
    bounded_delegated_action do
      association :bounded_delegated_action, project: project, issue: issue, account: account
    end
    boundary { "queue" }
    action { "review" }
    status { "active" }
    snapshot do
      {
        "intent_revision" => "sha256:abc123",
        "acceptance_revision" => "criteria:xyz789",
        "evidence_revision" => "evidence:def456",
        "posture_signature" => "posture:sig123",
        "phase" => "coding",
        "phase_policy" => { "allowed" => true },
        "trust" => true,
        "budget" => { "allowed" => true },
        "repository_controls" => true,
        "assessment_available" => true
      }
    end
    expires_at { 30.days.from_now }
  end
end
