# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Standalone text credentials" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:runner) { create(:runner, user: user, runner_key: "codex") }

  # @spec LLM-ROUTING-003 LLM-ROUTING-005
  it "materializes only the credential selected by a scoped proxy identity" do
    credential = create(:runner_credential, account: account, runner: runner)
    materialization = Runners::SubscriptionAuthProviders::Materialization.new(
      supported: true, mode: "native_file", env: {},
      files: { "/home/agent/.codex/auth.json" => "materialized" }, redacted_metadata: {}, error: nil
    )
    provider = instance_double(Runners::SubscriptionAuthProviders::Codex, materialize: materialization)
    allow(Runners::SubscriptionAuthProviders).to receive(:for_runner).with("codex").and_return(provider)
    identity = Containers::StandaloneTextCredential.issue(account: account, runner: runner, expires_in: 30)

    post "/api/proxy/standalone-text-credential", headers: { "Authorization" => "Bearer #{identity}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("env" => {}, "files" => { "/home/agent/.codex/auth.json" => "materialized" })
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
