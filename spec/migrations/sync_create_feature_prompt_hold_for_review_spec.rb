# frozen_string_literal: true

require "rails_helper"

require Rails.root.glob("db/migrate/*_sync_create_feature_prompt_hold_for_review.rb").sole

RSpec.describe SyncCreateFeaturePromptHoldForReview, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access { Prompt.unscoped.where(slug: described_class::PROMPT_SLUG).destroy_all }
  end

  # @spec AUTO-MERGE-009
  it "promotes review-hold instructions to the persisted create-feature prompt" do
    prompt = create(:prompt, :global, slug: described_class::PROMPT_SLUG)
    prompt.create_version!(template: "old {{project_name}}", variables: [], created_by: "seed")

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)
    expect(prompt.current_version.template).to include("paid-hold-review")
    expect(prompt.current_version.created_by).to eq("migration")
  end

  it "is a no-op when the persisted create-feature prompt is already current" do
    prompt = create(:prompt, :global, slug: described_class::PROMPT_SLUG)
    prompt.create_version!(
      template: Prompts::BuildForCreateFeature::FALLBACK_PROMPT,
      variables: described_class::VARIABLES,
      created_by: "seed"
    )

    expect { migration.up }.not_to change(PromptVersion, :count)
  end
end
