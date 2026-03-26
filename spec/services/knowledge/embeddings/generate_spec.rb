# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Embeddings::Generate do
  let(:api_key) { "sk-test-key" }
  let(:texts) { [ "Hello world", "Goodbye world" ] }
  let(:vector) { Array.new(3072, 0.1) }

  let(:success_response_body) do
    {
      data: [
        { index: 0, embedding: vector },
        { index: 1, embedding: vector }
      ],
      usage: { total_tokens: 10 }
    }.to_json
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("OPENAI_API_KEY").and_return(api_key)
    allow(ENV).to receive(:fetch).with("OPENAI_API_BASE_URL", anything).and_return("https://api.openai.com")
  end

  describe ".call" do
    before do
      stub_request(:post, "https://api.openai.com/v1/embeddings")
        .with(
          body: { input: texts, model: "text-embedding-3-large", dimensions: 3072 }.to_json,
          headers: { "Authorization" => "Bearer #{api_key}", "Content-Type" => "application/json" }
        )
        .to_return(status: 200, body: success_response_body, headers: { "Content-Type" => "application/json" })
    end

    it "returns embedding results for each text" do
      results = described_class.call(texts: texts)

      expect(results.size).to eq(2)
      expect(results.first.vector).to eq(vector)
      expect(results.first.token_count).to eq(5)
    end

    it "returns an empty array for empty input" do
      results = described_class.call(texts: [])

      expect(results).to eq([])
    end

    it "sorts results by index" do
      reversed_body = {
        data: [
          { index: 1, embedding: Array.new(3072, 0.2) },
          { index: 0, embedding: Array.new(3072, 0.1) }
        ],
        usage: { total_tokens: 10 }
      }.to_json

      stub_request(:post, "https://api.openai.com/v1/embeddings")
        .to_return(status: 200, body: reversed_body, headers: { "Content-Type" => "application/json" })

      results = described_class.call(texts: texts)

      expect(results.first.vector.first).to eq(0.1)
      expect(results.last.vector.first).to eq(0.2)
    end
  end

  describe "error handling" do
    it "raises EmbeddingError on API failure" do
      stub_request(:post, "https://api.openai.com/v1/embeddings")
        .to_return(status: 500, body: "Internal Server Error")

      expect { described_class.call(texts: texts) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /500/)
    end

    it "retries on Faraday errors and raises after max retries" do
      stub_request(:post, "https://api.openai.com/v1/embeddings")
        .to_raise(Faraday::ConnectionFailed.new("connection failed"))

      generator = described_class.new
      allow(generator).to receive(:sleep)

      expect { generator.call(texts: texts) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /after 3 retries/)
    end

    it "raises EmbeddingError when OPENAI_API_KEY is not set" do
      allow(ENV).to receive(:fetch).with("OPENAI_API_KEY").and_call_original
      # Clear ENV for this test
      original = ENV["OPENAI_API_KEY"]
      ENV.delete("OPENAI_API_KEY")

      expect { described_class.call(texts: texts) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /OPENAI_API_KEY/)
    ensure
      ENV["OPENAI_API_KEY"] = original if original
    end
  end

  describe ".estimate_cost" do
    it "calculates cost based on token count" do
      cost = described_class.estimate_cost(1_000_000)

      expect(cost).to eq(0.13)
    end

    it "returns zero for zero tokens" do
      expect(described_class.estimate_cost(0)).to eq(0.0)
    end
  end
end
