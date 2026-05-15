# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::RerenderForRun, :no_db do
  it "re-renders stored attachments for the run provider and refreshes the MCP snapshot" do
    stub_const("AgentRunMarketplaceEntry", transaction_class)
    attachment = build_attachment
    agent_run = build_agent_run([ attachment ])

    attachments = described_class.call(agent_run: agent_run)

    expect(attachments).to eq([ attachment ])
    expect_rendered_attachment(attachment)
    expect_updated_snapshot(agent_run)
  end

  def transaction_class
    Class.new do
      def self.transaction
        yield
      end
    end
  end

  def build_attachment
    entry = Struct.new(:provider_format, :entry_type, :name, keyword_init: true).new(
      provider_format: "canonical_v1",
      entry_type: "mcp_server",
      name: "Repo MCP"
    )
    version = Struct.new(:renderers, :canonical_artifact, keyword_init: true).new(
      renderers: {
        "codex" => {
          "attachment_strategy" => "mcp_server",
          "provider_format" => "codex_mcp_v1",
          "name" => "repo-docs",
          "install_type" => "npx",
          "command" => "npx"
        }
      },
      canonical_artifact: {
        "attachment_strategy" => "mcp_server",
        "name" => "repo-docs",
        "install_type" => "npx",
        "command" => "npx"
      }
    )

    Struct.new(
      :marketplace_entry,
      :marketplace_entry_version,
      :marketplace_entry_id,
      :marketplace_entry_version_id,
      :rendered_payload,
      :updated_attributes,
      keyword_init: true
    ) do
      def update!(attributes)
        self.updated_attributes = attributes
        self.rendered_payload = attributes.fetch(:rendered_payload)
      end
    end.new(
      marketplace_entry: entry,
      marketplace_entry_version: version,
      marketplace_entry_id: 9,
      marketplace_entry_version_id: 11,
      rendered_payload: {
        "provider" => "claude",
        "attachment_strategy" => "mcp_server",
        "payload" => { "name" => "repo-docs" }
      }
    )
  end

  def build_agent_run(attachments)
    relation = Struct.new(:attachments, keyword_init: true) do
      def includes(*)
        self
      end

      def ordered
        attachments
      end
    end.new(attachments: attachments)
    provider = Struct.new(:provider_key, keyword_init: true).new(provider_key: "codex")

    Struct.new(
      :agent_run_marketplace_entries,
      :provider,
      :agent_type,
      :mcp_server_snapshot,
      :updated_snapshot,
      keyword_init: true
    ) do
      def update_columns(attributes)
        self.updated_snapshot = attributes.fetch(:mcp_server_snapshot)
      end
    end.new(
      agent_run_marketplace_entries: relation,
      provider: provider,
      agent_type: "codex",
      mcp_server_snapshot: [ { "name" => "base-server" } ]
    )
  end

  def expect_rendered_attachment(attachment)
    expect(attachment.updated_attributes).to include(
      rendered_format: "codex_mcp_v1",
      rendered_payload: include(
        "provider" => "codex",
        "payload" => include("name" => "repo-docs")
      )
    )
  end

  def expect_updated_snapshot(agent_run)
    expect(agent_run.updated_snapshot).to include(
      { "name" => "base-server" },
      include(
        "name" => "repo-docs",
        "marketplace_attachment" => true,
        "marketplace_entry_id" => 9,
        "marketplace_entry_version_id" => 11
      )
    )
  end
end
