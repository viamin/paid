# frozen_string_literal: true

FactoryBot.define do
  factory :remediation_decision do
    account
    sequence(:fingerprint) { |n| "fingerprint-#{n}" }
    root_cause { "GitHub API rate limit exhausted" }
    confidence { 0.91 }
    evidence_pointers { [ "outer_errors[0]" ] }
    proposed_action { "notify" }
    action_target_type { "account" }
    action_target_id { account.id.to_s }
    action_target_metadata { {} }
    status { "proposed" }
    revert_data { {} }
    pre_remediation_failure_count { 3 }
    occurrence_count { 1 }
  end
end
