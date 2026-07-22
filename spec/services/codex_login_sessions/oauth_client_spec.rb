# frozen_string_literal: true

require "rails_helper"

RSpec.describe CodexLoginSessions::OAuthClient, :no_db do
  let(:config) do
    CodexLoginSessions::OAuthConfig.new(
      client_id: "test-client-id",
      device_url: "https://auth.example/device",
      token_url: "https://auth.example/token",
      scopes: "openai/subscription offline_access"
    )
  end

  def client_with(responses)
    transport = ->(_url, _params) { responses.shift || raise("no canned response") }
    described_class.new(config: config, transport: transport)
  end

  describe "#request_device_code" do
    it "parses the device authorization response" do
      body = JSON.generate(
        "device_code" => "dev-123",
        "user_code" => "ABCD-WXYZ",
        "verification_uri" => "https://auth.example/device",
        "verification_uri_complete" => "https://auth.example/device?user_code=ABCD-WXYZ",
        "expires_in" => 900,
        "interval" => 5
      )
      response = client_with([ body ]).request_device_code

      expect(response.device_code).to eq("dev-123")
      expect(response.user_code).to eq("ABCD-WXYZ")
      expect(response.verification_uri).to eq("https://auth.example/device?user_code=ABCD-WXYZ")
      expect(response.expires_in).to eq(900)
      expect(response.interval).to eq(5)
    end

    it "raises when OAuth is not configured" do
      unconfigured = CodexLoginSessions::OAuthConfig.new(
        client_id: nil, device_url: "https://x", token_url: "https://x", scopes: "s"
      )
      client = described_class.new(config: unconfigured, transport: ->(*) { "" })

      expect { client.request_device_code }.to raise_error(CodexLoginSessions::OAuthClient::ConfigurationError)
    end
  end

  describe "#poll_token" do
    it "reports success with tokens when access_token is present" do
      body = JSON.generate(
        "access_token" => "access-1",
        "refresh_token" => "refresh-1",
        "id_token" => "id-1"
      )
      response = client_with([ body ]).poll_token("dev-123")

      expect(response.status).to eq(:success)
      expect(response.tokens).to include("access_token" => "access-1", "refresh_token" => "refresh-1")
    end

    it "reports pending on authorization_pending" do
      body = JSON.generate("error" => "authorization_pending")
      response = client_with([ body ]).poll_token("dev-123")

      expect(response.status).to eq(:pending)
    end

    it "reports slow_down and backs off" do
      body = JSON.generate("error" => "slow_down")
      response = client_with([ body ]).poll_token("dev-123")

      expect(response.status).to eq(:slow_down)
    end

    it "reports denied on access_denied" do
      body = JSON.generate("error" => "access_denied")
      response = client_with([ body ]).poll_token("dev-123")

      expect(response.status).to eq(:denied)
    end
  end
end
