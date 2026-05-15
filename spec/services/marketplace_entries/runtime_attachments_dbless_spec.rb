# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::RuntimeAttachments, :no_db do
  it "extracts runtime env and file preparation from runtime-config attachments" do
    agent_run = build_agent_run([
      build_attachment(
        strategy: "runtime_config",
        payload: {
          "env" => { "MARKETPLACE_PLUGIN_FLAG" => "enabled" },
          "files" => [ { "path" => "~/.config/paid/plugin.json", "content" => "{\"enabled\":true}" } ]
        }
      )
    ])

    expect(described_class.runtime_env(agent_run)).to eq("MARKETPLACE_PLUGIN_FLAG" => "enabled")

    preparation = described_class.runtime_preparation(agent_run)
    expect(preparation.file_writes.map(&:path)).to eq([ "~/.config/paid/plugin.json" ])
    expect(preparation.file_writes.map(&:content)).to eq([ "{\"enabled\":true}" ])
  end

  it "extracts MCP snapshots from marketplace attachments" do
    agent_run = build_agent_run([ build_mcp_attachment ])

    expect(described_class.mcp_server_snapshots(agent_run)).to contain_exactly(
      include(
        "name" => "repo-docs",
        "install_type" => "npx",
        "command" => "npx",
        "marketplace_attachment" => true,
        "marketplace_entry_id" => 9,
        "marketplace_entry_version_id" => 11
      )
    )
  end

  it "ignores unsafe runtime file paths" do
    agent_run = build_agent_run([
      build_attachment(
        strategy: "runtime_config",
        payload: {
          "files" => [
            { "path" => "/etc/passwd", "content" => "root:x:0:0" },
            { "path" => "../.bashrc", "content" => "alias ll='ls -la'" },
            { "path" => "~/.config/paid/plugin.json", "content" => "{\"enabled\":true}" }
          ]
        }
      )
    ])

    preparation = described_class.runtime_preparation(agent_run)

    expect(preparation.file_writes.map(&:path)).to eq([ "~/.config/paid/plugin.json" ])
  end

  it "keeps only marketplace-prefixed runtime env keys" do
    agent_run = build_agent_run([
      build_attachment(
        strategy: "runtime_config",
        payload: {
          "env" => {
            "MARKETPLACE_PLUGIN_FLAG" => "enabled",
            "path" => "/tmp/override",
            "AWS_SECRET_ACCESS_KEY" => "leak",
            "PAID_PLUGIN_FLAG" => "legacy"
          }
        }
      )
    ])

    expect(described_class.runtime_env(agent_run)).to eq("MARKETPLACE_PLUGIN_FLAG" => "enabled")
  end

  def build_agent_run(attachments)
    relation = Struct.new(:attachments, keyword_init: true) do
      def ordered = self
      def to_a = attachments
    end.new(attachments:)

    Struct.new(:agent_run_marketplace_entries, keyword_init: true).new(agent_run_marketplace_entries: relation)
  end

  def build_attachment(strategy:, payload:, entry_id: 7, version_id: 8)
    Struct.new(:rendered_payload, :marketplace_entry_id, :marketplace_entry_version_id, keyword_init: true).new(
      rendered_payload: {
        "attachment_strategy" => strategy,
        "payload" => payload
      },
      marketplace_entry_id: entry_id,
      marketplace_entry_version_id: version_id
    )
  end

  def build_mcp_attachment
    build_attachment(
      strategy: "mcp_server",
      entry_id: 9,
      version_id: 11,
      payload: {
        "name" => "repo-docs",
        "install_type" => "npx",
        "command" => "npx"
      }
    )
  end
end
