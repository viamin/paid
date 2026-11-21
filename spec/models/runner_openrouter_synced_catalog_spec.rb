# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runner do
  let(:user) { create(:user) }
  let(:model) do
    create(:llm_model, :free, model_id: "google/acceptance-model:free", provider: "google",
      catalog_source: "openrouter_sync")
  end

  %w[opencode kilocode pi omp].each do |runner_key|
    context "with #{runner_key}" do
      let(:key) { create(:provider_api_key, user:, api_service_type: "openrouter") }
      let(:runner) do
        build(:runner, user:, runner_key:, auth_type: "api_key", provider_api_key: key,
          config: { runner_key => { "api_provider" => key.api_service_type, "model" => model.model_id } })
      end

      # @spec DIRECT-OUTBOUND-CATALOG-011 RUNNER-MODEL-OPTIONS-003
      it "saves the offered OpenRouter-synced model without replacing its vendor or catalog identity" do
        runner
        expect { runner.save! }.not_to change(LlmModel, :count)
        expect(runner.reload.config.dig(runner_key, "model")).to eq(model.model_id)
        expect(model.reload).to have_attributes(provider: "google", catalog_source: "openrouter_sync")
      end

      # @spec DIRECT-OUTBOUND-CATALOG-011
      it "still refuses a foreign-vendor row from a manual catalog" do
        model.update!(catalog_source: "manual")

        expect(runner).not_to be_valid
        expect(runner.errors[:config].join).to include("catalog but expected OpenRouter")
      end

      # @spec DIRECT-OUTBOUND-CATALOG-011
      it "does not treat OpenRouter sync as permission to use another provider's key" do
        key.update!(api_service_type: "anthropic")

        expect(runner).not_to be_valid
        expect(runner.errors[:config].join).to include("catalog but expected Anthropic")
      end
    end
  end
end
