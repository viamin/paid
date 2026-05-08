# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundle do
  it { is_expected.to belong_to(:account).optional }
  it { is_expected.to have_many(:bundle_outcomes).dependent(:destroy) }

  describe "#to_execution_config" do
    it "returns the bundle data in execution-ready sections" do
      bundle = build(:configuration_bundle)

      expect(bundle.to_execution_config).to eq(
        prompts: bundle.prompt_versions,
        models: bundle.model_preferences,
        orchestration: bundle.orchestration_config,
        thresholds: bundle.thresholds
      )
    end
  end

  it "rejects non-object JSON columns" do
    bundle = build(:configuration_bundle, thresholds: [])

    expect(bundle).not_to be_valid
    expect(bundle.errors[:thresholds]).to include("must be a JSON object")
  end
end
