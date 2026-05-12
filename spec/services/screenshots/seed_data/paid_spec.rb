# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::SeedData::Paid do
  it "returns the seeded style guide metadata" do
    result = described_class.call

    style_guide = StyleGuide.find(result.dig("style_guide", "id"))

    expect(result.fetch("style_guide")).to eq(
      "id" => style_guide.id,
      "name" => "Screenshot Style Guide"
    )
  end

  it "returns seeded strategy review metadata" do
    result = described_class.call

    strategy = Strategy.find(result.dig("strategy", "id"))
    pending_strategy_version = StrategyVersion.find(result.dig("pending_strategy_version", "id"))

    expect(result.fetch("strategy")).to eq(
      "id" => strategy.id,
      "name" => "Screenshot Strategy"
    )
    expect(pending_strategy_version).to be_pending_review
    expect(pending_strategy_version.strategy).to eq(strategy)
  end
end
