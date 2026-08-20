# frozen_string_literal: true

require "rails_helper"

# @spec EGRESS-POLICY-001
RSpec.describe AgentRuns::EgressPolicy::HostPattern do
  describe ".invalid_reason" do
    it "returns nil for safe patterns" do
      expect(described_class.invalid_reason("api.example.com")).to be_nil
      expect(described_class.invalid_reason("*.packages.example.com")).to be_nil
      expect(described_class.invalid_reason("My-API.Example.COM")).to be_nil
      expect(described_class.invalid_reason("xn--80ak6aa92e.com")).to be_nil
    end

    it "returns a reason for unsafe patterns" do
      expect(described_class.invalid_reason(nil)).to eq("is missing")
      expect(described_class.invalid_reason(123)).to eq("must be a string")
      expect(described_class.invalid_reason("")).to eq("is blank")
      expect(described_class.invalid_reason("*.example.*")).to be_present
      expect(described_class.invalid_reason("https://api.example.com")).to be_present
      expect(described_class.invalid_reason("169.254.169.254")).to be_present
      expect(described_class.invalid_reason("localhost")).to be_present
      expect(described_class.invalid_reason("localhost.localdomain")).to eq("must not target localhost")
      expect(described_class.invalid_reason("api.local")).to eq("top-level domain must not be a reserved or special-use TLD")
      expect(described_class.invalid_reason("*.localhost.localdomain")).to eq("must not target localhost")
    end

    it "rejects hostnames longer than 253 characters" do
      expect(described_class.invalid_reason(("a" * 251) + ".io")).to eq("is longer than 253 characters")
    end
  end

  describe ".matches?" do
    it "matches exact hosts case-insensitively" do
      expect(described_class.matches?("api.example.com", "API.EXAMPLE.COM")).to be(true)
      expect(described_class.matches?("api.example.com", "other.example.com")).to be(false)
    end

    it "matches subdomains for leading-wildcard patterns" do
      expect(described_class.matches?("*.packages.example.com", "npm.packages.example.com")).to be(true)
      expect(described_class.matches?("*.packages.example.com", "packages.example.com")).to be(false)
      expect(described_class.matches?("*.packages.example.com", "evil.example.com")).to be(false)
    end
  end
end
