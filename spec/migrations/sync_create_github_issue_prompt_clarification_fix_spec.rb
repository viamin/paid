# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260512153000_sync_create_github_issue_prompt_clarification_fix")

RSpec.describe SyncCreateGithubIssuePromptClarificationFix, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    Prompt.unscoped.where(slug: described_class::PROMPT_SLUG).destroy_all
  end

  it "promotes the updated template for the persisted global prompt" do
    prompt = create(
      :prompt,
      :global,
      :planning,
      slug: described_class::PROMPT_SLUG,
      name: "Goal: Create GitHub Issue"
    )
    previous_version = prompt.create_version!(
      template: "old {{base_prompt}}",
      variables: [ { "name" => "base_prompt" } ],
      created_by: "seed"
    )

    expect {
      migration.up
    }.to change { prompt.reload.prompt_versions.count }.by(1)

    expect(prompt.reload.current_version).not_to eq(previous_version)
    expect(prompt.current_version.template).to eq(described_class::TEMPLATE)
    expect(prompt.current_version.variables).to eq(described_class::VARIABLES)
    expect(prompt.current_version.created_by).to eq("migration")
    expect(prompt.current_version.change_notes).to eq(described_class::CHANGE_NOTES)
  end

  it "is a no-op when the prompt is already synced" do
    prompt = create(
      :prompt,
      :global,
      :planning,
      slug: described_class::PROMPT_SLUG,
      name: "Goal: Create GitHub Issue"
    )
    prompt.create_version!(
      template: described_class::TEMPLATE,
      variables: described_class::VARIABLES,
      created_by: "seed"
    )

    expect {
      migration.up
    }.not_to change(PromptVersion, :count)
  end

  it "is a no-op when the global prompt does not exist" do
    expect { migration.up }.not_to raise_error
  end

  it "creates the synced current version when the prompt exists without one" do
    prompt = create(
      :prompt,
      :global,
      :planning,
      slug: described_class::PROMPT_SLUG,
      name: "Goal: Create GitHub Issue"
    )

    expect(prompt.current_version).to be_nil

    expect {
      migration.up
    }.to change { prompt.reload.prompt_versions.count }.by(1)

    expect(prompt.reload.current_version.template).to eq(described_class::TEMPLATE)
    expect(prompt.current_version.variables).to eq(described_class::VARIABLES)
    expect(prompt.current_version.created_by).to eq("migration")
  end
end
