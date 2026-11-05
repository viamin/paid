# frozen_string_literal: true

# @spec BOUNDED-DELEGATED-ACTION-001
FactoryBot.define do
  factory :bounded_delegated_action do
    account { project.account }
    project
    issue { association :issue, project: }
    created_by { association :user, account: }
    action { "repair" }
    evidence { { "intent_digest" => "sha256:bounded", "acceptance_refs" => [ "AC-1" ] } }
    status { "active" }
    expires_at { 24.hours.from_now }
  end
end
