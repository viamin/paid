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
      data: [
        { index: 0, embedding: vector },
        { index: 1, embedding: vector }
      ],
      usage: { total_tokens: 10 }
    }.to_json
  end

  describe ".call" do
    before do
      stub_request(:post, "https://proxy.openai.test/api/proxy/openai/v1/embeddings")
        .with(
          body: { input: texts, model: "text-embedding-3-large", dimensions: 3072 }.to_json,
          headers: headers.merge("Content-Type" => "application/json")
        )
        .to_return(status: 200, body: success_response_body, headers: { "Content-Type" => "application/json" })
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
        data: [
          { index: 1, embedding: Array.new(3072, 0.2) },
          { index: 0, embedding: Array.new(3072, 0.1) }
        ],
        usage: { total_tokens: 10 }
      }.to_json

      stub_request(:post, "https://proxy.openai.test/api/proxy/openai/v1/embeddings")
        .to_return(status: 200, body: reversed_body, headers: { "Content-Type" => "application/json" })

      results = described_class.call(texts: texts, base_url: base_url, headers: headers)

      expect(results.first.vector.first).to eq(0.1)
      expect(results.last.vector.first).to eq(0.2)
    end
  end

  describe "error handling" do
    it "retries on retryable HTTP statuses and raises after max retries" do
      stub_request(:post, "https://proxy.openai.test/api/proxy/openai/v1/embeddings")
        .to_return(status: 500, body: "Internal Server Error")

      generator = described_class.new(base_url: base_url, headers: headers)
      allow(generator).to receive(:sleep)

      expect { generator.call(texts: texts) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /after 3 retries/)
    end

    it "respects Retry-After header on 429 responses" do
      stub_request(:post, "https://proxy.openai.test/api/proxy/openai/v1/embeddings")
        .to_return(status: 429, body: "Rate limited", headers: { "Retry-After" => "2.5" })
        .then.to_return(status: 200, body: success_response_body, headers: { "Content-Type" => "application/json" })

      generator = described_class.new(base_url: base_url, headers: headers)
      allow(generator).to receive(:sleep)

      generator.call(texts: texts)

      expect(generator).to have_received(:sleep).with(2.5)
    end

    it "raises EmbeddingError on non-retryable HTTP failures" do
      stub_request(:post, "https://proxy.openai.test/api/proxy/openai/v1/embeddings")
        .to_return(status: 400, body: "Bad Request")

      expect { described_class.call(texts: texts, base_url: base_url, headers: headers) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /400/)
    end

    it "retries on Faraday errors and raises after max retries" do
      stub_request(:post, "https://proxy.openai.test/api/proxy/openai/v1/embeddings")
        .to_raise(Faraday::ConnectionFailed.new("connection failed"))

      generator = described_class.new(base_url: base_url, headers: headers)
      allow(generator).to receive(:sleep)

      expect { generator.call(texts: texts) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /after 3 retries/)
    end

    it "raises EmbeddingError on non-JSON response body" do
      stub_request(:post, "https://proxy.openai.test/api/proxy/openai/v1/embeddings")
        .to_return(status: 200, body: "<html>Error</html>", headers: { "Content-Type" => "text/html" })

      expect { described_class.call(texts: texts, base_url: base_url, headers: headers) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /Failed to parse embedding API response/)
    end

    it "supports arbitrary OpenAI-compatible proxy base URLs" do
      stub_request(:post, "https://proxy.openai.test/custom/v1/embeddings")
        .with(headers: headers)
        .to_return(status: 200, body: success_response_body, headers: { "Content-Type" => "application/json" })

      results = described_class.call(
        texts: texts,
        base_url: "https://proxy.openai.test/custom/v1",
        headers: headers
      )

      expect(results.size).to eq(2)
      expect(results.first.vector).to eq(vector)
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
