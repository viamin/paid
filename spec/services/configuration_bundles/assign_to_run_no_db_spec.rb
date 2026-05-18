# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::AssignToRun, :no_db do
  let(:attachment) { build_attachment }
  let(:agent_run) { build_agent_run(attachment:) }

  describe "#normalized_marketplace_entries" do
    it "uses the effective provider payload for the run" do
      service = described_class.new(agent_run:)

      expect(service.send(:normalized_marketplace_entries)).to eq(
        [
          {
            entry_id: 17,
            version_id: 29,
            source: "manual",
            rendered_format: "codex_skill_v1",
            rendered_payload: {
              "provider" => "codex",
              "provider_format" => "codex_skill_v1",
              "attachment_strategy" => "prompt_append",
              "payload" => { "content" => "Codex instructions" }
            }
          }
        ]
      )
    end
  end

  def build_attachment
    entry = Struct.new(:name, keyword_init: true).new(name: "Shared skill")
    version = Struct.new(:renderers, :canonical_artifact, keyword_init: true).new(
      renderers: {
        "claude" => {
          "attachment_strategy" => "prompt_append",
          "provider_format" => "claude_skill_v1",
          "content" => "Claude instructions"
        },
        "codex" => {
          "attachment_strategy" => "prompt_append",
          "provider_format" => "codex_skill_v1",
          "content" => "Codex instructions"
        }
      },
      canonical_artifact: {
        "attachment_strategy" => "prompt_append",
        "provider_format" => "canonical_v1",
        "content" => "Canonical instructions"
      }
    )

    Struct.new(
      :marketplace_entry_id,
      :marketplace_entry_version_id,
      :attachment_source,
      :rendered_format,
      :rendered_payload,
      :marketplace_entry,
      :marketplace_entry_version,
      keyword_init: true
    ).new(
      marketplace_entry_id: 17,
      marketplace_entry_version_id: 29,
      attachment_source: "manual",
      rendered_format: "claude_skill_v1",
      rendered_payload: {
        "provider" => "claude",
        "provider_format" => "claude_skill_v1",
        "attachment_strategy" => "prompt_append",
        "payload" => { "content" => "Claude instructions" }
      },
      marketplace_entry: entry,
      marketplace_entry_version: version
    )
  end

  def build_agent_run(attachment:)
    runner = Struct.new(:runner_key, keyword_init: true).new(runner_key: "codex")
    project = Struct.new(:account, keyword_init: true).new(account: nil)
    attachments = Struct.new(:records, keyword_init: true) do
      def ordered
        records
      end
    end.new(records: [ attachment ])

    Struct.new(:runner, :agent_type, :project, :agent_run_marketplace_entries, keyword_init: true).new(
      runner: runner,
      agent_type: "codex",
      project: project,
      agent_run_marketplace_entries: attachments
    )
  end
end
