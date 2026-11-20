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

  # @spec API-CONVERSATION-DELEGATION-001
  it "streams text to the chat client before execution finishes without forwarding tool events" do
    chunks = []
    allow(executor).to receive(:execute) do |_command, **options|
      packets = [
        { type: "event", payload: { type: "response_started" } },
        { type: "event", payload: { type: "text_delta", content: "Hello " } },
        { type: "event", payload: { type: "tool_call_delta", arguments_json: "{}" } },
        { type: "event", payload: { type: "text_delta", content: "world" } },
        { type: "result", payload: { status: "succeeded", content: "Hello world", tool_calls: [] } }
      ]
      # Docker output may split a JSON line or combine several packets.
      output = packets.map { |packet| JSON.generate(packet) }.join("\n") + "\n"
      output.bytes.each_slice(17) do |bytes|
        options[:output_observer].call(:stdout, bytes.pack("C*"))
      end
      expect(chunks).to eq([ "Hello ", "world" ])
    end

    result = isolated_client.call([ { role: "user", content: "Hello" } ], on_chunk: chunks.method(:<<))

    expect(result[:content]).to eq("Hello world")
    expect(chunks).to eq([ "Hello ", "world" ])
  end

  # @spec API-CONVERSATION-DELEGATION-001, API-CONVERSATION-DELEGATION-007
  it "delivers only completed tool calls to the chat client with provider IDs and arguments intact" do
    arguments = '{"status":"completed","type":"text_delta"}'
    state = { protocol: "responses", output: [ { type: "function_call", call_id: "provider_1" } ] }
    allow(executor).to receive(:execute) do |_command, **options|
      options[:output_observer].call(:stdout, JSON.generate(
        type: "result", payload: { status: "partial", content: "", provider_state: state,
          tool_calls: [
            { id: "harness_1", provider_id: "provider_1", name: "list_projects", arguments_json: arguments, status: "completed" },
            { id: "harness_2", provider_id: "provider_2", name: "create_issue", arguments_json: "{", status: "incomplete" }
          ] }
      ) + "\n")
    end

    result = isolated_client.call([ { role: "user", content: "List projects" } ])

    expect(result[:tool_calls]).to eq([
      { id: "provider_1", name: "list_projects", arguments: arguments }
    ])
    expect(result[:provider_state]).to eq(state.deep_symbolize_keys)
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
    expect(received).to eq([ { type: :text_delta, content: "Hello" } ])
    expect(executor).to have_received(:close).once
  end

  # @spec API-CONVERSATION-DELEGATION-001
  it "restores completed tool-call statuses across the container JSON boundary" do
    transport = described_class.new(chat_session:, runner:, api_key: "secret-api-key", executor: executor)
    allow(executor).to receive(:execute) do |_command, **options|
      options[:output_observer].call(:stdout, JSON.generate(
        type: "result", payload: { status: "succeeded", content: "",
          tool_calls: [ { id: "call_1", name: "list_projects", arguments_json: "{}", status: "completed" } ] }
      ) + "\n")
    end

    expect(transport.call(request)[:tool_calls]).to eq([
      { id: "call_1", name: "list_projects", arguments_json: "{}", status: :completed }
    ])
  end

  # @spec CHAT-ISOLATION-001
  it "preserves the parent request deadline for container inference" do
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    request_with_deadline = request.merge(
      cancellation: ChatSessions::HarnessTransport::DeadlineCancellation.new(deadline: deadline)
    )
    executor_options = capture_executor_options
    transport = described_class.new(chat_session:, runner:, api_key: "secret-api-key")
    stub_deadline_execution(deadline)

    transport.call(request_with_deadline)

    expect(executor_options.call).to include(timeout: be > 0, deadline: deadline)
    expect(executor_options.call.fetch(:timeout)).to be <= 30
    expect(described_class::RUNNER).to include("request[:cancellation] = DeadlineCancellation.new(deadline: deadline)")
  end

  # @spec CHAT-ISOLATION-001
  it "does not reuse a prior result when a consecutive execution emits no result" do
    transport = described_class.new(chat_session:, runner:, api_key: "secret-api-key", executor: executor)
    allow(Containers::StandaloneTextExecutor).to receive(:new).and_return(executor)
    allow(executor).to receive(:execute).and_invoke(
      lambda do |_command, **options|
        options[:output_observer].call(:stdout,
          '{"type":"result","payload":{"status":"succeeded","content":"First","model":"gpt-test"}}' + "\n")
      end,
      ->(_command, **) { }
    )

    expect(transport.call(request)).to include(status: :succeeded, content: "First")
    expect { transport.call(request) }
      .to raise_error(AgentHarness::ProviderError, "Isolated chat execution returned no result")
  end

  def capture_executor_options
    options = nil
    allow(Containers::StandaloneTextExecutor).to receive(:new) { |**new_options| options = new_options; executor }
    -> { options }
  end

  def isolated_client
    transport = described_class.new(chat_session:, runner:, api_key: "secret-api-key", executor: executor)
    ChatSessions::BuildLlmClient::HttpClient.new(
      chat_session:, provider: :openai, protocol: :responses, endpoint: "https://api.openai.com/v1",
      api_key: "secret-api-key", model: "gpt-test", chat_transport: transport
    )
  end

  def stub_deadline_execution(deadline)
    allow(executor).to receive(:execute) do |_command, **options|
      expect(JSON.parse(options[:stdin_data])["deadline"]).to eq(deadline)
      expect(options[:timeout]).to be > 0
      expect(options[:timeout]).to be <= 30
      options[:output_observer].call(:stdout,
        '{"type":"result","payload":{"status":"succeeded","content":"Hello","model":"gpt-test"}}' + "\n")
    end
  end
end
