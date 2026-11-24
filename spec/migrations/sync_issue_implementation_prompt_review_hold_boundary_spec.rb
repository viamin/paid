# frozen_string_literal: true

require "rails_helper"

require Rails.root.glob("db/migrate/*_sync_issue_implementation_prompt_review_hold_boundary.rb").sole

RSpec.describe SyncIssueImplementationPromptReviewHoldBoundary, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access { Prompt.unscoped.where(slug: described_class::PROMPT_SLUG).destroy_all }
  end

  # @spec AUTO-MERGE-009
  it "promotes the explicit human-only decision boundary to the active issue prompt" do
    prompt = create(:prompt, :global, slug: described_class::PROMPT_SLUG)
    prompt.create_version!(template: "old {{title}}", variables: [], created_by: "seed")

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)
    expect(prompt.current_version.template).to include("specific unresolved human-only decision")
    expect(prompt.current_version.template).to include("screenshots or review")
    expect(prompt.current_version.template).to include("why normal delegated checks cannot settle it")
    expect(prompt.current_version).to have_attributes(
      created_by: "migration",
      change_notes: described_class::CHANGE_NOTES
    )
  end

  it "is a no-op when the persisted issue prompt already has the boundary" do
    prompt = create(:prompt, :global, slug: described_class::PROMPT_SLUG)
    prompt.create_version!(template: described_class::TEMPLATE, variables: described_class::VARIABLES, created_by: "seed")

    expect { migration.up }.not_to change(PromptVersion, :count)
  end
end
