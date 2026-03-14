# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::RulesBasedSelector do
  describe ".call" do
    let(:agent_run) { create(:agent_run) }

    before do
      create(:llm_model, capability_score: 9.0, model_id: "best-model")
      create(:llm_model, capability_score: 5.0, model_id: "basic-model")
    end

    it "returns a result with a selected model" do
      result = described_class.call(agent_run: agent_run)

      expect(result).to be_present
      expect(result[:model]).to be_a(LlmModel)
      expect(result[:selector_type]).to eq("rules")
    end

    it "selects higher capability models for complex tasks" do
      agent_run.issue.update!(body: "A" * 5000)

      result = described_class.call(agent_run: agent_run)

      expect(result[:model].capability_score.to_f).to be >= 8.0
    end

    it "returns nil when no models are available" do
      LlmModel.destroy_all

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end
  end
end
