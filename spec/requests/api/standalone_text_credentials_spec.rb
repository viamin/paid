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
    allow(AgentHarness::Authentication).to receive_messages(
      exchange_refresh_token_supported?: true, exchange_refresh_token: refreshed)
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

  # @spec LLM-ROUTING-005 SUBSCRIPTION-RUNNER-AUTH-005
  it "still materializes when the pre-run refresh exchange fails" do
    credential = create(:runner_credential, account: account, runner: runner,
      token: valid_codex_auth, expires_at: 1.minute.from_now)
    allow(AgentHarness::Authentication).to receive_messages(
      exchange_refresh_token_supported?: true,
      exchange_refresh_token: { "error" => "invalid_grant" })
    provider = instance_double(Runners::SubscriptionAuthProviders::Codex, materialize: materialization_double)
    allow(Runners::SubscriptionAuthProviders).to receive(:for_runner).with("codex").and_return(provider)
    identity = Containers::StandaloneTextCredential.issue(account: account, runner: runner, expires_in: 30)

    post "/api/proxy/standalone-text-credential", headers: { "Authorization" => "Bearer #{identity}" }

    expect(response).to have_http_status(:ok)
    expect(credential.reload.token).to eq(valid_codex_auth)
    expect(credential.reload.last_used_at).to be_present
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
end
