# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::IsolatedTransport, type: :service do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:runner) do
    create(:runner, user: user, runner_key: "opencode", auth_type: "api_key",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openai"),
      config: { "opencode" => { "api_provider" => "openai", "model" => "gpt-test" } })
  end
  let(:chat_session) { create(:chat_session, account: account, created_by: user, runner: runner) }
  let(:executor) { instance_double(Containers::StandaloneTextExecutor, close: nil) }
  let(:credentialless_candidate) do
    { "provider" => "openai", "model" => "gpt-test", "protocol" => "responses",
      "authentication_mode" => "api_key", "endpoint" => "https://api.openai.com/v1" }
  end
  # Production shape from BuildLlmClient::HttpClient#candidate: the request
  # arrives carrying the provider API key in each candidate's credentials.
  let(:request) do
    { operation: :chat, candidates: [ {
      provider: :openai, model: "gpt-test", protocol: :responses,
      authentication_mode: :api_key, credentials: { api_key: "secret-api-key" },
      endpoint: "https://api.openai.com/v1"
    } ], stream: true }
  end

  # @spec CHAT-ISOLATION-001
  it "runs the normalized chat request in the disposable executor without serializing its API key" do
    transport = described_class.new(chat_session:, runner:, api_key: "secret-api-key", executor: executor)
    output = <<~JSON
      {"type":"event","payload":{"type":"text_delta","content":"Hello"}}
      {"type":"result","payload":{"status":"succeeded","content":"Hello","model":"gpt-test","usage":{"input_tokens":2,"output_tokens":1}}}
    JSON
    received = []
    allow(executor).to receive(:execute) do |_command, **options|
      expect(options[:stdin_data]).not_to include("secret-api-key")
      payload = JSON.parse(options[:stdin_data])
      expect(payload["candidates"]).to eq([ credentialless_candidate ])
      expect(payload["credential_env"]).to eq("OPENAI_API_KEY")
      expect(options[:env]).to include("OPENAI_API_KEY" => "secret-api-key")
      options[:output_observer].call(:stdout, output)
      AgentHarness::CommandExecutor::Result.new(stdout: "", stderr: "", exit_code: 0, duration: 0)
    end

    response = transport.call(request, &received.method(:<<))

    expect(response).to include(status: :succeeded, content: "Hello", model: "gpt-test")
    expect(received).to eq([ { type: "text_delta", content: "Hello" } ])
    expect(executor).to have_received(:close).once
  end
end
