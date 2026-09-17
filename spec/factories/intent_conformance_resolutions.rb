# frozen_string_literal: true

FactoryBot.define do
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
