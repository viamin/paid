# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaidAgentHarnessPiRuntimePatch do
  let(:provider) { AgentHarness::Providers::Pi.new }
  let(:provider_runtime) do
    AgentHarness::ProviderRuntime.new(
      metadata: {
        "paid_pi_auth_entry" => {
          "provider" => "minimax",
          "api_key" => "secret-key"
        }
      }
    )
  end
  let(:upstream_preparation) do
    AgentHarness::ExecutionPreparation.new(
      file_writes: [
        {
          path: PaidAgentHarnessPiRuntimePatch::PI_AUTH_JSON_PATH,
          content: "{\"native\":true}",
          mode: 0o600
        }
      ]
    )
  end

  it "exposes Pi API key env vars for auth and subscription unsets" do
    expected_env_vars = Provider::PI_API_PROVIDERS.values.map { |config| config[:env_var] }.uniq

    expect(provider.api_key_env_var_names).to match_array(expected_env_vars)
    expect(provider.subscription_unset_vars).to match_array(expected_env_vars)
  end

  it "does not duplicate auth.json when upstream already materializes it" do
    upstream = upstream_preparation

    provider.singleton_class.prepend(
      Module.new do
        protected

        define_method(:build_execution_preparation) do |_options|
          upstream
        end
      end
    )

    result = provider.send(:build_execution_preparation, provider_runtime: provider_runtime)

    expect(result.file_writes.size).to eq(1)
    expect(result.file_writes.first.path).to eq(PaidAgentHarnessPiRuntimePatch::PI_AUTH_JSON_PATH)
    expect(result.file_writes.first.content).to eq("{\"native\":true}")
  end

  it "materializes auth.json from provider runtime metadata when upstream does not" do
    preparation = provider.send(:build_execution_preparation, provider_runtime: provider_runtime)

    expect(preparation).to be_a(AgentHarness::ExecutionPreparation)
    expect(preparation.file_writes.size).to eq(1)

    write = preparation.file_writes.first
    expect(write.path).to eq(PaidAgentHarnessPiRuntimePatch::PI_AUTH_JSON_PATH)
    expect(write.mode).to eq(0o600)
    expect(JSON.parse(write.content)).to eq(
      "minimax" => {
        "type" => "api_key",
        "key" => "secret-key"
      }
    )
  end
end
