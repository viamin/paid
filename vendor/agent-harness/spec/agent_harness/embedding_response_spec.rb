# frozen_string_literal: true

RSpec.describe AgentHarness::EmbeddingResponse do
  subject(:response) do
    described_class.new(
      vectors: [[0.1, 0.2], [0.3, 0.4]],
      token_count: 42,
      duration: 1.25,
      provider: :openai,
      model: "text-embedding-3-large",
      dimensions: 2,
      metadata: {source: "test"}
    )
  end

  it "exposes the embedding response attributes" do
    expect(response.vectors).to eq([[0.1, 0.2], [0.3, 0.4]])
    expect(response.token_count).to eq(42)
    expect(response.duration).to eq(1.25)
    expect(response.provider).to eq(:openai)
    expect(response.model).to eq("text-embedding-3-large")
    expect(response.dimensions).to eq(2)
    expect(response.metadata).to eq({source: "test"})
  end

  it "reports success" do
    expect(response.success?).to be(true)
  end

  it "serializes to a hash" do
    expect(response.to_h).to include(
      token_count: 42,
      provider: :openai,
      model: "text-embedding-3-large"
    )
  end

  it "renders a concise inspect string" do
    expect(response.inspect).to include("AgentHarness::EmbeddingResponse")
    expect(response.inspect).to include("provider=openai")
    expect(response.inspect).to include("vectors=2")
  end
end
