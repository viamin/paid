# frozen_string_literal: true

FactoryBot.define do
  factory :intent_conformance_verdict do
    project
    issue { association :issue, :pull_request, project: project }
    pr_head_sha { SecureRandom.hex(20) }
    approved_design_revision { SecureRandom.hex(20) }
    outcome { IntentConformanceVerdict::OUTCOME_WITHIN_SCOPE }
    reasoning_summary { "The PR matches the approved design's acceptance criteria." }
    evaluated_at { Time.current }

    trait :material_drift do
      outcome { IntentConformanceVerdict::OUTCOME_MATERIAL_DRIFT }
      cited_claims { [ { "design_ref" => "RDR-067#decision", "claim_text" => "Bounded exceptions are head-scoped." } ] }
      cited_diff_locations { [ { "file" => "app/services/intent_conformance/signal.rb", "anchor" => "L10" } ] }
    end

    trait :uncertain do
      outcome { IntentConformanceVerdict::OUTCOME_UNCERTAIN }
    end

    trait :not_evaluated do
      outcome { IntentConformanceVerdict::OUTCOME_NOT_EVALUATED }
    end
  end
end
