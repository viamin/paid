# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::Resolver do
  it "attaches automatic entries for opted-in users when the rule matches" do
    project = create(:project)
    entry = create_automatic_entry_for(project.account)
    agent_run = create(:agent_run, project: project, custom_prompt: "Implement the issue")

    results = described_class.call(
      project: project,
      agent_run: agent_run,
      auto_attach_enabled: true
    )

    expect(results.map(&:entry)).to eq([ entry ])
    expect(results.map(&:source)).to eq([ "automatic" ])
  end

  it "upgrades to manual when the user also explicitly selects an automatically matched entry" do
    project = create(:project)
    entry = create_automatic_entry_for(project.account)
    agent_run = create(:agent_run, project: project, custom_prompt: "Implement the issue")

    results = described_class.call(
      project: project,
      agent_run: agent_run,
      manual_entry_ids: [ entry.id ],
      auto_attach_enabled: true
    )

    expect(results.map(&:entry)).to eq([ entry ])
    expect(results.map(&:source)).to eq([ "manual" ])
  end

  it "applies automatic entries when the account requires marketplace attachment" do
    project = create(:project)
    entry = create_automatic_entry_for(project.account)
    agent_run = create(:agent_run, project: project, custom_prompt: "Implement the issue")

    results = described_class.call(
      project: project,
      agent_run: agent_run,
      account_auto_attach_required: true
    )

    expect(results.map(&:entry)).to eq([ entry ])
    expect(results.map(&:source)).to eq([ "automatic" ])
  end

  it "prefers team-default over automatic when the same entry matches both rule modes" do
    project = create(:project)
    entry = create_automatic_entry_for(project.account)
    create(:marketplace_entry_rule, marketplace_entry: entry, mode: "team_default", conditions: {}, rationale: "Required by the team")
    agent_run = create(:agent_run, project: project, custom_prompt: "Implement the issue")

    results = described_class.call(
      project: project,
      agent_run: agent_run,
      auto_attach_enabled: true,
      account_auto_attach_required: true
    )

    expect(results.map(&:entry)).to eq([ entry ])
    expect(results.map(&:source)).to eq([ "team_default" ])
    expect(results.map(&:reason)).to eq([ "Required by the team" ])
  end

  it "fails closed when a manually selected entry is unavailable to the run" do
    project = create(:project)
    other_account_entry = create_automatic_entry_for(create(:account))
    agent_run = create(:agent_run, project: project, custom_prompt: "Implement the issue")

    expect {
      described_class.call(
        project: project,
        agent_run: agent_run,
        manual_entry_ids: [ other_account_entry.id ]
      )
    }.to raise_error(
      ActiveRecord::RecordNotFound,
      /Selected marketplace entries are unavailable or incompatible/
    )
  end

  it "preserves explicit manual selection order instead of candidate relation order" do
    project = create(:project)
    z_entry = create_manual_entry_for(project.account, name: "Zed skill")
    a_entry = create_manual_entry_for(project.account, name: "Alpha skill")
    agent_run = create(:agent_run, project: project, custom_prompt: "Implement the issue")

    results = described_class.call(
      project: project,
      agent_run: agent_run,
      manual_entry_ids: [ z_entry.id, a_entry.id ]
    )

    expect(results.map(&:entry)).to eq([ z_entry, a_entry ])
    expect(results.map(&:source)).to eq([ "manual", "manual" ])
  end

  it "preserves explicit manual selection order when one selected entry also matched an automatic rule" do
    project = create(:project)
    automatic_entry = create_automatic_entry_for(project.account)
    manual_entry = create_manual_entry_for(project.account, name: "Manual skill")
    agent_run = create(:agent_run, project: project, custom_prompt: "Implement the issue")

    results = described_class.call(
      project: project,
      agent_run: agent_run,
      manual_entry_ids: [ manual_entry.id, automatic_entry.id ],
      auto_attach_enabled: true
    )

    expect(results.map(&:entry)).to eq([ manual_entry, automatic_entry ])
    expect(results.map(&:source)).to eq([ "manual", "manual" ])
  end

  def create_automatic_entry_for(account)
    entry = create(:marketplace_entry, account: account, name: "Shared skill")
    version = create(:marketplace_entry_version,
      marketplace_entry: entry,
      canonical_artifact: {
        "attachment_strategy" => "prompt_append",
        "content" => "Follow the shared workflow."
      })
    entry.update!(current_version: version)
    create(:marketplace_entry_rule, marketplace_entry: entry, mode: "automatic", conditions: {})
    entry
  end

  def create_manual_entry_for(account, name:)
    entry = create(:marketplace_entry, account: account, name: name)
    version = create(:marketplace_entry_version,
      marketplace_entry: entry,
      canonical_artifact: {
        "attachment_strategy" => "prompt_append",
        "content" => "#{name} instructions"
      })
    entry.update!(current_version: version)
    entry
  end
end
