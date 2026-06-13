# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# Concrete stand-in for Models::RegistryModels so the detector exercises real
# method dispatch (no double arity quirks).
class CatalogDriftFakeRegistry
  def initialize(models_by_provider, fetched, healthy)
    @models_by_provider = models_by_provider
    @fetched = fetched
    @healthy = healthy
  end

  def fetched?
    @fetched
  end

  def healthy?(provider)
    @healthy && @models_by_provider.key?(provider)
  end

  def for_provider(provider)
    @models_by_provider[provider] || []
  end
end

RSpec.describe Models::DetectCatalogDrift do
  # Plain hashes for modalities/metadata are fine: the detector only calls
  # `.to_h` on them, which Hash supports.
  def reg_model(id:, provider:, created_at:, capabilities: %w[function_calling], modalities: { input: %w[text], output: %w[text] }, metadata: {})
    OpenStruct.new(
      id: id,
      provider: provider,
      created_at: created_at,
      capabilities: capabilities,
      modalities: modalities,
      metadata: metadata
    )
  end

  def fake_registry(models_by_provider, fetched = true, healthy = true)
    CatalogDriftFakeRegistry.new(models_by_provider, fetched, healthy)
  end

  let(:nov_2025) { Time.utc(2025, 11, 13) }
  let(:dec_2025) { Time.utc(2025, 12, 11) }
  let(:apr_2024) { Time.utc(2024, 5, 13) }

  before do
    LlmModel.create!(model_id: "gpt-5.1", display_name: "GPT-5.1", provider: "openai", category: "coding", tier: "mid")
  end

  it "reports registry models newer than the newest catalogued model" do
    registry = fake_registry(
      "openai" => [
        reg_model(id: "gpt-5.1", provider: "openai", created_at: nov_2025),
        reg_model(id: "gpt-5.2", provider: "openai", created_at: dec_2025)
      ]
    )

    result = described_class.call(providers: %w[openai], registry: registry)

    expect(result.drift?).to be(true)
    expect(result.providers["openai"][:new_models].map { |m| m[:representative] }).to eq(%w[gpt-5.2])
  end

  it "ignores models older than the newest catalogued model" do
    registry = fake_registry(
      "openai" => [
        reg_model(id: "gpt-5.1", provider: "openai", created_at: nov_2025),
        reg_model(id: "gpt-4o", provider: "openai", created_at: apr_2024)
      ]
    )

    result = described_class.call(providers: %w[openai], registry: registry)

    expect(result.drift?).to be(false)
  end

  it "excludes non-chat, open-weight, and unstable preview/latest models" do
    registry = fake_registry(
      "openai" => [
        reg_model(id: "gpt-5.1", provider: "openai", created_at: nov_2025),
        reg_model(id: "gpt-5.2-image", provider: "openai", created_at: dec_2025),
        reg_model(id: "gpt-5.2-chat-latest", provider: "openai", created_at: dec_2025),
        reg_model(id: "gpt-5.2-preview", provider: "openai", created_at: dec_2025),
        reg_model(id: "gemma-5", provider: "openai", created_at: dec_2025, metadata: { open_weights: true }),
        reg_model(id: "gpt-5.2-embedding", provider: "openai", created_at: dec_2025, capabilities: %w[embedding])
      ]
    )

    result = described_class.call(providers: %w[openai], registry: registry)

    expect(result.drift?).to be(false)
  end

  it "collapses dated snapshots into one representative entry" do
    registry = fake_registry(
      "openai" => [
        reg_model(id: "gpt-5.1", provider: "openai", created_at: nov_2025),
        reg_model(id: "gpt-5.2", provider: "openai", created_at: dec_2025),
        reg_model(id: "gpt-5.2-2025-12-11", provider: "openai", created_at: dec_2025)
      ]
    )

    new_models = described_class.call(providers: %w[openai], registry: registry).providers["openai"][:new_models]

    expect(new_models.size).to eq(1)
    expect(new_models.first).to include(representative: "gpt-5.2", variants: 2)
  end

  it "treats a catalogued model the registry no longer knows as deprecated" do
    LlmModel.create!(model_id: "gpt-retired", display_name: "Retired", provider: "openai", category: "coding", tier: "low")

    registry = fake_registry(
      "openai" => [ reg_model(id: "gpt-5.1", provider: "openai", created_at: nov_2025) ]
    )

    result = described_class.call(providers: %w[openai], registry: registry)

    expect(result.providers["openai"][:deprecated_models]).to eq(%w[gpt-retired])
  end

  it "suppresses deprecation signals when the registry fetch is unhealthy" do
    LlmModel.create!(model_id: "gpt-retired", display_name: "Retired", provider: "openai", category: "coding", tier: "low")

    registry = fake_registry(
      { "openai" => [ reg_model(id: "gpt-5.1", provider: "openai", created_at: nov_2025) ] },
      true,
      false
    )

    result = described_class.call(providers: %w[openai], registry: registry)

    expect(result.providers).to be_empty
  end

  it "produces a stable fingerprint for the same finding set" do
    registry = fake_registry(
      "openai" => [
        reg_model(id: "gpt-5.1", provider: "openai", created_at: nov_2025),
        reg_model(id: "gpt-5.2", provider: "openai", created_at: dec_2025)
      ]
    )

    first = described_class.call(providers: %w[openai], registry: registry).fingerprint
    second = described_class.call(providers: %w[openai], registry: registry).fingerprint

    expect(first).to eq(second)
  end
end
