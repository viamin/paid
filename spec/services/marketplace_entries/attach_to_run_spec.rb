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

  it "attaches manual, team default, and automatic entries" do
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
    manual = create_manual_entry

    attachments = described_class.call(agent_run:, manual_entry_ids: [ automatic.id, manual.id ], auto_attach_enabled: true, account_auto_attach_required: true)

    expect(attachments.map(&:marketplace_entry)).to contain_exactly(automatic, team_default, manual)
    expect(attachments.map(&:attachment_source)).to contain_exactly("automatic", "team_default", "manual")
    expect(attachments.last.rendered_format).to eq("claude_skill_v1")
  end

  it "preserves automatic precedence over later team-default and manual matches for the same entry" do
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
    expect(attachments.first.attachment_source).to eq("automatic")
    expect(attachments.first.selection_reason).to eq("Matched automatic marketplace rule")
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

  it "attaches automatic entries and still skips team-default entries unless the account requires them" do
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

    attachments = described_class.call(agent_run:, auto_attach_enabled: true)

    expect(attachments.map(&:marketplace_entry)).to eq([ automatic ])
    expect(attachments.map(&:attachment_source)).to eq([ "automatic" ])
  end

  it "attaches account-required team-default entries without manual selection" do
    team_default = create_entry(
      name: "Team default skill",
      rule_mode: "team_default",
      conditions: {},
      content: "Team default instructions"
    )

    attachments = described_class.call(agent_run:, account_auto_attach_required: true)

    expect(attachments.map(&:marketplace_entry)).to eq([ team_default ])
    expect(attachments.map(&:attachment_source)).to eq([ "team_default" ])
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
