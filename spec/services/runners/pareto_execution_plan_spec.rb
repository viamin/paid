# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::ParetoExecutionPlan do
  describe ".call" do
    let(:user) { create(:user) }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret") }
    let(:runner) do
      create(
        :runner,
        user: user,
        runner_key: "openrouter_pareto",
        auth_type: "api_key",
        provider_api_key: api_key
      )
    end

    it "uses the Pareto model identifier and OpenRouter base URL" do
      project = Struct.new(:data_classification).new("open")

      result = described_class.call(runner: runner, project: project)

      expect(result.config).to eq(
        model: "openrouter/pareto-code",
        base_url: "https://openrouter.ai/api/v1",
        api_key_env: "OPENROUTER_API_KEY",
        provider_routing: { data_collection: "allow" }
      )
    end

    it "treats nil classification as internal" do
      project = Struct.new(:data_classification).new(nil)

      result = described_class.call(runner: runner, project: project)

      expect(result.config.fetch(:provider_routing)).to eq(data_collection: "allow")
    end

    it "denies data collection for confidential projects" do
      project = Struct.new(:data_classification).new("confidential")

      result = described_class.call(runner: runner, project: project)

      expect(result.config.fetch(:provider_routing)).to eq(data_collection: "deny")
    end

    it "enables zdr for restricted projects" do
      project = Struct.new(:data_classification).new("restricted")

      result = described_class.call(runner: runner, project: project)

      expect(result.config.fetch(:provider_routing)).to eq(data_collection: "deny", zdr: true)
    end

    it "raises a service-type error when the runner is not OpenRouter-backed" do
      project = Struct.new(:data_classification).new("internal")
      allow(runner).to receive(:required_api_service_type).and_return("anthropic")

      expect do
        described_class.call(runner: runner, project: project)
      end.to raise_error(ArgumentError, /must use the OpenRouter API service type/)
    end
  end
end
