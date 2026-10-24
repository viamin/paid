# frozen_string_literal: true

FactoryBot.define do
  factory :intent_conformance_shadow_evaluation do
    project
    association :solo_maintainer, factory: :user
    association :created_by, factory: :user
    policy { "solo" }
    status { "labeling" }
    purpose { "rdr-067-measured-rollout" }
    manifest_path { "docs/intent/intent-conformance-rollout/shadow-evaluation-manifest-spec.yml" }
    manifest_commit { SecureRandom.hex(20) }
    manifest_digest { SecureRandom.hex(32) }

    trait :frozen do
      status { "frozen" }
      labels_frozen_at { Time.current }
    end
  end

  factory :intent_conformance_shadow_evaluation_label do
    association :shadow_evaluation, factory: :intent_conformance_shadow_evaluation
    association :recorded_by, factory: :user
    sequence(:case_id) { |n| "A-#{format('%02d', n)}" }
    state { "labeled" }
    outcome { "within_scope" }
    cited_design_claim { "RDR-999 §2: the widget SHALL be blue." }
    reason { "Matches the approved design." }
    recorded_at { Time.current }
  end

  factory :intent_conformance_shadow_evaluation_run do
    association :shadow_evaluation, factory: :intent_conformance_shadow_evaluation
    case_id { "A-01" }
    reviewer_run_id { "run-A-01" }
    reviewer_model { "claude-sonnet-4-6" }
    prompt_digest { SecureRandom.hex(16) }
    verdict { "within_scope" }
    cost_cents { 0 }
    recorded_at { Time.current }

    trait :not_evaluated do
      verdict { "not_evaluated" }
      failure_reason { "unsuccessful_response" }
    end
  end
end
