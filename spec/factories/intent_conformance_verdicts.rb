# frozen_string_literal: true

FactoryBot.define do
  factory :intent_conformance_verdict do
    issue { association :issue, :pull_request }
    pr_head_sha { SecureRandom.hex(20) }
    approved_design_revision { SecureRandom.hex(20) }
    outcome { IntentConformanceVerdict::WITHIN_SCOPE }
    reasoning_summary { "The PR matches the approved design's acceptance criteria." }
    evaluated_at { Time.current }

    trait :material_drift do
      outcome { IntentConformanceVerdict::MATERIAL_DRIFT }
      cited_claims { [ { "design_ref" => "RDR-067#decision", "claim_text" => "Bounded exceptions are head-scoped." } ] }
      cited_diff_locations { [ { "file" => "app/services/intent_conformance/signal.rb", "anchor" => "L10" } ] }
    end

    trait :uncertain do
      outcome { IntentConformanceVerdict::UNCERTAIN }
    end

    trait :not_evaluated do
      outcome { IntentConformanceVerdict::NOT_EVALUATED }
    end
  end
end
