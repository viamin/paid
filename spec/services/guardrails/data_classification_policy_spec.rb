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

    it "warns for sensitive projects using a risky free model outside openrouter" do
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
        "data_classification" => "confidential",
        "provider_data_collection" => nil
      )
      expect(decision.outputs).to include("warning_emitted" => true)
    end

    it "does not warn for openrouter_sync models because provider routing denies data collection" do
      model.update!(catalog_source: "openrouter_sync")

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

    it "does not warn for restricted projects with openrouter_sync model" do
      project.update!(data_classification: "restricted")
      model.update!(catalog_source: "openrouter_sync")

      result = described_class.call(agent_run: agent_run, selection: selection)

      expect(result).not_to be_warning
      expect(result.provider_data_collection).to eq("deny")
    end

    context "when the run uses the openrouter_free runner with a non-openrouter_sync free model" do
      let(:openrouter_key) { create(:provider_api_key, user: project.created_by, api_service_type: "openrouter") }
      let(:openrouter_free_runner) do
        create(
          :runner,
          user: project.created_by,
          runner_key: "openrouter_free",
          auth_type: "api_key",
          provider_api_key: openrouter_key,
          tier_model_ids: LlmModel::TIERS.index_with { model.model_id }
        )
      end

      before { agent_run.update!(runner: openrouter_free_runner) }

      it "does not warn for confidential projects and records data_collection=deny" do
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

      it "records data_collection=allow for internal projects" do
        project.update!(data_classification: "internal")

        result = described_class.call(agent_run: agent_run, selection: selection)

        expect(result).not_to be_warning
        expect(result.provider_data_collection).to eq("allow")
      end
    end
  end
end
