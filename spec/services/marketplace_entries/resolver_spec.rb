# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::Resolver do
  it "attaches automatic entries without requiring historical manual selections" do
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
end
