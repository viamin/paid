# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::AppJwt do
  let(:app_id) { "123456" }
  let(:private_key) { OpenSSL::PKey::RSA.new(2048).to_pem }

  describe ".sign" do
    it "returns a JWT string" do
      jwt = described_class.sign(app_id: app_id, private_key: private_key)
      expect(jwt).to be_a(String)
      expect(jwt).to include(".")
    end

    it "raises ConfigurationError when app_id is blank" do
      expect {
        described_class.sign(app_id: "", private_key: private_key)
      }.to raise_error(Github::AppJwt::ConfigurationError, /app id/i)
    end

    it "raises ConfigurationError when private_key is blank" do
      expect {
        described_class.sign(app_id: app_id, private_key: "")
      }.to raise_error(Github::AppJwt::ConfigurationError, /private key/i)
    end

    it "raises ConfigurationError when private_key is not valid PEM" do
      expect {
        described_class.sign(app_id: app_id, private_key: "not-a-key")
      }.to raise_error(Github::AppJwt::ConfigurationError, /invalid/i)
    end
  end

  describe ".private_key_parseable?" do
    it "returns true for a valid PEM key" do
      expect(described_class.private_key_parseable?(private_key)).to be(true)
    end

    it "returns false for empty string" do
      expect(described_class.private_key_parseable?("")).to be(false)
    end

    it "returns false for nil" do
      expect(described_class.private_key_parseable?(nil)).to be(false)
    end

    it "returns false for invalid key content" do
      expect(described_class.private_key_parseable?("not-a-valid-key")).to be(false)
    end
  end
end
