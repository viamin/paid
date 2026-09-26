# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::FailureClassification do
  # @spec APPLE-ATTEMPT-009
  describe ".valid?" do
    it "is true for every taxonomy entry" do
      described_class::TAXONOMY.each do |classification|
        expect(described_class.valid?(classification)).to be(true), "expected #{classification} to be valid"
      end
    end

    it "is false for an unknown classification" do
      expect(described_class.valid?("flaky")).to be(false)
    end
  end

  # @spec APPLE-ATTEMPT-010
  describe ".infrastructure?" do
    it "is true for the infrastructure subset" do
      described_class::INFRASTRUCTURE.each do |classification|
        expect(described_class.infrastructure?(classification)).to be(true), "expected #{classification} to be infrastructure"
      end
    end

    it "is false for a project classification" do
      expect(described_class.infrastructure?("test_assertion")).to be(false)
    end
  end

  # @spec APPLE-ATTEMPT-010
  describe ".project?" do
    it "is false for the infrastructure subset" do
      described_class::INFRASTRUCTURE.each do |classification|
        expect(described_class.project?(classification)).to be(false), "expected #{classification} not to be a project classification"
      end
    end

    it "is true for a project classification" do
      expect(described_class.project?("test_assertion")).to be(true)
    end
  end

  describe "TAXONOMY" do
    it "has exactly ten unique entries" do
      expect(described_class::TAXONOMY.uniq.size).to eq(10)
    end

    it "contains the infrastructure subset" do
      expect(described_class::INFRASTRUCTURE - described_class::TAXONOMY).to be_empty
    end
  end
end
