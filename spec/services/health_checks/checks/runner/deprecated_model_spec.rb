# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Runner::DeprecatedModel do
  let(:owner) { create(:user) }
  let(:provider_api_key) { create(:provider_api_key, user: owner, api_service_type: "anthropic") }
  let(:runner) do
    create(
      :runner,
      user: owner,
      runner_key: "cursor",
      auth_type: "api_key",
      provider_api_key: provider_api_key,
      tier_model_ids: { "mid" => "claude-retired" }
    )
  end

  let(:model) do
    create(
      :llm_model,
      model_id: "claude-retired",
      provider: "anthropic",
      tier: "mid"
    )
  end

  before { model }

  context "with a stubbed drift detector" do
    let(:drift_detector) { instance_double(Models::DetectCatalogDrift) }
    let(:deprecated_models) { [] }

    before do
      allow(Models::DetectCatalogDrift).to receive(:new).and_return(drift_detector)
      allow(drift_detector).to receive(:deprecated_models_for).with("anthropic").and_return(deprecated_models)
    end

    it "returns no findings when the resolved model is still present in the registry" do
      expect(described_class.call(runner)).to eq([])
    end

    context "when the resolved model has been dropped from the registry" do
      let(:deprecated_models) { [ "claude-retired" ] }

      # @spec HEALTH-CHECKS-005
      it "returns a warning" do
        expect(described_class.call(runner)).to contain_exactly(
          have_attributes(
            code: :deprecated_model,
            scope: :runner,
            severity: :warning,
            title: "Runner pinned to a deprecated model",
            description: a_string_including("claude-retired"),
            remediation: a_string_including("tier model mapping"),
            action_url: Rails.application.routes.url_helpers.edit_runner_path(runner)
          )
        )
      end
    end
  end

  context "when the registry is unhealthy for the provider" do
    # Drive through a real DetectCatalogDrift so the @registry.healthy?(provider)
    # guard is genuinely exercised (required coverage from #3055) rather than
    # stubbed away. A degraded registry fetch must suppress deprecation findings.
    let(:unhealthy_registry) { instance_double(Models::RegistryModels) }

    before do
      allow(unhealthy_registry).to receive(:healthy?).with("anthropic").and_return(false)
      allow(Models::DetectCatalogDrift).to receive(:new)
        .and_return(Models::DetectCatalogDrift.new(registry: unhealthy_registry))
    end

    it "returns no findings because the healthy? guard suppresses them" do
      expect(described_class.call(runner)).to eq([])
      expect(unhealthy_registry).to have_received(:healthy?).with("anthropic")
    end
  end
end
