# frozen_string_literal: true

require "rails_helper"

RSpec.describe Guardrails::DataClassificationPolicy do
  describe ".call" do
    let(:project) { create(:project, data_classification: data_classification) }
    let(:agent_run) { create(:agent_run, project: project) }
    let(:model) do
      create(:llm_model, model_id: "free-model", pricing_tier: "free", data_training_risk: "possible")
    end
    let(:selection) do
      {
        model: model,
        selector_type: "rules",
        reasoning: "Selected by rules"
      }
    end
    let(:data_classification) { "confidential" }

    it "warns for sensitive projects using a risky free model outside openrouter_free" do
      result = described_class.call(agent_run: agent_run, selection: selection)

      expect(result).to be_warning
      expect(result.provider_data_collection).to be_nil

      log = agent_run.agent_run_logs.where(log_type: "system").order(:id).last
      expect(log.content).to include("Data classification warning")
      expect(log.metadata).to include(
        "type" => "data_classification_guardrail",
        "data_classification" => "confidential",
        "model_id" => "free-model"
      )

      decision = agent_run.orchestration_decisions.order(:id).last
      expect(decision.decision_type).to eq("check_data_classification")
      expect(decision.actor).to eq("data_classification_policy")
      expect(decision.context).to include(
        "decision_status" => "applied",
        "data_classification" => "confidential"
      )
      expect(decision.outputs).to include("warning_emitted" => true)
    end

    it "does not warn for openrouter_free because provider routing denies data collection" do
      allow(agent_run).to receive(:effective_runner).and_return("openrouter_free")

      result = described_class.call(agent_run: agent_run, selection: selection)

      expect(result).not_to be_warning
      expect(result.provider_data_collection).to eq("deny")
      expect(agent_run.agent_run_logs.where(log_type: "system")).to be_empty

      decision = agent_run.orchestration_decisions.order(:id).last
      expect(decision.context).to include(
        "decision_status" => "noop",
        "data_classification" => "confidential",
        "provider_data_collection" => "deny"
      )
    end

    it "does not warn for internal projects" do
      project.update!(data_classification: "internal")

      result = described_class.call(agent_run: agent_run, selection: selection)

      expect(result).not_to be_warning
    end

    it "does not warn for restricted projects routed through openrouter_free" do
      project.update!(data_classification: "restricted")
      allow(agent_run).to receive(:effective_runner).and_return("openrouter_free")

      result = described_class.call(agent_run: agent_run, selection: selection)

      expect(result).not_to be_warning
      expect(result.provider_data_collection).to eq("deny")
    end
  end
end
