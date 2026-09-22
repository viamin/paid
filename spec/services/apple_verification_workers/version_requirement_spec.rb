# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationWorkers::VersionRequirement do
  describe ".parse" do
    it "accepts comparator, pessimistic, and exact constraints" do
      expect(described_class.parse(">= 26.0").to_s).to eq(">= 26.0")
      expect(described_class.parse(">= 26.0, < 27.0").to_s).to eq(">= 26.0, < 27.0")
      expect(described_class.parse("~> 26.0").to_s).to eq("~> 26.0")
      expect(described_class.parse("= 26.1").to_s).to eq("= 26.1")
    end

    it "rejects malformed constraints with a deterministic error" do
      expect { described_class.parse("latest") }.to raise_error(AppleVerificationWorkers::InvalidVersionConstraint, /latest/)
      expect { described_class.parse(">= 26.0 !") }.to raise_error(AppleVerificationWorkers::InvalidVersionConstraint, /26\.0 !/)
      expect { described_class.parse("") }.to raise_error(AppleVerificationWorkers::InvalidVersionConstraint)
    end

    it "rejects constraints that match no version" do
      expect { described_class.parse(">= 27.0, < 26.0") }.to raise_error(AppleVerificationWorkers::InvalidVersionConstraint, /matches no version/)
      expect { described_class.parse("> 26.0, <= 26.0") }.to raise_error(AppleVerificationWorkers::InvalidVersionConstraint, /matches no version/)
    end
  end

  describe "#within?" do
    it "is true when every satisfying version also satisfies the outer constraint" do
      expect(described_class.parse(">= 26.0, < 27.0").within?(described_class.parse(">= 26.0"))).to be(true)
      expect(described_class.parse("~> 26.0").within?(described_class.parse(">= 26.0, < 27.0"))).to be(true)
      expect(described_class.parse("= 26.1").within?(described_class.parse(">= 26.0, < 27.0"))).to be(true)
      expect(described_class.parse(">= 26.0").within?(described_class.parse(">= 26.0"))).to be(true)
    end

    it "is false when the range escapes the outer constraint" do
      expect(described_class.parse(">= 26.0").within?(described_class.parse(">= 26.0, < 27.0"))).to be(false)
      expect(described_class.parse(">= 24.0").within?(described_class.parse(">= 26.0, < 27.0"))).to be(false)
      expect(described_class.parse(">= 26.0, < 27.0").within?(described_class.parse("> 26.0, < 27.0"))).to be(false)
      expect(described_class.parse(">= 26.0, <= 27.0").within?(described_class.parse(">= 26.0, < 27.0"))).to be(false)
    end
  end
end
