# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Embeddings::Generate do
  let(:texts) { [ "Hello world", "Goodbye world" ] }
  let(:vector) { Array.new(3072, 0.1) }
  let(:base_url) { "https://proxy.openai.test/api/proxy/openai/v1" }
  let(:headers) do
    {
      "Authorization" => "Bearer paid-knowledge-run:99:token",
      "X-Paid-Knowledge-Provider" => "openrouter"
    }
  end

  let(:success_response_body) do
    {
      "data" => [
        { "index" => 0, "embedding" => vector },
        { "index" => 1, "embedding" => vector }
      ],
      "usage" => { "total_tokens" => 10 }
    }
  end

  describe ".call" do
    before do
      allow(AgentHarness).to receive(:embed).and_return(success_response_body)
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

    it "sorts results by index" do
      reversed_body = {
        "data" => [
          { "index" => 1, "embedding" => Array.new(3072, 0.2) },
          { "index" => 0, "embedding" => Array.new(3072, 0.1) }
        ],
        "usage" => { "total_tokens" => 10 }
      }

      allow(AgentHarness).to receive(:embed).and_return(reversed_body)

      results = described_class.call(texts: texts, base_url: base_url, headers: headers)

      expect(results.first.vector.first).to eq(0.1)
      expect(results.last.vector.first).to eq(0.2)
    end

    it "passes proxy credentials through AgentHarness.embed" do
      described_class.call(texts: texts, base_url: base_url, headers: headers)

      expect(AgentHarness).to have_received(:embed).with(
        texts,
        model: "text-embedding-3-large",
        dimensions: 3072,
        base_url: base_url,
        api_key: "paid-knowledge-run:99:token",
        headers: { "X-Paid-Knowledge-Provider" => "openrouter" },
        timeout: AgentHarness::OpenAICompatibleTransport::DEFAULT_TIMEOUT
      )
    end
  end

  describe "error handling" do
    it "retries on retryable HTTP statuses and raises after max retries" do
      allow(AgentHarness).to receive(:embed).and_raise(
        AgentHarness::ProviderError.new("Server error (500): Internal Server Error", context: { status: 500 })
      )

      generator = described_class.new(base_url: base_url, headers: headers)
      allow(generator).to receive(:sleep)

      expect { generator.call(texts: texts) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /after 3 retries/)
      expect(AgentHarness).to have_received(:embed).exactly(4).times
    end

    it "respects Retry-After header on 429 responses" do
      calls = 0
      allow(AgentHarness).to receive(:embed) do
        calls += 1
        raise AgentHarness::RateLimitError.new(
          "API rate limit exceeded: Rate limited",
          context: { headers: { "retry-after" => "2.5" } }
        ) if calls == 1

        success_response_body
      end

      generator = described_class.new(base_url: base_url, headers: headers)
      allow(generator).to receive(:sleep)

      generator.call(texts: texts)

      expect(generator).to have_received(:sleep).with(2.5)
    end

    it "raises EmbeddingError on non-retryable HTTP failures" do
      allow(AgentHarness).to receive(:embed).and_raise(
        AgentHarness::ProviderError.new("Bad request: Bad Request", context: { status: 400 })
      )

      expect { described_class.call(texts: texts, base_url: base_url, headers: headers) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /Bad request/)
    end

    it "retries on transport errors and raises after max retries" do
      allow(AgentHarness).to receive(:embed).and_raise(
        AgentHarness::ProviderError.new("HTTP connection error: connection failed", original_error: IOError.new("connection failed"))
      )

      generator = described_class.new(base_url: base_url, headers: headers)
      allow(generator).to receive(:sleep)

      expect { generator.call(texts: texts) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /after 3 retries/)
    end

    it "retries when the shim wraps TLS transport failures as provider errors" do
      allow(AgentHarness).to receive(:embed).and_raise(
        AgentHarness::ProviderError.new(
          "HTTP connection error: tls handshake failed",
          original_error: OpenSSL::SSL::SSLError.new("tls handshake failed")
        )
      )

      generator = described_class.new(base_url: base_url, headers: headers)
      allow(generator).to receive(:sleep)

      expect { generator.call(texts: texts) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /after 3 retries/)
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
      allow(AgentHarness).to receive(:embed).and_return(success_response_body)

      described_class.call(
        texts: texts,
        base_url: "https://proxy.openai.test/custom/v1",
        headers: headers
      )

      expect(AgentHarness).to have_received(:embed).with(
        texts,
        model: "text-embedding-3-large",
        dimensions: 3072,
        base_url: "https://proxy.openai.test/custom/v1",
        api_key: "paid-knowledge-run:99:token",
        headers: { "X-Paid-Knowledge-Provider" => "openrouter" },
        timeout: AgentHarness::OpenAICompatibleTransport::DEFAULT_TIMEOUT
      )
    end
  end

  describe ".results_from_body" do
    it "distributes total tokens evenly across embeddings" do
      body = {
        "data" => [
          { "index" => 0, "embedding" => [ 0.1 ] },
          { "index" => 1, "embedding" => [ 0.2 ] }
        ],
        "usage" => { "total_tokens" => 8 }
      }

      results = described_class.results_from_body(body)

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
