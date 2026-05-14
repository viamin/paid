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
    team_scope { "account" }
    status { "active" }
  end
end
