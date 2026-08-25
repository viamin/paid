# frozen_string_literal: true

require "rails_helper"

require Rails.root.glob("db/migrate/*_sync_enhance_issue_structured_output_prompt.rb").sole

RSpec.describe SyncEnhanceIssueStructuredOutputPrompt, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access do
      Prompt.unscoped.where(slug: "goal.enhance_issue").destroy_all
    end
  end

  # @spec ISSUE-ENHANCEMENT-010
  it "promotes the structured-output contract for an existing global prompt" do
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")
    previous_version = prompt.create_version!(template: "post a comment directly", variables: [], created_by: "seed")

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)

    expect(prompt.current_version).not_to eq(previous_version)
    expect(prompt.current_version.template).to include("paid-enhance-issue-output")
    expect(prompt.current_version.template).not_to include("POST $GITHUB_API_URL")
    expect(prompt.current_version.template).not_to include("/issues/{{issue_number}}/comments")
    expect(prompt.current_version.created_by).to eq("migration")
  end

  # @spec ISSUE-ENHANCEMENT-010
  it "is idempotent when the expected prompt version is active" do
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")
    migration.up

    expect { migration.up }.not_to change { prompt.reload.prompt_versions.count }
  end
end
