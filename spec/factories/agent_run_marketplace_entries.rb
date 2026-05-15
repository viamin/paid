# frozen_string_literal: true

FactoryBot.define do
  factory :agent_run_marketplace_entry do
    agent_run
    marketplace_entry
    marketplace_entry_version { association :marketplace_entry_version, marketplace_entry: marketplace_entry }
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

    after(:create) do |attachment|
      entry = attachment.marketplace_entry
      next if entry.current_version_id == attachment.marketplace_entry_version_id

      entry.update!(current_version: attachment.marketplace_entry_version)
    end
  end
end
