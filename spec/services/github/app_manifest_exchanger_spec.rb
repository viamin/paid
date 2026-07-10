# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::AppManifestExchanger do
  let(:code) { "abc123manifestcode" }
  let(:exchange_url) { %r{/app-manifests/#{code}/conversions\z} }

  describe ".call" do
    it "exchanges the manifest code for app credentials" do
      stub_request(:post, exchange_url).to_return(
        status: 201,
        body: {
          id: 42,
          slug: "paid-agents-self-hosted",
          html_url: "https://github.com/apps/paid-agents-self-hosted",
          pem: OpenSSL::PKey::RSA.new(2048).to_pem,
          webhook_secret: "shhh"
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      result = described_class.call(code: code)

      expect(result.app_id).to eq(42)
      expect(result.slug).to eq("paid-agents-self-hosted")
      expect(result.html_url).to eq("https://github.com/apps/paid-agents-self-hosted")
      expect(result.private_key).to start_with("-----BEGIN")
      expect(result.webhook_secret).to eq("shhh")
    end

    it "raises an Error when GitHub returns an error" do
      stub_request(:post, exchange_url).to_return(
        status: 422,
        body: { message: "code expired" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      expect {
        described_class.call(code: code)
      }.to raise_error(Github::AppManifestExchanger::Error, /code expired/)
    end

    it "raises when the code is blank" do
      expect {
        described_class.call(code: "")
      }.to raise_error(Github::AppManifestExchanger::Error, /Missing GitHub manifest code/)
    end

    it "synthesizes a webhook_secret when GitHub does not return one" do
      stub_request(:post, exchange_url).to_return(
        status: 201,
        body: { id: 7, slug: "demo", pem: OpenSSL::PKey::RSA.new(2048).to_pem }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      result = described_class.call(code: code)
      expect(result.webhook_secret).to be_present
      expect(result.webhook_secret.length).to be >= 32
    end
  end
end
