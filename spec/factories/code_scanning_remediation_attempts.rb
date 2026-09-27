# frozen_string_literal: true

FactoryBot.define do
  factory :code_scanning_remediation_attempt do
    issue
    pull_request_number { 1 }
    merge_commit_sha { "a" * 40 }
    merged_at { Time.current }
    status { "awaiting_verification" }
    tool_name { "CodeQL" }
    category { "/language:ruby" }
  end
end
