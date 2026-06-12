# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::RegistryModels do
  let(:registry) { instance_double(RubyLLM::Models) }

  def model(id:, provider:)
    instance_double(RubyLLM::Model::Info, id: id, provider: provider)
  end

  before do
    allow(RubyLLM).to receive(:models).and_return(registry)
    allow(registry).to receive(:refresh!).and_return(true)
  end

  it "normalizes the gemini provider alias to google" do
    allow(registry).to receive(:all).and_return([ model(id: "gemini-3-pro", provider: "gemini") ])

    subject = described_class.fetch

    expect(subject.for_provider("google").map(&:id)).to eq(%w[gemini-3-pro])
  end

  it "indexes models by id across providers" do
    allow(registry).to receive(:all).and_return([
      model(id: "shared", provider: "openai"),
      model(id: "shared", provider: "anthropic")
    ])

    index = described_class.fetch.grouped_by_id

    expect(index["shared"].keys).to contain_exactly("openai", "anthropic")
  end

  it "reports the registry as healthy only above the provider threshold" do
    allow(registry).to receive(:all).and_return(Array.new(2) { |i| model(id: "m#{i}", provider: "openai") })

    subject = described_class.fetch

    expect(subject.fetched?).to be(true)
    expect(subject.healthy?("openai")).to be(false)
  end

  it "is not fetched and logs a fallback when the registry is unavailable" do
    allow(registry).to receive(:refresh!).and_raise(StandardError.new("down"))
    allow(Rails.logger).to receive(:warn)

    subject = described_class.fetch

    expect(subject.fetched?).to be(false)
    expect(subject.all).to eq([])
    expect(Rails.logger).to have_received(:warn).with(hash_including(message: "model_registry.registry_fallback"))
  end
end
