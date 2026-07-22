# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::Settings do
  describe ".normalize" do
    it "accepts explicit boolean override values" do
      expect(described_class.normalize("active", true)).to be(true)
      expect(described_class.normalize("active", false)).to be(false)
      expect(described_class.normalize("active", "true")).to be(true)
      expect(described_class.normalize("active", "false")).to be(false)
      expect(described_class.normalize("active", " 1 ")).to be(true)
      expect(described_class.normalize("active", " 0 ")).to be(false)
    end

    it "rejects ambiguous boolean-like strings" do
      expect {
        described_class.normalize("active", "foo")
      }.to raise_error(ArgumentError, /Invalid boolean override/)

      expect {
        described_class.normalize("active", "no")
      }.to raise_error(ArgumentError, /Invalid boolean override/)
    end
  end
end
