# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::FeatureExtractor, :no_db do
  describe ".call" do
    it "extracts categorical features from a bundle definition" do
      definition = {
        "schema_version" => 1,
        "goal" => "create_pr",
        "agent_type" => "claude_code"
      }

      features = described_class.call(definition)

      expect(features.goal).to eq("create_pr")
      expect(features.agent_type).to eq("claude_code")
    end

    it "detects the presence of a model selection" do
      with_model = { "model_selection" => { "llm_model_id" => "gpt-4" } }
      without_model = { "model_selection" => nil }

      expect(described_class.call(with_model).has_model_selection).to be(true)
      expect(described_class.call(without_model).has_model_selection).to be(false)
    end

    it "detects the presence of a custom prompt" do
      with_prompt = { "custom_prompt_sha256" => "abc123" }
      without_prompt = { "custom_prompt_sha256" => nil }

      expect(described_class.call(with_prompt).has_custom_prompt).to be(true)
      expect(described_class.call(without_prompt).has_custom_prompt).to be(false)
    end

    it "counts service containers and MCP servers" do
      definition = {
        "service_container_ids" => [ 1, 2, 3 ],
        "mcp_servers" => [ { "name" => "server1" }, { "name" => "server2" } ]
      }

      features = described_class.call(definition)

      expect(features.service_container_count).to eq(3)
      expect(features.mcp_server_count).to eq(2)
    end

    it "returns zero counts for missing arrays" do
      features = described_class.call({})

      expect(features.service_container_count).to eq(0)
      expect(features.mcp_server_count).to eq(0)
      expect(features.has_mcp_servers).to be(false)
    end

    it "extracts experiment features as numeric values" do
      definition = {
        "experiments" => {
          "knowledge.token_budget" => { "value" => 8000 },
          "some.other_key" => { "value" => 42.5 }
        }
      }

      features = described_class.call(definition)

      expect(features.experiment_features).to eq(
        "knowledge.token_budget" => 8000.0,
        "some.other_key" => 42.5
      )
    end

    it "falls back to variant ID when value key is absent" do
      definition = {
        "experiments" => {
          "knowledge.token_budget" => { "configuration_experiment_variant_id" => 99 }
        }
      }

      features = described_class.call(definition)

      expect(features.experiment_features).to eq("knowledge.token_budget" => 99.0)
    end

    it "returns 0.0 for non-numeric experiment values" do
      definition = {
        "experiments" => {
          "bad_key" => { "value" => "not-a-number" }
        }
      }

      features = described_class.call(definition)

      expect(features.experiment_features).to eq("bad_key" => 0.0)
    end

    it "handles raw numeric experiment values" do
      definition = { "experiments" => { "numeric_key" => 4000 } }

      features = described_class.call(definition)

      expect(features.experiment_features).to eq("numeric_key" => 4000.0)
    end

    it "returns an empty experiments hash when none are defined" do
      features = described_class.call({ "goal" => "create_pr" })

      expect(features.experiment_features).to eq({})
    end
  end
end
