# frozen_string_literal: true

require "rails_helper"

require Rails.root.glob("db/migrate/*_sync_create_feature_prompt_problem_framing.rb").sole

RSpec.describe SyncCreateFeaturePromptProblemFraming, :aggregate_failures do
  let(:migration) { described_class.new }
  let(:slug) { Prompts::BuildForCreateFeature::PROMPT_SLUG }

  before do
    TenantContext.with_system_access { Prompt.unscoped.where(slug:).destroy_all }
  end

  # @spec FEATURE-CREATION-006
  it "keeps the seed definition current after adding problem-framing guidance" do
    prompt = create(:prompt, :global, slug:)
    migration.up

    expect { load Rails.root.join("db/seeds/prompts.rb") }
      .not_to change { prompt.reload.prompt_versions.count }
  end
end
