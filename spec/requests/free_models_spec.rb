# frozen_string_literal: true

require "rails_helper"

RSpec.describe "FreeModels" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:high_free_attributes) do
    {
      model_id: "high-free",
      display_name: "High Free",
      provider: "deepseek",
      tier: "high",
      pricing_tier: "free",
      catalog_source: "openrouter_sync",
      capability_score: 9.1,
      supports_tools: true,
      data_training_risk: "possible",
      metadata: { "supported_parameters" => [ "reasoning" ] }
    }
  end
  let(:low_free_attributes) do
    {
      model_id: "low-free",
      display_name: "Low Free",
      provider: "qwen",
      tier: "low",
      pricing_tier: "free",
      catalog_source: "openrouter_sync",
      capability_score: 4.2,
      data_training_risk: "none",
      metadata: { "below_quality_bar" => true }
    }
  end

  before { sign_in user }

  describe "GET /free_models" do
    it "renders the free-model catalog by tier with project opt-outs" do
      create(:llm_model, high_free_attributes)
      create(:llm_model, low_free_attributes)

      get free_models_path(project_id: project.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Free Models")
      expect(response.body).to include("High Tier")
      expect(response.body).to include("Low Tier")
      expect(response.body).to include("High Free")
      expect(response.body).to include("Low Free")
      expect(response.body).to include("Training Risk: possible")
      expect(response.body).to include("Below Quality Bar")
      expect(response.body).to include("Save Project Preferences")
    end

    it "links a missing free-model runner to the free-policy OpenCode form" do
      get free_models_path(project_id: project.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ERB::Util.html_escape(new_runner_path(
        form_variant: "api_key",
        runner_key: "opencode",
        model_policy: Runners::ModelOptions::FREE_POLICY_VALUE
      )))
    end
  end

  describe "PATCH /free_models/project_preferences" do
    it "persists excluded free model ids on the selected project" do
      patch project_preferences_free_models_path, params: {
        project_id: project.id,
        project: {
          excluded_free_model_ids: [ "high-free", "low-free", "" ]
        }
      }

      expect(response).to redirect_to(free_models_path(project_id: project.id))
      expect(project.reload.model_preferences["excluded_free_model_ids"]).to eq(%w[high-free low-free])
    end
  end
end
