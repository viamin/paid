# frozen_string_literal: true

RSpec.describe AgentHarness::Orchestration::Conductor, "#embed" do
  let(:embedding_response) do
    AgentHarness::EmbeddingResponse.new(
      vectors: [[0.1, 0.2]],
      token_count: 12,
      duration: 0.5,
      provider: :openai,
      model: "text-embedding-3-large"
    )
  end

  let(:mock_provider) do
    instance_double(AgentHarness::Providers::OpenaiCompatible).tap do |provider|
      allow(provider).to receive_message_chain(:class, :provider_name).and_return(:openai)
      allow(provider).to receive(:embed).and_return(embedding_response)
    end
  end

  let(:mock_provider_manager) do
    instance_double(AgentHarness::Orchestration::ProviderManager).tap do |pm|
      allow(pm).to receive(:providers_supporting_embeddings).and_return([:openai, :openrouter])
      allow(pm).to receive(:select_provider).and_return(mock_provider)
      allow(pm).to receive(:record_success)
      allow(pm).to receive(:record_failure)
      allow(pm).to receive(:mark_rate_limited)
      allow(pm).to receive(:switch_provider).and_return(nil)
      allow(pm).to receive(:current_provider).and_return(:openai)
      allow(pm).to receive(:available_providers).and_return([:openai])
      allow(pm).to receive(:health_status).and_return([])
      allow(pm).to receive(:reset!)
    end
  end

  let(:config) do
    AgentHarness::Configuration.new.tap do |c|
      c.default_provider = :openai
      c.provider(:openai) { |p| p.enabled = true }
      c.provider(:openrouter) { |p| p.enabled = true }
    end
  end

  subject(:conductor) do
    described_class.new(config: config).tap do |instance|
      instance.instance_variable_set(:@provider_manager, mock_provider_manager)
    end
  end

  it "routes embeddings through orchestration" do
    response = conductor.embed(
      texts: ["hello"],
      provider: :openai,
      model: "text-embedding-3-large",
      dimensions: 3_072
    )

    expect(response).to eq(embedding_response)
    expect(mock_provider_manager).to have_received(:providers_supporting_embeddings).with(model: "text-embedding-3-large")
    expect(mock_provider_manager).to have_received(:select_provider).with(:openai, allowed_providers: [:openai, :openrouter])
    expect(mock_provider).to have_received(:embed).with(
      texts: ["hello"],
      model: "text-embedding-3-large",
      dimensions: 3_072
    )
  end

  it "raises when no embedding providers are configured for the model" do
    allow(mock_provider_manager).to receive(:providers_supporting_embeddings).and_return([])

    expect {
      conductor.embed(texts: ["hello"], provider: :openai, model: "text-embedding-3-large")
    }.to raise_error(AgentHarness::NoProvidersAvailableError, /No embedding providers configured/)
  end

  it "marks providers rate limited on embedding rate-limit errors" do
    error = AgentHarness::RateLimitError.new("rate limited", reset_time: Time.now + 60)
    allow(mock_provider).to receive(:embed).and_raise(error)

    expect(mock_provider_manager).to receive(:mark_rate_limited).with(:openai, reset_at: error.reset_time).at_least(:once)

    expect {
      conductor.embed(texts: ["hello"], provider: :openai, model: "text-embedding-3-large")
    }.to raise_error(AgentHarness::RateLimitError)
  end
end
