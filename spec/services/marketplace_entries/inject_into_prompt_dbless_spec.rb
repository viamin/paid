# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::InjectIntoPrompt, :no_db do
  it "appends prompt-facing marketplace payloads" do
    agent_run = build_agent_run

    rendered = described_class.call(agent_run:, prompt: "# Task\n\nImplement the issue.")

    expect(rendered).to include("Marketplace Attachments")
    expect(rendered).to include("Use the repository workflow.")
  end

  it "preserves a nil prompt when there are no marketplace attachments" do
    agent_run = build_agent_run(attachments: [])

    expect(described_class.call(agent_run:, prompt: nil)).to be_nil
  end

  it "returns the prompt without loading attachment records when none exist" do
    stub_const("InjectIntoPromptDblessRelation", Class.new)
    relation = instance_double(InjectIntoPromptDblessRelation)
    allow(relation).to receive_messages(loaded?: false, exists?: false)
    allow(relation).to receive(:includes).and_raise("should not load attachments")

    agent_run = Struct.new(:agent_run_marketplace_entries, keyword_init: true)
      .new(agent_run_marketplace_entries: relation)

    expect(described_class.call(agent_run:, prompt: "Base prompt")).to eq("Base prompt")
  end

  it "builds marketplace content when attachments exist but the base prompt is nil" do
    agent_run = build_agent_run

    rendered = described_class.call(agent_run:, prompt: nil)

    expect(rendered).to start_with("# Marketplace Attachments")
    expect(rendered).to include("Use the repository workflow.")
  end

  it "re-renders prompt content when the executing provider changes" do
    agent_run = build_agent_run(attachments: [ provider_switching_attachment ])

    rendered = described_class.call(agent_run:, prompt: "Base prompt", provider_key: "codex")

    expect(rendered).to include("Codex workflow.")
    expect(rendered).not_to include("Claude workflow.")
  end

  def build_agent_run(attachments: nil)
    relation = Struct.new(:attachments, keyword_init: true) do
      def loaded?
        true
      end

      def exists?
        attachments.any?
      end

      def includes(*)
        self
      end

      def ordered
        attachments
      end
    end.new(attachments: attachments || [ build_attachment ])

    Struct.new(:agent_run_marketplace_entries, keyword_init: true)
      .new(agent_run_marketplace_entries: relation)
  end

  def build_attachment(rendered_payload: nil, provider_renderers: {})
    entry = Struct.new(:name, keyword_init: true).new(name: "Repo skill")
    version = Struct.new(:renderers, :canonical_artifact, keyword_init: true).new(
      renderers: provider_renderers,
      canonical_artifact: {
        "attachment_strategy" => "prompt_append",
        "content" => "Canonical workflow."
      }
    )

    Struct.new(
      :rendered_payload,
      :marketplace_entry,
      :marketplace_entry_version,
      :attachment_source,
      :selection_reason,
      keyword_init: true
    ).new(
      rendered_payload: rendered_payload || {
        "attachment_strategy" => "prompt_append",
        "payload" => { "content" => "Use the repository workflow." }
      },
      marketplace_entry: entry,
      marketplace_entry_version: version,
      attachment_source: "manual",
      selection_reason: "Selected manually"
    )
  end

  def provider_switching_attachment
    build_attachment(
      rendered_payload: {
        "provider" => "claude",
        "attachment_strategy" => "prompt_append",
        "payload" => { "content" => "Claude workflow." }
      },
      provider_renderers: {
        "codex" => {
          "attachment_strategy" => "prompt_append",
          "provider_format" => "codex_skill_v1",
          "content" => "Codex workflow."
        }
      }
    )
  end
end
