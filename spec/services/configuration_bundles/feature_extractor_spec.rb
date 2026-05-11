# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::FeatureExtractor, :no_db do
  describe ".call" do
    it "extracts categorical features from a bundle definition" do
      definition = {
        "schema_version" => 1,
        "goal" => "create_pr",
        "agent_type" => "claude_code",
        "provider_id" => "openai",
        "prompt_version_id" => "pv_123",
        "custom_prompt_sha256" => "abc123"
      }

      features = described_class.call(definition)

      expect(features.goal).to eq("create_pr")
      expect(features.agent_type).to eq("claude_code")
      expect(features.provider_id).to eq("openai")
      expect(features.prompt_version_id).to eq("pv_123")
      expect(features.custom_prompt_sha256).to eq("abc123")
    end

    it "detects the presence of a model selection" do
      with_model = { "model_selection" => { "llm_model_id" => "gpt-4" } }
      without_model = { "model_selection" => nil }

      expect(described_class.call(with_model).has_model_selection).to be(true)
      expect(described_class.call(without_model).has_model_selection).to be(false)
    end

    it "preserves canonicalized model selection and exact sidecar definitions" do
      definition = {
        "model_selection" => { "provider" => "openai", "model" => "gpt-5" },
        "service_container_ids" => [ 3, 1, 2 ],
        "mcp_servers" => [
          { "config" => { "path" => "/tmp/z", "mode" => "read" }, "name" => "zeta" },
          { "name" => "alpha", "config" => { "mode" => "write", "path" => "/tmp/a" } }
        ]
      }

      features = described_class.call(definition)

      expect(features.model_selection).to eq({ "model" => "gpt-5", "provider" => "openai" })
      expect(features.service_container_ids).to eq([ 1, 2, 3 ])
      expect(features.mcp_servers).to eq([
        { "config" => { "mode" => "read", "path" => "/tmp/z" }, "name" => "zeta" },
        { "config" => { "mode" => "write", "path" => "/tmp/a" }, "name" => "alpha" }
      ])
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

    it "drops non-hash MCP server snapshots while preserving canonical ordering" do
      definition = {
        "mcp_servers" => [
          "invalid",
          { "name" => "zeta", "config" => { "path" => "/tmp/z", "mode" => "read" } },
          { "config" => { "mode" => "write", "path" => "/tmp/a" }, "name" => "alpha" }
        ]
      }

      features = described_class.call(definition)

      expect(features.mcp_servers).to eq([
        { "config" => { "mode" => "read", "path" => "/tmp/z" }, "name" => "zeta" },
        { "config" => { "mode" => "write", "path" => "/tmp/a" }, "name" => "alpha" }
      ])
      expect(features.has_mcp_servers).to be(true)
      expect(features.mcp_server_count).to eq(2)
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

    it "preserves non-numeric scalar experiment values" do
      definition = {
        "experiments" => {
          "bad_key" => { "value" => "not-a-number" }
        }
      }

      features = described_class.call(definition)

      expect(features.experiment_features).to eq("bad_key" => "not-a-number")
    end

    it "handles raw numeric experiment values" do
      definition = { "experiments" => { "numeric_key" => 4000 } }

      features = described_class.call(definition)

      expect(features.experiment_features).to eq("numeric_key" => 4000.0)
    end

    it "stably encodes structured experiment values" do
      definition = {
        "experiments" => {
          "knowledge.section_order" => { "value" => [ "summary", "tests", "implementation" ] }
        }
      }

      features = described_class.call(definition)

      expect(features.experiment_features).to eq(
        "knowledge.section_order" => "[\"summary\",\"tests\",\"implementation\"]"
      )
    end

    it "returns an empty experiments hash when none are defined" do
      features = described_class.call({ "goal" => "create_pr" })

      expect(features.experiment_features).to eq({})
    end
  end
end
