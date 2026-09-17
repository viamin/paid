# frozen_string_literal: true

FactoryBot.define do
  factory :design_amendment do
    project
    feature_intent { association :feature_intent, project: project }
    status { "open" }
    reason { "The approved acceptance criteria must change." }
    drift_evidence do
      {
        "changed_claims" => [
          "RDR-067 §Decision: verdicts are bound to PR head and design revision",
          "EARS INTENT-AMENDMENT-001: exceptions cannot change product commitments"
        ]
      }
    end
    design_pr_url { "https://github.com/example/example/pull/9001" }
    superseded_revision { |a| a.feature_intent.approved_design_revision || "abc123superseded" }
  end
end
