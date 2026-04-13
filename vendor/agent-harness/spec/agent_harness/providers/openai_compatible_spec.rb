# frozen_string_literal: true

RSpec.describe AgentHarness::Providers::Openai do
  FakeSuccessResponse = Struct.new(:body, :headers, keyword_init: true) do
    def code
      "200"
    end

    def to_hash
      headers
    end

    def is_a?(klass)
      klass == Net::HTTPSuccess || super
    end
  end

  FakeErrorResponse = Struct.new(:code, :body, :headers, keyword_init: true) do
    def to_hash
      headers
    end

    def is_a?(klass)
      false
    end
  end

  let(:provider_config) do
    AgentHarness::ProviderConfig.new(:openai).tap do |config|
      config.api_key = "sk-test"
      config.base_url = "https://api.openai.com"
    end
  end

  let(:provider) { described_class.new(config: provider_config) }
  let(:http_client) { instance_double("Net::HTTP") }

  before do
    allow(Net::HTTP).to receive(:start).and_yield(http_client)
  end

  it "requests embeddings and returns vectors plus token usage" do
    allow(http_client).to receive(:request).and_return(
      FakeSuccessResponse.new(
        body: JSON.generate(
          data: [
            {index: 1, embedding: [0.3, 0.4]},
            {index: 0, embedding: [0.1, 0.2]}
          ],
          usage: {total_tokens: 22},
          model: "text-embedding-3-large"
        ),
        headers: {"x-request-id" => ["req-123"]}
      )
    )

    response = provider.embed(
      texts: ["first", "second"],
      model: "text-embedding-3-large",
      dimensions: 2
    )

    expect(response.vectors).to eq([[0.1, 0.2], [0.3, 0.4]])
    expect(response.token_count).to eq(22)
    expect(response.provider).to eq(:openai)
    expect(response.model).to eq("text-embedding-3-large")
    expect(AgentHarness.token_tracker.total_tokens).to eq(22)
  end

  it "respects provider runtime base_url and headers" do
    captured_request = nil
    allow(http_client).to receive(:request) do |request|
      captured_request = request
      FakeSuccessResponse.new(
        body: JSON.generate(data: [{index: 0, embedding: [0.1]}], usage: {total_tokens: 1}),
        headers: {}
      )
    end

    provider.embed(
      texts: ["hello"],
      model: "text-embedding-3-large",
      provider_runtime: AgentHarness::ProviderRuntime.new(
        base_url: "https://example.com/custom",
        env: {"OPENAI_API_KEY" => "runtime-key"},
        metadata: {headers: {"X-Test" => "true"}}
      )
    )

    expect(Net::HTTP).to have_received(:start).with(
      "example.com",
      443,
      hash_including(use_ssl: true)
    )
    expect(captured_request["Authorization"]).to eq("Bearer runtime-key")
    expect(captured_request["X-Test"]).to eq("true")
  end

  it "maps 429 responses to RateLimitError" do
    allow(http_client).to receive(:request).and_return(
      FakeErrorResponse.new(
        code: "429",
        body: JSON.generate(error: {message: "Too many requests"}),
        headers: {"retry-after" => ["60"]}
      )
    )

    expect {
      provider.embed(texts: ["hello"], model: "text-embedding-3-large")
    }.to raise_error(AgentHarness::RateLimitError, /Too many requests/)
  end
end

RSpec.describe AgentHarness::Providers::Openrouter do
  let(:provider_config) do
    AgentHarness::ProviderConfig.new(:openrouter).tap do |config|
      config.api_key = "sk-test"
      config.base_url = "https://openrouter.ai/api/v1"
    end
  end

  let(:provider) { described_class.new(config: provider_config) }
  let(:http_client) { instance_double("Net::HTTP") }

  before do
    allow(Net::HTTP).to receive(:start).and_yield(http_client)
    allow(http_client).to receive(:request).and_return(
      FakeSuccessResponse.new(
        body: JSON.generate(data: [{index: 0, embedding: [0.1]}], usage: {total_tokens: 1}),
        headers: {}
      )
    )
  end

  it "keeps the OpenRouter /api/v1 prefix when building the embeddings URL" do
    provider.embed(texts: ["hello"], model: "text-embedding-3-large")

    expect(Net::HTTP).to have_received(:start).with(
      "openrouter.ai",
      443,
      hash_including(use_ssl: true)
    )
    expect(http_client).to have_received(:request) do |request|
      expect(request.path).to eq("/api/v1/embeddings")
    end
  end
end

RSpec.describe AgentHarness::Providers::AzureOpenai do
  let(:provider_config) do
    AgentHarness::ProviderConfig.new(:azure_openai).tap do |config|
      config.api_key = "azure-key"
      config.base_url = "https://example.openai.azure.com"
      config.api_version = "2024-10-21"
      config.deployment = "embed-prod"
    end
  end

  let(:provider) { described_class.new(config: provider_config) }
  let(:http_client) { instance_double("Net::HTTP") }

  before do
    allow(Net::HTTP).to receive(:start).and_yield(http_client)
    allow(http_client).to receive(:request).and_return(
      FakeSuccessResponse.new(
        body: JSON.generate(data: [{index: 0, embedding: [0.1]}], usage: {total_tokens: 1}),
        headers: {}
      )
    )
  end

  it "uses the Azure deployment-specific embeddings endpoint" do
    provider.embed(texts: ["hello"], model: "text-embedding-3-large", dimensions: 3)

    expect(http_client).to have_received(:request) do |request|
      expect(request.path).to eq("/openai/deployments/embed-prod/embeddings?api-version=2024-10-21")
      expect(request["api-key"]).to eq("azure-key")
      expect(request["Authorization"]).to be_nil
      expect(JSON.parse(request.body)).to eq("input" => ["hello"], "dimensions" => 3)
    end
  end
end
