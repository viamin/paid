# frozen_string_literal: true

FactoryBot.define do
  factory :agent_run_marketplace_entry do
    agent_run
    marketplace_entry
    marketplace_entry_version
    attachment_source { "manual" }
    position { 0 }
    selection_reason { "Selected manually for this run" }
    rendered_format { "canonical_v1" }
    rendered_payload do
      {
        "provider" => "claude",
        "provider_format" => "canonical_v1",
        "attachment_strategy" => "prompt_append",
        "payload" => {
          "content" => "Follow the repository coding workflow."
        }
      }
    end
  end
end
