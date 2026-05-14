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

  it "attaches automatic, team default, and manual entries in precedence order" do
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
    manual = create_manual_entry

    attachments = described_class.call(agent_run:, manual_entry_ids: [ manual.id ])

    expect(attachments.map(&:marketplace_entry)).to eq([ automatic, team_default, manual ])
    expect(attachments.map(&:attachment_source)).to eq(%w[automatic team_default manual])
    expect(attachments.last.rendered_format).to eq("claude_skill_v1")
  end

  it "injects prompt-append attachments into the effective prompt" do
    manual = create_entry(name: "Manual skill", content: "Always run bundle exec rubocop first.")

    described_class.call(agent_run:, manual_entry_ids: [ manual.id ])

    expect(agent_run.effective_prompt).to include("Marketplace Attachments")
    expect(agent_run.effective_prompt).to include("Always run bundle exec rubocop first.")
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
end
