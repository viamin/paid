# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::SurrogateOutcomeModel, :no_db do
  def build_row(goal:, agent_type:, quality_score:, experiment_features: {}, success: true,
                cost_cents: 40, duration_seconds: 120, weight: 1.0, objective_score: nil,
                provider_id: nil, prompt_version_id: nil, custom_prompt_sha256: nil,
                model_selection: nil, service_container_ids: [], mcp_servers: [])
    features = ConfigurationBundles::FeatureExtractor::FeatureVector.new(
      goal: goal,
      agent_type: agent_type,
      provider_id: provider_id,
      prompt_version_id: prompt_version_id,
      custom_prompt_sha256: custom_prompt_sha256,
      model_selection: model_selection,
      has_model_selection: model_selection.present?,
      has_custom_prompt: custom_prompt_sha256.present?,
      has_mcp_servers: mcp_servers.any?,
      service_container_ids: service_container_ids,
      mcp_servers: mcp_servers,
      service_container_count: service_container_ids.size,
      mcp_server_count: mcp_servers.size,
      experiment_features: experiment_features
    )
    objective_score ||= quality_score * 0.9
    ConfigurationBundles::TrainingDataset::Row.new(
      features: features,
      quality_score: quality_score,
      objective_score: objective_score,
      success: success,
      cost_cents: cost_cents,
      duration_seconds: duration_seconds,
      tokens_used: 5000,
      weight: weight
    )
  end

  def build_dataset(rows)
    ConfigurationBundles::TrainingDataset::Dataset.new(
      rows: rows,
      feature_names: rows.flat_map { |r| r.features.experiment_features.keys }.uniq.sort,
      size: rows.size
    )
  end

  def bundle_definition(goal: "create_pr", agent_type: "claude_code", experiments: {},
                        provider_id: nil, prompt_version_id: nil, custom_prompt_sha256: nil,
                        model_selection: nil, service_container_ids: [], mcp_servers: [])
    {
      "schema_version" => 1,
      "goal" => goal,
      "agent_type" => agent_type,
      "provider_id" => provider_id,
      "prompt_version_id" => prompt_version_id,
      "custom_prompt_sha256" => custom_prompt_sha256,
      "model_selection" => model_selection,
      "service_container_ids" => service_container_ids,
      "mcp_servers" => mcp_servers,
      "experiments" => experiments
    }
  end

  def section_order_experiment(*sections)
    { "knowledge.section_order" => { "value" => sections } }
  end

  def openai_bundle_identity
    {
      provider_id: "openai",
      prompt_version_id: "prompt-v1",
      model_selection: { "provider" => "openai", "model" => "gpt-5" },
      service_container_ids: [ 1, 2 ],
      mcp_servers: [ { "name" => "filesystem", "transport" => "stdio" } ]
    }
  end

  def anthropic_bundle_identity
    {
      provider_id: "anthropic",
      prompt_version_id: "prompt-v2",
      model_selection: { "provider" => "anthropic", "model" => "claude-sonnet" },
      service_container_ids: [ 9 ],
      mcp_servers: [ { "name" => "github", "transport" => "http" } ]
    }
  end

  describe ".train" do
    it "stores global statistics from the training dataset" do
      rows = [
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.8, success: true),
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.6, success: false)
      ]
      dataset = build_dataset(rows)

      model = described_class.train(dataset: dataset)

      expect(model).to be_trained
      expect(model.trained_state.training_size).to eq(2)
      expect(model.trained_state.global_mean_quality).to be_within(0.001).of(0.7)
      expect(model.trained_state.global_success_rate).to eq(0.5)
      expect(model.trained_state.trained_at).to be_within(1.second).of(Time.current)
    end

    it "handles an empty training dataset" do
      dataset = build_dataset([])

      model = described_class.train(dataset: dataset)

      expect(model).not_to be_trained
      expect(model.trained_state.training_size).to eq(0)
      expect(model.trained_state.global_mean_objective).to be_nil
    end

    it "computes weighted means respecting row weights" do
      rows = [
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.9, weight: 3.0),
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.5, weight: 1.0)
      ]
      dataset = build_dataset(rows)

      model = described_class.train(dataset: dataset)

      expect(model.trained_state.global_mean_quality).to be_within(0.001).of(0.8)
    end
  end

  describe "#predict" do
    it "returns prior prediction when model is not trained" do
      model = described_class.new

      prediction = model.predict(bundle_definition: bundle_definition)

      expect(prediction.predicted_objective_score).to eq(described_class::PRIOR_MEAN)
      expect(prediction.predicted_quality_score).to eq(described_class::PRIOR_MEAN)
      expect(prediction.uncertainty).to eq(1.0)
      expect(prediction.sample_count).to eq(0.0)
      expect(prediction.trained_at).to be_nil
    end

    it "returns global baseline when no historical rows match the query goal" do
      rows = [
        build_row(goal: "review", agent_type: "claude_code", quality_score: 0.9, success: true)
      ]
      dataset = build_dataset(rows)
      model = described_class.train(dataset: dataset)

      prediction = model.predict(bundle_definition: bundle_definition(goal: "create_pr"))

      expect(prediction.predicted_quality_score).to be_within(0.001).of(0.9)
      expect(prediction.predicted_success_probability).to eq(1.0)
      expect(prediction.sample_count).to eq(0.0)
    end

    it "predicts higher quality for definitions matching historical high-quality outcomes" do
      rows = [
        build_row(
          goal: "create_pr", agent_type: "claude_code", quality_score: 0.95, success: true,
          experiment_features: { "knowledge.token_budget" => 8000.0 }
        ),
        build_row(
          goal: "create_pr", agent_type: "claude_code", quality_score: 0.60, success: false,
          experiment_features: { "knowledge.token_budget" => 2000.0 }
        )
      ]
      dataset = build_dataset(rows)
      model = described_class.train(dataset: dataset)

      high_budget_prediction = model.predict(
        bundle_definition: bundle_definition(experiments: { "knowledge.token_budget" => { "value" => 8000 } })
      )
      low_budget_prediction = model.predict(
        bundle_definition: bundle_definition(experiments: { "knowledge.token_budget" => { "value" => 2000 } })
      )

      expect(high_budget_prediction.predicted_quality_score).to be > low_budget_prediction.predicted_quality_score
    end

    it "distinguishes structured experiment variants with different values" do
      rows = [
        build_row(
          goal: "create_pr", agent_type: "claude_code", quality_score: 0.95, success: true,
          experiment_features: { "knowledge.section_order" => "[\"summary\",\"tests\",\"implementation\"]" }
        ),
        build_row(
          goal: "create_pr", agent_type: "claude_code", quality_score: 0.55, success: false,
          experiment_features: { "knowledge.section_order" => "[\"implementation\",\"summary\",\"tests\"]" }
        )
      ]
      dataset = build_dataset(rows)
      model = described_class.train(dataset: dataset)

      preferred_prediction = model.predict(
        bundle_definition: bundle_definition(experiments: section_order_experiment("summary", "tests", "implementation"))
      )
      alternate_prediction = model.predict(
        bundle_definition: bundle_definition(experiments: section_order_experiment("implementation", "summary", "tests"))
      )

      expect(preferred_prediction.predicted_quality_score).to be > alternate_prediction.predicted_quality_score
    end

    it "applies Bayesian prior smoothing to predictions" do
      rows = [
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 1.0, success: true, weight: 1.0)
      ]
      dataset = build_dataset(rows)
      model = described_class.train(dataset: dataset)

      prediction = model.predict(
        bundle_definition: bundle_definition(experiments: { "knowledge.token_budget" => { "value" => 8000 } })
      )

      expect(prediction.predicted_quality_score).to be < 1.0
      expect(prediction.predicted_quality_score).to be > described_class::PRIOR_MEAN
    end

    it "reduces uncertainty with more matching outcomes" do
      few_rows = Array.new(2) do
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.8, success: true, weight: 1.0)
      end
      many_rows = Array.new(20) do
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.8, success: true, weight: 1.0)
      end

      few_model = described_class.train(dataset: build_dataset(few_rows))
      many_model = described_class.train(dataset: build_dataset(many_rows))

      definition = bundle_definition

      few_uncertainty = few_model.predict(bundle_definition: definition).uncertainty
      many_uncertainty = many_model.predict(bundle_definition: definition).uncertainty

      expect(many_uncertainty).to be < few_uncertainty
    end

    it "estimates cost and duration from weighted matches" do
      rows = [
        build_row(
          goal: "create_pr", agent_type: "claude_code", quality_score: 0.8,
          cost_cents: 100, duration_seconds: 300, weight: 2.0
        ),
        build_row(
          goal: "create_pr", agent_type: "claude_code", quality_score: 0.8,
          cost_cents: 200, duration_seconds: 600, weight: 1.0
        )
      ]
      dataset = build_dataset(rows)
      model = described_class.train(dataset: dataset)

      prediction = model.predict(bundle_definition: bundle_definition)

      expect(prediction.predicted_cost_cents).to be_within(1).of(133)
      expect(prediction.predicted_duration_seconds).to be_within(1).of(400)
    end

    it "preserves zero-valued cost and duration estimates" do
      rows = [
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.8,
                  cost_cents: 0, duration_seconds: 0)
      ]
      dataset = build_dataset(rows)
      model = described_class.train(dataset: dataset)

      prediction = model.predict(bundle_definition: bundle_definition)

      expect(prediction.predicted_cost_cents).to eq(0)
      expect(prediction.predicted_duration_seconds).to eq(0)
    end

    it "predicts success probability from historical outcomes" do
      rows = Array.new(8) do |i|
        build_row(
          goal: "create_pr", agent_type: "claude_code",
          quality_score: 0.8, success: i < 6
        )
      end
      dataset = build_dataset(rows)
      model = described_class.train(dataset: dataset)

      prediction = model.predict(bundle_definition: bundle_definition)

      expect(prediction.predicted_success_probability).to be_within(0.05).of(0.75)
    end

    it "penalizes mismatched agent types within the same goal" do
      rows = [
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.9, success: true),
        build_row(goal: "create_pr", agent_type: "cursor", quality_score: 0.5, success: true)
      ]
      dataset = build_dataset(rows)
      model = described_class.train(dataset: dataset)

      claude_prediction = model.predict(
        bundle_definition: bundle_definition(agent_type: "claude_code")
      )
      cursor_prediction = model.predict(
        bundle_definition: bundle_definition(agent_type: "cursor")
      )

      expect(claude_prediction.predicted_quality_score).to be > cursor_prediction.predicted_quality_score
    end

    it "does not mix histories across different providers or sidecar definitions" do
      rows = [
        build_row(
          goal: "create_pr", agent_type: "claude_code", quality_score: 0.95, success: true,
          **openai_bundle_identity
        ),
        build_row(
          goal: "create_pr", agent_type: "claude_code", quality_score: 0.2, success: false,
          **anthropic_bundle_identity
        )
      ]
      model = described_class.train(dataset: build_dataset(rows))

      openai_prediction = model.predict(
        bundle_definition: bundle_definition(**openai_bundle_identity.merge(service_container_ids: [ 2, 1 ]))
      )
      anthropic_prediction = model.predict(
        bundle_definition: bundle_definition(**anthropic_bundle_identity)
      )

      expect(openai_prediction.predicted_quality_score).to be > anthropic_prediction.predicted_quality_score
      expect(openai_prediction.predicted_quality_score).to be > 0.7
      expect(anthropic_prediction.predicted_quality_score).to be < 0.5
    end

    it "can be retrained with new data" do
      initial_rows = [
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.5, success: true)
      ]
      model = described_class.train(dataset: build_dataset(initial_rows))

      first_prediction = model.predict(bundle_definition: bundle_definition)

      updated_rows = [
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.95, success: true)
      ]
      model.train(dataset: build_dataset(updated_rows))

      second_prediction = model.predict(bundle_definition: bundle_definition)

      expect(second_prediction.predicted_quality_score).to be > first_prediction.predicted_quality_score
      expect(second_prediction.trained_at).to be >= first_prediction.trained_at
    end
  end

  describe ".call (class method shortcut)" do
    it "predicts using a pre-trained state" do
      rows = [
        build_row(goal: "create_pr", agent_type: "claude_code", quality_score: 0.85, success: true)
      ]
      model = described_class.train(dataset: build_dataset(rows))

      prediction = described_class.call(
        bundle_definition: bundle_definition,
        trained_state: model.trained_state
      )

      expect(prediction.predicted_quality_score).to be > 0.0
      expect(prediction.trained_at).to be_present
    end
  end
end
