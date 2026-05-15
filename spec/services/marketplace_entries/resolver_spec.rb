# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::Resolver do
  it "scopes persisted manual opt-in to the effective consent owner" do
    owner_one, owner_two, project_one, project_two = build_projects_with_distinct_owners
    entry = create_automatic_entry_for(project_one.account)
    opted_in_run = create_opted_in_run(project: project_one, entry: entry)
    other_run = create(:agent_run, project: project_two, custom_prompt: "Implement the issue")

    owner_one_results = described_class.call(
      project: project_one,
      agent_run: opted_in_run,
      auto_attach_enabled: true,
      consent_owner_id: owner_one.id
    )
    owner_two_results = described_class.call(
      project: project_two,
      agent_run: other_run,
      auto_attach_enabled: true,
      consent_owner_id: owner_two.id
    )

    expect(owner_one_results.map(&:entry)).to eq([ entry ])
    expect(owner_two_results).to be_empty
  end

  def build_projects_with_distinct_owners
    account = create(:account)
    owner_one = create(:user, account: account)
    owner_two = create(:user, account: account)
    token_one = create(:github_token, account: account, created_by: owner_one)
    token_two = create(:github_token, account: account, created_by: owner_two)
    project_one = create(:project, account: account, created_by: owner_one, github_token: token_one)
    project_two = create(:project, account: account, created_by: owner_two, github_token: token_two)
    [ owner_one, owner_two, project_one, project_two ]
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

  def create_opted_in_run(project:, entry:)
    run = create(:agent_run, project: project, custom_prompt: "Implement the issue")
    create(:agent_run_marketplace_entry,
      agent_run: run,
      marketplace_entry: entry,
      marketplace_entry_version: entry.current_version,
      attachment_source: "manual")
    run
  end
end
