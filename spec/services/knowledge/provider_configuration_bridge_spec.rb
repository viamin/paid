# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ProviderConfiguration, :no_db do
  it "keeps the provider selector constant wired to the runner selector implementation" do
    expect(Knowledge::ProviderSelector.superclass).to eq(Knowledge::RunnerSelector)
  end

  it "keeps the provider executor exhaustion error wired to the runner error class" do
    expect(Knowledge::ProviderExecutor::AllProvidersExhausted).to eq(Knowledge::RunnerExecutor::AllRunnersExhausted)
  end

  it "accepts legacy provider keywords on provider configuration results" do
    result = Knowledge::ProviderConfiguration::Result.new(
      provider: "openai",
      provider_label: "OpenAI",
      api_key: "secret"
    )

    expect(result.provider).to eq("openai")
    expect(result.runner).to eq("openai")
    expect(result.provider_label).to eq("OpenAI")
    expect(result.runner_label).to eq("OpenAI")
    expect(result.api_key).to eq("secret")
  end
end
