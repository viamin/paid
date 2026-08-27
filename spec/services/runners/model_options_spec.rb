# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::ModelOptions do
  describe ".call" do
    it "includes the free policy option only for opencode + openrouter" do
      create(:llm_model, provider: "openrouter")

      result = described_class.call(runner_key: "opencode", api_service_type: "openrouter")

      expect(result.options.first).to include(value: described_class::FREE_POLICY_OPTION, kind: "free_policy")
    end

    it "omits the free policy option for other runner keys and service types" do
      create(:llm_model, provider: "anthropic")

      result = described_class.call(runner_key: "pi", api_service_type: "anthropic")

      expect(result.options.map { |option| option[:kind] }).not_to include("free_policy")
    end

    it "lists active catalog models for the service type and always appends a custom option" do
      model = create(:llm_model, provider: "anthropic", display_name: "Claude Test")
      create(:llm_model, :inactive, provider: "anthropic")

      result = described_class.call(runner_key: "kilocode", api_service_type: "anthropic")

      catalog_values = result.options.select { |option| option[:kind] == "catalog" }.map { |option| option[:value] }
      expect(catalog_values).to contain_exactly(model.model_id)
      expect(result.options.last).to include(value: LlmModel::CUSTOM_MODEL_OPTION, kind: "custom")
    end

    it "excludes models Runners::ModelCompatibility marks unsupported" do
      model = create(:llm_model, provider: "openai")
      allow(Runners::ModelCompatibility).to receive(:call).and_call_original
      allow(Runners::ModelCompatibility).to receive(:call)
        .with(runner_key: "pi", model_id: model.model_id, auth_type: "api_key")
        .and_return(Runners::ModelCompatibility::Result.new(supported: false, reason: "nope"))

      result = described_class.call(runner_key: "pi", api_service_type: "openai")

      expect(result.options.map { |option| option[:value] }).not_to include(model.model_id)
    end

    context "when catalog_cache and compatibility_cache are shared across calls" do
      it "queries the catalog once per service type and checks compatibility once per (runner_key, model_id)" do
        model = create(:llm_model, provider: "anthropic")
        catalog_cache = {}
        compatibility_cache = {}
        expect(LlmModel).to receive(:dropdown_options_for).once.and_call_original
        expect(Runners::ModelCompatibility).to receive(:call).once.and_call_original

        2.times do
          described_class.call(
            runner_key: "pi",
            api_service_type: "anthropic",
            catalog_cache: catalog_cache,
            compatibility_cache: compatibility_cache
          )
        end

        expect(catalog_cache["anthropic"].map(&:model_id)).to contain_exactly(model.model_id)
      end

      it "does not share compatibility results across different runner keys" do
        model = create(:llm_model, provider: "anthropic")
        compatibility_cache = {}

        described_class.call(runner_key: "pi", api_service_type: "anthropic", compatibility_cache: compatibility_cache)
        described_class.call(runner_key: "omp", api_service_type: "anthropic", compatibility_cache: compatibility_cache)

        expect(compatibility_cache.keys).to contain_exactly(
          [ "pi", model.model_id, "api_key" ],
          [ "omp", model.model_id, "api_key" ]
        )
      end
    end
  end
end
