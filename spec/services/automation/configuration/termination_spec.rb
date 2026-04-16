# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Configuration::Termination do
  describe ".from_hash" do
    it "returns the frozen EMPTY value when given nil" do
      expect(described_class.from_hash(nil)).to equal(described_class::EMPTY)
    end

    it "returns the frozen EMPTY value when given an empty hash" do
      expect(described_class.from_hash({})).to equal(described_class::EMPTY)
    end

    it "normalizes a full termination hash" do
      termination = described_class.from_hash(
        "max_review_rounds" => 15,
        "max_review_goal_retries" => 3,
        "stop_when_no_comments" => true,
        "quality_threshold" => "high",
        "timeout_minutes" => 60
      )

      expect(termination).to have_attributes(
        max_review_rounds: 15,
        max_review_goal_retries: 3,
        stop_when_no_comments: true,
        quality_threshold: "high",
        timeout_minutes: 60
      )
    end

    it "coerces numeric strings to integers" do
      termination = described_class.from_hash(
        "max_review_rounds" => "5",
        "timeout_minutes" => "120"
      )

      expect(termination.max_review_rounds).to eq(5)
      expect(termination.timeout_minutes).to eq(120)
    end

    it "treats non-integer values as nil" do
      termination = described_class.from_hash("max_review_rounds" => "not-a-number")
      expect(termination.max_review_rounds).to be_nil
    end

    it "treats blank quality_threshold as nil" do
      termination = described_class.from_hash("quality_threshold" => "  ")
      expect(termination.quality_threshold).to be_nil
    end

    it "defaults stop_when_no_comments to false when missing or non-true" do
      expect(described_class.from_hash("stop_when_no_comments" => false).stop_when_no_comments).to be false
      expect(described_class.from_hash("stop_when_no_comments" => "true").stop_when_no_comments).to be false
    end
  end

  it "EMPTY exposes nil/default values" do
    expect(described_class::EMPTY).to have_attributes(
      max_review_rounds: nil,
      max_review_goal_retries: nil,
      stop_when_no_comments: false,
      quality_threshold: nil,
      timeout_minutes: nil
    )
  end
end
