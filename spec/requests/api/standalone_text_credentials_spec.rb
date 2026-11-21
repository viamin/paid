# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Standalone text credentials" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:runner) { create(:runner, user: user, runner_key: "codex") }
  let(:valid_codex_auth) { file_fixture("codex_auth_valid.json").read }

  def materialization_double(secret: "materialized")
    Runners::SubscriptionAuthProviders::Materialization.new(
      supported: true, mode: "native_file", env: {},
      files: { "/home/agent/.codex/auth.json" => secret }, redacted_metadata: {}, error: nil
    )
  end

  def stub_codex_refresh(tokens:)
    stub_const("ENV", ENV.to_hash.merge("CODEX_OAUTH_CLIENT_ID" => "test-client-id"))
    client = instance_double(CodexLoginSessions::OAuthClient)
    allow(CodexLoginSessions::OAuthClient).to receive(:new).and_return(client)
    allow(client).to receive(:refresh_token).and_return(
      CodexLoginSessions::OAuthClient::TokenResponse.new(status: :success, tokens: tokens, error: nil)
    )
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-005
  it "materializes only the credential selected by a scoped proxy identity" do
    credential = create(:runner_credential, account: account, runner: runner)
    provider = instance_double(Runners::SubscriptionAuthProviders::Codex, materialize: materialization_double)
    allow(Runners::SubscriptionAuthProviders).to receive(:for_runner).with("codex").and_return(provider)
    identity = Containers::StandaloneTextCredential.issue(account: account, runner: runner, expires_in: 30)

    post "/api/proxy/standalone-text-credential", headers: { "Authorization" => "Bearer #{identity}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("env" => {}, "files" => { "/home/agent/.codex/auth.json" => "materialized" })
    expect(credential.reload.last_used_at).to be_present
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-005 SUBSCRIPTION-RUNNER-AUTH-005
  it "refreshes a near-expiry managed credential before materializing it" do
    credential = create(:runner_credential, account: account, runner: runner,
      token: valid_codex_auth, expires_at: 1.minute.from_now)
    refreshed = JSON.parse(valid_codex_auth)
    refreshed["tokens"]["access_token"] = "eyJserver-refreshed-access"
    stub_codex_refresh(tokens: refreshed.fetch("tokens"))
    provider = instance_double(Runners::SubscriptionAuthProviders::Codex)
    allow(provider).to receive(:materialize).and_return(materialization_double(secret: "fresh"))
    allow(Runners::SubscriptionAuthProviders).to receive(:for_runner).with("codex").and_return(provider)
    identity = Containers::StandaloneTextCredential.issue(account: account, runner: runner, expires_in: 30)

    post "/api/proxy/standalone-text-credential", headers: { "Authorization" => "Bearer #{identity}" }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(credential.reload.token)["tokens"]["access_token"]).to eq("eyJserver-refreshed-access")
    expect(provider).to have_received(:materialize)
      .with(hash_including(secret: a_string_including("eyJserver-refreshed-access")))
  end

  # @spec LLM-ROUTING-011 SUBSCRIPTION-RUNNER-AUTH-006
  it "recovers an expired unrevoked Codex credential before isolated materialization" do
    credential = create(:runner_credential, account: account, runner: runner,
      token: valid_codex_auth, expires_at: 1.minute.ago)
    refreshed = JSON.parse(valid_codex_auth)
    refreshed["tokens"]["access_token"] = "eyJserver-refreshed-access"
    refreshed["tokens"]["expires_at"] = 1.hour.from_now.utc.iso8601
    stub_codex_refresh(tokens: refreshed.fetch("tokens"))
    provider = instance_double(Runners::SubscriptionAuthProviders::Codex)
    allow(provider).to receive(:materialize).and_return(materialization_double(secret: "fresh"))
    allow(Runners::SubscriptionAuthProviders).to receive(:for_runner).with("codex").and_return(provider)
    identity = Containers::StandaloneTextCredential.issue(account: account, runner: runner, expires_in: 30)

    post "/api/proxy/standalone-text-credential", headers: { "Authorization" => "Bearer #{identity}" }

    expect(response).to have_http_status(:ok)
    expect(credential.reload).to be_active
    expect(provider).to have_received(:materialize)
      .with(hash_including(secret: a_string_including("eyJserver-refreshed-access")))
  end

  # @spec LLM-ROUTING-011 SUBSCRIPTION-RUNNER-AUTH-006
  it "rejects an expired credential when the pre-run refresh exchange fails" do
    credential = create(:runner_credential, account: account, runner: runner,
      token: valid_codex_auth, expires_at: 1.minute.from_now)
    stub_const("ENV", ENV.to_hash.merge("CODEX_OAUTH_CLIENT_ID" => "test-client-id"))
    client = instance_double(CodexLoginSessions::OAuthClient)
    allow(CodexLoginSessions::OAuthClient).to receive(:new).and_return(client)
    allow(client).to receive(:refresh_token).and_return(
      CodexLoginSessions::OAuthClient::TokenResponse.new(status: :error, tokens: nil, error: "invalid_grant")
    )
    provider = instance_double(Runners::SubscriptionAuthProviders::Codex)
    allow(provider).to receive(:materialize)
    allow(Runners::SubscriptionAuthProviders).to receive(:for_runner).with("codex").and_return(provider)
    identity = Containers::StandaloneTextCredential.issue(account: account, runner: runner, expires_in: 30)

    post "/api/proxy/standalone-text-credential", headers: { "Authorization" => "Bearer #{identity}" }

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq("error" => "Managed subscription credential requires reconnecting")
    expect(credential.reload.token).to eq(valid_codex_auth)
    expect(provider).not_to have_received(:materialize)
  end

  # @spec LLM-ROUTING-011 SUBSCRIPTION-RUNNER-AUTH-006
  it "uses an older fresh credential when the newest expired credential cannot refresh" do
    fresh = create(:runner_credential, account: account, runner: runner, token: valid_codex_auth,
      expires_at: 1.hour.from_now)
    expired = JSON.parse(valid_codex_auth).tap { |payload| payload["tokens"].delete("refresh_token") }
    create(:runner_credential, account: account, runner: runner, token: JSON.generate(expired), expires_at: 1.minute.ago)
    provider = instance_double(Runners::SubscriptionAuthProviders::Codex)
    allow(provider).to receive(:materialize).and_return(materialization_double)
    allow(Runners::SubscriptionAuthProviders).to receive(:for_runner).with("codex").and_return(provider)
    identity = Containers::StandaloneTextCredential.issue(account: account, runner: runner, expires_in: 30)

    post "/api/proxy/standalone-text-credential", headers: { "Authorization" => "Bearer #{identity}" }

    expect(response).to have_http_status(:ok)
    expect(provider).to have_received(:materialize).with(hash_including(secret: fresh.token))
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-005
  it "materializes an API key only under the signed identity's requested environment names" do
    api_key = create(:runner_api_key, user: user, api_service_type: "openai", api_key: "selected-secret")
    runner.update!(auth_type: "api_key", provider_api_key: api_key)
    identity = Containers::StandaloneTextCredential.issue(account: account, runner: runner,
      expires_in: 30, env_keys: [ "OPENAI_API_KEY" ])

    post "/api/proxy/standalone-text-credential", headers: { "Authorization" => "Bearer #{identity}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("env" => { "OPENAI_API_KEY" => "selected-secret" }, "files" => {})
  end

  # @spec LLM-ROUTING-002 LLM-ROUTING-006
  it "rejects an invalid identity without exposing credential material" do
    post "/api/proxy/standalone-text-credential", headers: { "Authorization" => "Bearer invalid" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Invalid standalone text credential")
  end

  # @spec LLM-ROUTING-002 LLM-ROUTING-006
  it "rejects an identity when its selected runner is discarded before materialization" do
    create(:runner_credential, account: account, runner: runner)
    identity = Containers::StandaloneTextCredential.issue(account: account, runner: runner, expires_in: 30)
    runner.update_column(:discarded_at, Time.current)

    post "/api/proxy/standalone-text-credential", headers: { "Authorization" => "Bearer #{identity}" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Invalid standalone text credential")
  end
end
