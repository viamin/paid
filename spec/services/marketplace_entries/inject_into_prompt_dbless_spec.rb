# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::InjectIntoPrompt, :no_db do
  it "appends prompt-facing marketplace payloads" do
    agent_run = build_agent_run

    rendered = described_class.call(agent_run:, prompt: "# Task\n\nImplement the issue.")

    expect(rendered).to include("Marketplace Attachments")
    expect(rendered).to include("Use the repository workflow.")
  end

  def build_agent_run
    entry = Struct.new(:name, keyword_init: true).new(name: "Repo skill")
    attachment = Struct.new(
      :rendered_payload,
      :marketplace_entry,
      :attachment_source,
      :selection_reason,
      keyword_init: true
    ).new(
      rendered_payload: {
        "attachment_strategy" => "prompt_append",
        "payload" => { "content" => "Use the repository workflow." }
      },
      marketplace_entry: entry,
      attachment_source: "manual",
      selection_reason: "Selected manually"
    )
    relation = Struct.new(:attachments, keyword_init: true) do
      def includes(*)
        self
      end

      def ordered
        attachments
      end
    end.new(attachments: [ attachment ])

    Struct.new(:agent_run_marketplace_entries, keyword_init: true)
      .new(agent_run_marketplace_entries: relation)
  end
end
