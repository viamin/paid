# frozen_string_literal: true

FactoryBot.define do
  factory :intent_conformance_review_schedule do
    project
    issue { association :issue, :pull_request, project: project }
    pr_head_sha { SecureRandom.hex(20) }
    approved_design_revision { SecureRandom.hex(20) }
  end
end
