# frozen_string_literal: true

FactoryBot.define do
  factory :feature_intent do
    project
    sequence(:title) { |n| "Feature intent #{n}" }
    brief { "Ship the approved feature." }
    status { "released" }
    approved_design_revision { "abc123superseded" }
    approved_revision_recorded_at { 1.day.ago }
  end

  factory :feature_intent_issue do
    feature_intent
    issue
  end

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

  factory :design_amendment_pause do
    design_amendment
    issue
    reason_code { "affected" }
    status { "held" }
    evidence { { "cited_claims" => [] } }
  end

  factory :design_amendment_follow_up do
    design_amendment
    issue
    status { "open" }
    evidence { { "cited_claims" => [] } }
  end

  factory :intent_conformance_resolution do
    project
    issue { association :issue, :pull_request, project: project }
    resolved_by { association :user, account: project.account }
    resolution_type { "implementation_exception" }
    sequence(:pull_request_number) { |n| 500 + n }
    sequence(:pr_head_sha) { |n| format("head<%04d>", n) }
    reason { "The deviation leaves the product contract intact." }
  end
end
