# frozen_string_literal: true

require "rails_helper"

require Rails.root.join("db/migrate/20260916153929_sync_enhance_issue_prompt_simplified_english")

RSpec.describe SyncEnhanceIssuePromptSimplifiedEnglish, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access do
      Prompt.unscoped.where(slug: described_class::PROMPT_SLUG).destroy_all
    end
  end

  # @spec ISSUE-ENHANCEMENT-001
  it "promotes the simplified-technical-English template for an existing global prompt" do
    prompt = create(:prompt, :global, slug: described_class::PROMPT_SLUG, name: "Goal: Enhance Issue")
    previous_version = prompt.create_version!(
      template: "old template without simplified-English guidance",
      variables: [],
      created_by: "seed"
    )

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)

    expect(prompt.current_version).not_to eq(previous_version)
    expect(prompt.current_version.template).to include("Write the comment in simplified technical English.")
    expect(prompt.current_version.template).to include("Use short sentences.")
    expect(prompt.current_version.template).to include("One idea per sentence.")
    expect(prompt.current_version.template).to include("Do not stack jargon.")
    expect(prompt.current_version.created_by).to eq("migration")
    expect(prompt.current_version.change_notes).to eq(described_class::CHANGE_NOTES)
  end

  it "is idempotent when the expected prompt version is active" do
    prompt = create(:prompt, :global, slug: described_class::PROMPT_SLUG, name: "Goal: Enhance Issue")
    migration.up

    expect { migration.up }.not_to change { prompt.reload.prompt_versions.count }
  end

  it "is a no-op when the global prompt does not exist" do
    expect { migration.up }.not_to raise_error
  end
end
