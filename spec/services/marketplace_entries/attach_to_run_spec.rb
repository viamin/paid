# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::AttachToRun do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project, custom_prompt: "Implement the issue") }

  def create_entry(name:, rule_mode: nil, conditions: {}, content:, renderers: {})
    entry = create(:marketplace_entry, account: project.account, name:)
    version = create(:marketplace_entry_version,
      marketplace_entry: entry,
      canonical_artifact: {
        "attachment_strategy" => "prompt_append",
        "content" => content
      },
      renderers: renderers,
      compatibility_constraints: {})
    entry.update!(current_version: version)
    create(:marketplace_entry_rule, marketplace_entry: entry, mode: rule_mode, conditions:) if rule_mode
    entry
  end

  it "attaches automatic, team default, and manual entries" do
    automatic, team_default, manual = create_attachment_mix

    attachments = described_class.call(
      agent_run:,
      manual_entry_ids: [ automatic.id, manual.id ],
      auto_attach_enabled: true,
      account_auto_attach_required: true
    )

    expect(attachments.map(&:marketplace_entry)).to eq([ automatic, team_default, manual ])
    expect(attachments.map(&:attachment_source)).to eq([ "manual", "team_default", "manual" ])
    expect(attachments.last.rendered_format).to eq("claude_skill_v1")
  end

  it "upgrades to manual when the user explicitly selects an entry that also matches automatic rules" do
    entry = create_entry(
      name: "Shared skill",
      rule_mode: "automatic",
      conditions: { "goals" => [ "create_pr" ] },
      content: "Automatic instructions"
    )
    create(:marketplace_entry_rule, marketplace_entry: entry, mode: "team_default", conditions: {})

    attachments = described_class.call(agent_run:, manual_entry_ids: [ entry.id ], auto_attach_enabled: true)

    expect(attachments.size).to eq(1)
    expect(attachments.first.marketplace_entry).to eq(entry)
    expect(attachments.first.attachment_source).to eq("manual")
    expect(attachments.first.selection_reason).to eq("Selected manually for this run")
  end

  it "attaches runtime-config marketplace entries and preserves the rendered payload" do
    entry = create(:marketplace_entry, account: project.account, name: "Build plugin", entry_type: "plugin")
    version = create(:marketplace_entry_version,
      marketplace_entry: entry,
      canonical_artifact: {
        "attachment_strategy" => "runtime_config",
        "env" => { "MARKETPLACE_PLUGIN_FLAG" => "enabled" },
        "files" => [ { "path" => "~/.config/paid/plugin.json", "content" => "{\"enabled\":true}" } ]
      },
      compatibility_constraints: {})
    entry.update!(current_version: version)

    attachments = described_class.call(agent_run:, manual_entry_ids: [ entry.id ])

    expect(attachments.size).to eq(1)
    expect(attachments.first.marketplace_entry).to eq(entry)
    expect(attachments.first.rendered_payload.dig("payload", "env")).to eq("MARKETPLACE_PLUGIN_FLAG" => "enabled")
  end

  it "does not attach automatic or team default entries when automatic attachment is disabled" do
    create_entry(
      name: "Automatic skill",
      rule_mode: "automatic",
      conditions: { "goals" => [ "create_pr" ] },
      content: "Automatic instructions"
    )
    create_entry(
      name: "Team default skill",
      rule_mode: "team_default",
      conditions: {},
      content: "Team default instructions"
    )

    attachments = described_class.call(agent_run:)

    expect(attachments).to be_empty
  end

  it "attaches automatic and team-default entries when the user has enabled automatic attachment" do
    automatic = create_entry(
      name: "Automatic skill",
      rule_mode: "automatic",
      conditions: { "goals" => [ "create_pr" ] },
      content: "Automatic instructions"
    )
    team_default = create_entry(
      name: "Team default skill",
      rule_mode: "team_default",
      conditions: {},
      content: "Team default instructions"
    )

    attachments = described_class.call(agent_run:, auto_attach_enabled: true)

    expect(attachments.map(&:marketplace_entry)).to eq([ automatic, team_default ])
    expect(attachments.map(&:attachment_source)).to eq([ "automatic", "team_default" ])
  end

  it "does not add unrelated team-default entries when the user manually selected a marketplace entry" do
    automatic = create_entry(
      name: "Automatic skill",
      rule_mode: "automatic",
      conditions: { "goals" => [ "create_pr" ] },
      content: "Automatic instructions"
    )
    create_entry(
      name: "Team default skill",
      rule_mode: "team_default",
      conditions: {},
      content: "Team default instructions"
    )
    manual = create_entry(name: "Manual skill", content: "Manual instructions")

    attachments = described_class.call(
      agent_run:,
      manual_entry_ids: [ manual.id ],
      auto_attach_enabled: true
    )

    expect(attachments.map(&:marketplace_entry)).to eq([ automatic, manual ])
    expect(attachments.map(&:attachment_source)).to eq([ "automatic", "manual" ])
  end

  it "attaches account-required automatic and team-default entries without manual selection" do
    automatic = create_entry(
      name: "Automatic skill",
      rule_mode: "automatic",
      conditions: { "goals" => [ "create_pr" ] },
      content: "Automatic instructions"
    )
    team_default = create_entry(
      name: "Team default skill",
      rule_mode: "team_default",
      conditions: {},
      content: "Team default instructions"
    )

    attachments = described_class.call(agent_run:, account_auto_attach_required: true)

    expect(attachments.map(&:marketplace_entry)).to eq([ automatic, team_default ])
    expect(attachments.map(&:attachment_source)).to eq([ "automatic", "team_default" ])
  end

  it "does not treat a manual selection as consent for unrelated automatic or team-default entries" do
    create_entry(
      name: "Automatic skill",
      rule_mode: "automatic",
      conditions: { "goals" => [ "create_pr" ] },
      content: "Automatic instructions"
    )
    manual = create_entry(name: "Manual skill", content: "Manual instructions")

    attachments = described_class.call(agent_run:, manual_entry_ids: [ manual.id ])

    expect(attachments.map(&:marketplace_entry)).to eq([ manual ])
    expect(attachments.map(&:attachment_source)).to eq([ "manual" ])
  end

  it "injects prompt-append attachments into the effective prompt" do
    manual = create_entry(name: "Manual skill", content: "Always run bundle exec rubocop first.")

    described_class.call(agent_run:, manual_entry_ids: [ manual.id ])

    expect(agent_run.effective_prompt).to include("Marketplace Attachments")
    expect(agent_run.effective_prompt).to include("Always run bundle exec rubocop first.")
  end

  it "merges attached marketplace MCP servers into the run snapshot" do
    entry = create_mcp_entry

    described_class.call(agent_run:, manual_entry_ids: [ entry.id ])

    expect(agent_run.reload.mcp_server_snapshot).to include(
      include(
        "name" => "repo-docs",
        "install_type" => "npx",
        "marketplace_attachment" => true,
        "marketplace_entry_id" => entry.id
      )
    )
  end

  def create_manual_entry
    create_entry(
      name: "Manual skill",
      content: "Manual instructions",
      renderers: {
        "claude" => {
          "attachment_strategy" => "prompt_append",
          "provider_format" => "claude_skill_v1",
          "content" => "Provider-native manual instructions"
        }
      }
    )
  end

  def create_attachment_mix
    automatic = create_entry(
      name: "Automatic skill",
      rule_mode: "automatic",
      conditions: { "goals" => [ "create_pr" ] },
      content: "Automatic instructions"
    )
    team_default = create_entry(
      name: "Team default skill",
      rule_mode: "team_default",
      conditions: {},
      content: "Team default instructions"
    )

    [ automatic, team_default, create_manual_entry ]
  end

  def create_mcp_entry
    entry = create(:marketplace_entry, account: project.account, name: "Repo MCP", entry_type: "mcp_server")
    version = create(:marketplace_entry_version,
      marketplace_entry: entry,
      canonical_artifact: {
        "attachment_strategy" => "mcp_server",
        "name" => "repo-docs",
        "install_type" => "npx",
        "command" => "npx",
        "args" => [ "-y", "@acme/repo-docs-mcp" ]
      },
      compatibility_constraints: {})
    entry.update!(current_version: version)
    entry
  end
end
