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
end
