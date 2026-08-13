# frozen_string_literal: true

FactoryBot.define do
  factory :marketplace_entry do
    account
    name { "Repo Coding Skill" }
    entry_type { "skill" }
    description { "Reusable repository-specific coding instructions" }
    provider { "claude" }
    provider_format { "canonical_v1" }
    usage_guidance { "Use for Rails issue implementation runs." }
    added_by_name { "Test User" }
    added_by_email { "test@example.com" }
    tags { [ "rails", "repo" ] }
    extension_points { [ "prompts", "tools" ] }
    certification_status { "verified" }
    support_tier { "community" }
    documentation_url { "https://docs.example.com/repo-coding-skill" }
    source_code_url { "https://github.com/example/repo-coding-skill" }
    certification_notes { "Validated against a reference Rails repo and reviewed for rollback safety." }
    team_scope { "account" }
    status { "active" }
  end
end
