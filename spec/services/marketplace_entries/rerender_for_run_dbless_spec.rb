# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::RerenderForRun, :no_db do
  it "keeps stored attachments immutable and refreshes the MCP snapshot for the provider attempt" do
    attachment = build_attachment
    agent_run = build_agent_run([ attachment ])

    attachments = described_class.call(agent_run: agent_run)

    expect(attachments).to eq([ attachment ])
    expect_stored_attachment_to_remain_unchanged(attachment)
    expect_updated_snapshot(agent_run)
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
      keyword_init: true
    ).new(
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
    persistence_relation_class = Struct.new(:updated_snapshot, keyword_init: true) do
      def update_all(attributes)
        self.updated_snapshot = attributes.fetch(:mcp_server_snapshot)
      end
    end
    persistence_relation = persistence_relation_class.new
    fake_model_class = Class.new do
      define_method(:where) do |conditions|
        raise "unexpected conditions" unless conditions == { id: 42 }

        persistence_relation
      end
    end.new
    attachments_relation = Struct.new(:attachments, keyword_init: true) do
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
      :id,
      :mcp_server_snapshot,
      :persisted_snapshot,
      :updated_snapshot,
      :fake_model_class,
      keyword_init: true
    ) do
      def class
        fake_model_class
      end
    end.new(
      agent_run_marketplace_entries: attachments_relation,
      provider: provider,
      id: 42,
      agent_type: "codex",
      mcp_server_snapshot: [ { "name" => "base-server" } ],
      fake_model_class: fake_model_class
    )
  end

  def expect_stored_attachment_to_remain_unchanged(attachment)
    expect(attachment.rendered_payload).to include(
      "provider" => "claude",
      "payload" => include("name" => "repo-docs")
    )
    expect(attachment.to_h).not_to include(
      rendered_format: "codex_mcp_v1",
      rendered_payload: include("provider" => "codex")
    )
  end

  def expect_updated_snapshot(agent_run)
    expect(agent_run.fake_model_class.where(id: agent_run.id).updated_snapshot).to include(
      { "name" => "base-server" },
      include(
        "name" => "repo-docs",
        "marketplace_attachment" => true,
        "marketplace_entry_id" => 9,
        "marketplace_entry_version_id" => 11
      )
    )
    expect(agent_run.mcp_server_snapshot).to include(
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
