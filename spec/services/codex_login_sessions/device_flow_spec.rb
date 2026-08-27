# frozen_string_literal: true

require "rails_helper"

RSpec.describe CodexLoginSessions::DeviceFlow do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:session) do
    create(:codex_login_session, account: account, created_by: user, credential_name: "Codex Connect Login")
  end

  def fake_client(device_response: nil, token_responses: [])
    double = instance_double(CodexLoginSessions::OAuthClient)
    allow(double).to receive(:request_device_code).and_return(device_response) if device_response
    if token_responses.any?
      poll = token_responses.dup
      allow(double).to receive(:poll_token) { poll.shift }
    end
    double
  end

  def device_response
    CodexLoginSessions::OAuthClient::DeviceResponse.new(
      device_code: "dev-123", user_code: "ABCD-WXYZ",
      verification_uri: "https://auth.example/device?user_code=ABCD-WXYZ",
      expires_in: 900, interval: 5
    )
  end

  describe "#start!" do
    it "stores the device code, user code, and verification URI" do
      flow = described_class.new(session: session, client: fake_client(device_response: device_response))

      flow.start!
      session.reload

      expect(session).to be_awaiting_authorization
      expect(session.device_code).to eq("dev-123")
      expect(session.user_code).to eq("ABCD-WXYZ")
      expect(session.verification_uri).to eq("https://auth.example/device?user_code=ABCD-WXYZ")
    end

    it "fails the session when the device request raises" do
      client = fake_client
      allow(client).to receive(:request_device_code).and_raise(CodexLoginSessions::OAuthClient::DeviceRequestError, "boom")
      flow = described_class.new(session: session, client: client)

      flow.start!
      session.reload

      expect(session).to be_failed
      expect(session.error_message).to include("boom")
    end
  end

  describe "#poll!" do
    before do
      described_class.new(session: session, client: fake_client(device_response: device_response)).start!
      session.reload
    end

    it "persists the captured credential on success" do
      tokens = { "id_token" => "id-1", "access_token" => "access-1", "refresh_token" => "refresh-1" }
      client = fake_client(token_responses: [
        CodexLoginSessions::OAuthClient::TokenResponse.new(status: :success, tokens: tokens, error: nil)
      ])
      result = described_class.new(session: session, client: client).poll!(session_token: session.session_token)

      expect(result[:completed]).to be(true)
      session.reload
      expect(session).to be_completed
      expect(session.runner_credential).not_to be_nil
      expect(session.runner_credential.runner_key).to eq("codex")
      expect(session.runner_credential.auth_kind).to eq("oauth_token")

      parsed = JSON.parse(session.runner_credential.token)
      expect(parsed["tokens"]["access_token"]).to eq("access-1")
      expect(parsed["tokens"]["refresh_token"]).to eq("refresh-1")
    end

    it "stores the credential under the requested target runner key" do
      session.update!(metadata: { "target_runner_key" => "opencode" })
      tokens = { "id_token" => "id-1", "access_token" => "access-1", "refresh_token" => "refresh-1" }
      client = fake_client(token_responses: [
        CodexLoginSessions::OAuthClient::TokenResponse.new(status: :success, tokens: tokens, error: nil)
      ])

      described_class.new(session: session, client: client).poll!(session_token: session.session_token)

      expect(session.reload.runner_credential.runner_key).to eq("opencode")
    end

    it "keeps the session pending while authorization is not complete" do
      client = fake_client(token_responses: [
        CodexLoginSessions::OAuthClient::TokenResponse.new(status: :pending, tokens: nil, error: nil)
      ])
      result = described_class.new(session: session, client: client).poll!(session_token: session.session_token)

      expect(result[:completed]).to be(false)
      expect(result[:status]).to eq(:pending)
      expect(session.reload).to be_polling
    end

    it "backs off on slow_down" do
      client = fake_client(token_responses: [
        CodexLoginSessions::OAuthClient::TokenResponse.new(status: :slow_down, tokens: nil, error: nil)
      ])
      described_class.new(session: session, client: client).poll!(session_token: session.session_token)

      expect(session.reload.poll_interval).to be > 5
    end

    it "fails the session on access denied" do
      session.update!(metadata: { "target_runner_key" => "opencode" })
      client = fake_client(token_responses: [
        CodexLoginSessions::OAuthClient::TokenResponse.new(status: :denied, tokens: nil, error: "access_denied")
      ])
      allow(Audit::RecordEvent).to receive(:call).and_call_original

      result = described_class.new(session: session, client: client).poll!(session_token: session.session_token)

      expect(result[:status]).to eq(:failed)
      expect(session.reload).to be_failed
      expect(Audit::RecordEvent).to have_received(:call).with(
        hash_including(
          action: "runner.codex_login_failed",
          metadata: hash_including(
            credential_name: session.credential_name,
            runner_key: "opencode",
            details: [ "authorization_denied" ]
          )
        )
      )
    end

    it "fails the session when the OAuth response carries no usable tokens" do
      client = fake_client(token_responses: [
        CodexLoginSessions::OAuthClient::TokenResponse.new(status: :success, tokens: {}, error: nil)
      ])
      result = described_class.new(session: session, client: client).poll!(session_token: session.session_token)

      expect(result[:status]).to eq(:failed)
      expect(result[:error]).to include("Connect Codex login did not return a usable OAuth session")
      expect(session.reload).to be_failed
      expect(session.runner_credential).to be_nil
    end
  end
end
