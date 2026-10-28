# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::EligibleModels do
  let(:user) { create(:user) }
  let(:provider_api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }
  let(:runner) do
    create(:runner, user: user, provider_api_key: provider_api_key, runner_key: "opencode", auth_type: "api_key",
      config: { "opencode" => { "model" => "vendor/eligible", "api_provider" => "openrouter" } })
  end

  it "returns only active advertised, runner-compatible tool models with catalog freshness" do # @spec FREE-MODEL-SYNC-013
    eligible = create(:llm_model, model_id: "vendor/eligible", provider: "openrouter", supports_tools: true,
      catalog_source: "openrouter_zdr_sync")
    create(:openrouter_zdr_model, model_id: eligible.model_id, active: true)
    rejected = create(:llm_model, model_id: "vendor/no-tools", provider: "openrouter", supports_tools: false,
      catalog_source: "openrouter_zdr_sync")
    create(:openrouter_zdr_model, model_id: rejected.model_id, active: true)

    result = described_class.call(runner: runner)

    expect(result.models).to include(eligible)
    expect(result.models).not_to include(rejected)
    expect(result.catalog_state).to be_a(OpenrouterZdrCatalogState)
  end
end
