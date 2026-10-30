# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_review_package do
    project
    association :agent_run, project:, goal: "layered_verification_audit"
    revision { 1 }
    sequence(:package_digest) { |n| Digest::SHA256.hexdigest("package-#{n}") }
    bound_inputs { {} }
    approvals { [] }
    inbox_decisions { [] }
  end
end
