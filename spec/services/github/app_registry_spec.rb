# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::AppRegistry do
  describe ".configured?" do
    around do |example|
      original_id = ENV.delete("PAID_AGENT_APP_ID")
      original_key = ENV.delete("PAID_AGENT_APP_PRIVATE_KEY")
      original_slug = ENV.delete("PAID_AGENT_APP_SLUG")
      example.run
    ensure
      ENV["PAID_AGENT_APP_ID"] = original_id
      ENV["PAID_AGENT_APP_PRIVATE_KEY"] = original_key
      ENV["PAID_AGENT_APP_SLUG"] = original_slug
    end

    it "returns false when no credentials are set" do
      expect(described_class.configured?).to be(false)
    end

    it "returns false when only app_id is set" do
      ENV["PAID_AGENT_APP_ID"] = "123"
      expect(described_class.configured?).to be(false)
    end

    it "returns true when both app_id and valid private key are set via ENV" do
      key = OpenSSL::PKey::RSA.new(2048).to_pem
      ENV["PAID_AGENT_APP_ID"] = "123"
      ENV["PAID_AGENT_APP_PRIVATE_KEY"] = key
      expect(described_class.configured?).to be(true)
    end

    it "returns false when private key is not parseable" do
      ENV["PAID_AGENT_APP_ID"] = "123"
      ENV["PAID_AGENT_APP_PRIVATE_KEY"] = "invalid-key"
      expect(described_class.configured?).to be(false)
    end
  end

  describe ".slug" do
    around do |example|
      original = ENV.delete("PAID_AGENT_APP_SLUG")
      example.run
    ensure
      ENV["PAID_AGENT_APP_SLUG"] = original
    end

    it "returns default slug when not configured" do
      expect(described_class.slug).to eq("paid-agents")
    end

    it "returns ENV slug when configured" do
      ENV["PAID_AGENT_APP_SLUG"] = "custom-paid"
      expect(described_class.slug).to eq("custom-paid")
    end
  end

  describe ".bot_login" do
    it "returns slug with [bot] suffix" do
      expect(described_class.bot_login).to eq("paid-agents[bot]")
    end
  end

  describe ".bot_logins" do
    it "returns slug and bot_login" do
      expect(described_class.bot_logins).to contain_exactly("paid-agents", "paid-agents[bot]")
    end
  end
end
