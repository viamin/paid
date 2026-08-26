# frozen_string_literal: true

FactoryBot.define do
  factory :auto_merge_attempt do
    project
    issue { association :issue, :pull_request, project: project }
    attempted_at { Time.current }
    actor_path { AutoMergeAttempts::Record::ACTOR_REVIEW_AUTO_MERGE }
    status { "blocked" }
    reason_code { AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION }
    sanitized_message { "Missing workflows permission." }
    credential_mode { "github_app" }
  end
end
