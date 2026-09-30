# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Embeddings::Generate do
  # @spec KNOWLEDGE-EMBED-001
  let(:texts) { [ "Hello world", "Goodbye world" ] }
  let(:vector) { Array.new(3072, 0.1) }
  let(:base_url) { "https://proxy.openai.test/api/proxy/openai/v1" }
  let(:headers) do
    {
      "Authorization" => "Bearer paid-knowledge-run:99:token",
      "X-Paid-Knowledge-Provider" => "openrouter"
    }
  end

  let(:success_response) do
    AgentHarness::EmbeddingResult.new(
      vectors: [ vector, vector ],
      model: "text-embedding-3-large",
      input_tokens: 10
    )
  end

  describe ".call" do
    before do
      allow(AgentHarness).to receive(:embed).and_return(success_response)
    end

    it "returns embedding results for each text" do
      results = described_class.call(texts: texts, base_url: base_url, headers: headers)

      expect(results.size).to eq(2)
      expect(results.first.vector).to eq(vector)
      expect(results.first.token_count).to eq(5)
    end

    it "returns an empty array for empty input" do
      expect(described_class.call(texts: [], base_url: base_url, headers: headers)).to eq([])
    end

    it "preserves the response vector order" do
      reversed_response = AgentHarness::EmbeddingResult.new(
        vectors: [ Array.new(3072, 0.1), Array.new(3072, 0.2) ],
        model: "text-embedding-3-large",
        input_tokens: 10
      )

      allow(AgentHarness).to receive(:embed).and_return(reversed_response)

      results = described_class.call(texts: texts, base_url: base_url, headers: headers)

      expect(results.first.vector.first).to eq(0.1)
      expect(results.last.vector.first).to eq(0.2)
    end

    it "passes proxy credentials through AgentHarness.embed" do
      described_class.call(texts: texts, base_url: base_url, headers: headers)

      expect(AgentHarness).to have_received(:embed).with(
        inputs: texts,
        model: "text-embedding-3-large",
        dimensions: 3072,
        endpoint: base_url,
        credentials: { api_key: "paid-knowledge-run:99:token" },
        headers: { "X-Paid-Knowledge-Provider" => "openrouter" },
        timeout: AgentHarness::OpenAICompatibleTransport::DEFAULT_TIMEOUT,
        max_attempts: 4
      )
    end
  end

  describe "error handling" do
    # @spec KNOWLEDGE-EMBED-002
    it "delegates the single retry loop, including Retry-After handling, to Agent Harness" do
      allow(AgentHarness).to receive(:embed).and_raise(
        AgentHarness::RateLimitError.new("rate limited", reset_time: 2.seconds.from_now)
      )

      expect { described_class.call(texts: texts, base_url: base_url, headers: headers) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /rate limited/)
      expect(AgentHarness).to have_received(:embed).once.with(hash_including(max_attempts: 4))
    end

    it "raises EmbeddingError on non-retryable HTTP failures" do
      allow(AgentHarness).to receive(:embed).and_raise(
        AgentHarness::ProviderError.new("Bad request: Bad Request", context: { status: 400 })
      )

      expect { described_class.call(texts: texts, base_url: base_url, headers: headers) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /Bad request/)
    end

    it "preserves a classified transport error as the embedding error cause" do
      provider_error = AgentHarness::ProviderError.new(
        "HTTP connection error: tls handshake failed",
        original_error: OpenSSL::SSL::SSLError.new("tls handshake failed")
      )
      allow(AgentHarness).to receive(:embed).and_raise(
        provider_error
      )

      expect { described_class.call(texts: texts, base_url: base_url, headers: headers) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError) { |error|
          expect(error.cause).to be(provider_error)
        }
    end

    it "raises EmbeddingError on invalid embedding response JSON" do
      allow(AgentHarness).to receive(:embed).and_raise(
        AgentHarness::ProviderError.new(
          "Invalid JSON in embedding API response: unexpected token at '<html>Error</html>'",
          original_error: JSON::ParserError.new("unexpected token at '<html>Error</html>'")
        )
      )

      expect { described_class.call(texts: texts, base_url: base_url, headers: headers) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /Invalid JSON/)
    end

    it "does not wrap programming errors as EmbeddingError" do
      allow(AgentHarness).to receive(:embed).and_raise(NoMethodError.new("undefined method"))

      expect { described_class.call(texts: texts, base_url: base_url, headers: headers) }
        .to raise_error(NoMethodError)
    end

    it "supports arbitrary OpenAI-compatible proxy base URLs" do
      allow(AgentHarness).to receive(:embed).and_return(success_response)

      described_class.call(
        texts: texts,
        base_url: "https://proxy.openai.test/custom/v1",
        headers: headers
      )

      expect(AgentHarness).to have_received(:embed).with(
        inputs: texts,
        model: "text-embedding-3-large",
        dimensions: 3072,
        endpoint: "https://proxy.openai.test/custom/v1",
        credentials: { api_key: "paid-knowledge-run:99:token" },
        headers: { "X-Paid-Knowledge-Provider" => "openrouter" },
        timeout: AgentHarness::OpenAICompatibleTransport::DEFAULT_TIMEOUT,
        max_attempts: 4
      )
    end
  end

  describe ".results_from_response" do
    it "distributes total tokens evenly across embeddings" do
      response = AgentHarness::EmbeddingResult.new(
        vectors: [ [ 0.1 ], [ 0.2 ] ],
        model: "text-embedding-3-large",
        input_tokens: 8
      )

      results = described_class.results_from_response(response)

      expect(results.map(&:token_count)).to eq([ 4, 4 ])
      expect(response.per_vector_usage).to be_nil
    end
  end

  describe ".results_from_body" do
    it "sorts container response vectors by index" do
      body = {
        "data" => [
          { "index" => 1, "embedding" => [ 0.2 ] },
          { "index" => 0, "embedding" => [ 0.1 ] }
        ],
        "usage" => { "total_tokens" => 8 }
      }

      results = described_class.results_from_body(body)

      expect(results.map(&:vector)).to eq([ [ 0.1 ], [ 0.2 ] ])
      expect(results.map(&:token_count)).to eq([ 4, 4 ])
    end
  end

  describe ".estimate_cost" do
    it "calculates cost based on token count" do
      expect(described_class.estimate_cost(1_000_000)).to eq(0.13)
    end

    it "returns zero for zero tokens" do
      expect(described_class.estimate_cost(0)).to eq(0.0)
    end
  end
end
