# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Request do
  let(:project) { create(:project) }
  let(:owner) { project.effective_owner }
  let(:runner) do
    create(:runner, user: owner, runner_key: "codex",
      tier_models: { "mid" => { "model_id" => "runner-mid", "provider_id" => 17 } })
  end
  let(:run) { create(:agent_run, project: project, runner: runner, final_runner: runner.routing_key) }
  let(:provider_class) { class_double(AgentHarness::Providers::Codex) }
  let(:provider) { instance_double(AgentHarness::Providers::Codex) }
  let(:response) { instance_double(AgentHarness::Response, success?: true, output: "ok") }

  before do
    allow(AgentHarness).to receive(:provider_class).with(:codex).and_return(provider_class)
    allow(provider_class).to receive(:new).and_return(provider)
    allow(provider).to receive_messages(supports_tool_control?: true, send_message: response)
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)
  end

  # @spec LLM-ROUTING-001 LLM-ROUTING-003
  it "uses a configured subscription when its driver can disable tools" do
    owner.settings.update!(kb_chat_runner: runner.routing_key)
    allow(provider).to receive(:subscription_unset_vars).and_return([ "OPENAI_API_KEY" ])
    stub_const("ENV", ENV.to_hash.merge("ANTHROPIC_API_KEY" => "unrelated"))

    described_class.call(project: project, prompt: "Assess", timeout: 30)

    expect(AgentHarness.conductor).to have_received(:execute_direct).with("Assess", hash_including(
      provider: :codex, model: "runner-mid",
      provider_runtime: an_object_having_attributes(unset_env: [ "OPENAI_API_KEY" ])
    ))
  end

  # @spec LLM-ROUTING-001 LLM-ROUTING-002
  it "tries an authorized configured fallback after authentication fails" do
    fallback = create(:runner, user: owner, runner_key: "gemini",
      tier_models: { "mid" => { "model_id" => "gemini-mid", "provider_id" => 17 } })
    owner.settings.update!(kb_chat_runner: runner.routing_key, kb_chat_fallback_runners: [ fallback.routing_key ], fallback_enabled: true)
    allow(AgentHarness).to receive(:provider_class).with(:gemini).and_return(provider_class)
    allow(provider).to receive(:subscription_unset_vars).and_return([])
    allow(AgentHarness.conductor).to receive(:execute_direct).with(anything, hash_including(provider: :codex))
      .and_raise(AgentHarness::AuthenticationError, "Not logged in")

    expect(described_class.call(project: project, prompt: "Assess", timeout: 30)).to eq(response)

    expect(AgentHarness.conductor).to have_received(:execute_direct).with("Assess", hash_including(provider: :gemini, model: "gemini-mid"))
  end

  # @spec LLM-ROUTING-002
  it "honors disabled automatic fallback" do
    owner.settings.update!(kb_chat_runner: runner.routing_key, fallback_enabled: false)
    allow(provider).to receive(:subscription_unset_vars).and_return([])
    allow(AgentHarness.conductor).to receive(:execute_direct).and_raise(AgentHarness::AuthenticationError, "Not logged in")

    expect { described_class.call(project: project, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::AuthenticationError, "Not logged in")
    expect(AgentHarness.conductor).to have_received(:execute_direct).once
  end

  # @spec LLM-ROUTING-002
  it "rejects an actor from another account" do
    other = create(:user)

    expect { described_class.call(account: project.account, user: other, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::ConfigurationError, /No owning user/)
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec LLM-ROUTING-002
  it "honors project exclusions instead of using the configured model" do
    project.update!(model_preferences: { "excluded_model_ids" => [ "runner-mid" ] })

    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::ConfigurationError, /policy/)
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec LLM-ROUTING-002
  it "honors project tier limits when selecting a catalog default" do
    runner.update!(tier_models: {}, tier_model_ids: {})
    create(:llm_model, :openai, tier: "mid")
    project.update!(model_preferences: { "max_tier" => "low" })

    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::ConfigurationError, /policy/)
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec LLM-ROUTING-007
  it "skips an API runner whose credential-specific circuit is open" do
    credential = create(:runner_api_key, user: owner, api_service_type: "openai")
    runner.update!(auth_type: "api_key", provider_api_key: credential)
    owner.settings.update!(kb_chat_runner: runner.routing_key, fallback_enabled: false)
    create(:runner_state, :circuit_open, user: owner, runner_name: runner.state_key)

    expect { described_class.call(project: project, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::ConfigurationError, /No eligible/)
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec LLM-ROUTING-005
  it "refuses host CLI execution when the driver cannot disable tools" do
    allow(provider).to receive_messages(supports_tool_control?: false, subscription_unset_vars: [])

    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::ConfigurationError, /isolated environment or API credentials/)
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
    expect(provider).not_to have_received(:send_message)
  end

  # @spec LLM-ROUTING-005
  it "uses API text transport when an API runner cannot disable CLI tools" do
    credential = create(:runner_api_key, user: owner, api_service_type: "openai")
    runner.update!(auth_type: "api_key", provider_api_key: credential)
    allow(provider).to receive_messages(supports_tool_control?: false,
      api_key_env_var_names: [ "OPENAI_API_KEY" ], api_key_unset_vars: [])
    transport = instance_double(AgentHarness::Api::ChatTransport, call: { status: :succeeded, content: "assessment" })
    allow(AgentHarness::Api::ChatTransport).to receive(:new).and_return(transport)

    expect(described_class.call(agent_run: run, prompt: "Assess", timeout: 30)).to be_success

    expect(transport).to have_received(:call) do |request|
      expect(request[:candidates].first).to include(model: "runner-mid", credentials: { api_key: credential.api_key })
    end
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "uses the selected API credential for host requests" do
    credential = create(:runner_api_key, user: owner, api_service_type: "openai")
    runner.update!(auth_type: "api_key", provider_api_key: credential)
    transport = instance_double(AgentHarness::Api::ChatTransport, call: { status: :succeeded, content: "assessment" })
    allow(AgentHarness::Api::ChatTransport).to receive(:new).and_return(transport)

    expect(described_class.call(agent_run: run, prompt: "Assess", timeout: 30)).to be_success

    expect(transport).to have_received(:call) do |request|
      expect(request[:candidates].first).to include(credentials: { api_key: credential.api_key })
    end
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec LLM-ROUTING-001 LLM-ROUTING-003
  it "preserves a direct-outbound runner's upstream model and endpoint" do
    credential = create(:runner_api_key, user: owner, api_service_type: "deepseek")
    selected = create(:runner, :api_key, user: owner, runner_key: "opencode", provider_api_key: credential,
      config: { "opencode" => { "api_provider" => "deepseek", "model" => "deepseek-chat" } })
    owner.settings.update!(kb_chat_runner: selected.routing_key, fallback_enabled: false)
    transport = instance_double(AgentHarness::Api::ChatTransport, call: { status: :succeeded, content: "assessment" })
    allow(AgentHarness::Api::ChatTransport).to receive(:new).and_return(transport)
    allow(AgentHarness).to receive(:provider_class).with(:opencode).and_call_original

    expect(described_class.call(project: project, prompt: "Assess", timeout: 30)).to be_success

    expect(transport).to have_received(:call) do |request|
      expect(request[:candidates]).to contain_exactly(include(model: "deepseek-chat",
        endpoint: "https://api.deepseek.com/v1", credentials: { api_key: credential.api_key }))
    end
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "refuses to substitute host auth for managed subscription credentials" do
    create(:runner_credential, runner: runner, account: project.account)

    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::ConfigurationError, /Managed subscription credentials require/)
    expect(provider).not_to have_received(:send_message)
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "does not fall through to a host API key when the runner's key is missing" do
    credential = create(:runner_api_key, user: owner, api_service_type: "openai")
    runner.update!(auth_type: "api_key", provider_api_key: credential)
    credential.update_column(:api_key, "")

    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::ConfigurationError, /missing its API credential/)
    expect(provider).not_to have_received(:send_message)
  end

  # @spec LLM-ROUTING-001
  it "does not hardcode vendors in application text operations" do
    adapter_files = %w[app/services/chat_sessions/build_llm_client.rb]
    offenders = Dir[Rails.root.join("app/{services,temporal}/**/*.rb").to_s].filter_map do |path|
      next if adapter_files.any? { |adapter| path.end_with?(adapter) }

      path if File.read(path).match?(/provider: :(?:claude|anthropic|openai)\b|(?:DEFAULT_MODEL|MODEL|MODEL_VERSION) = "claude/)
    end

    expect(offenders).to be_empty
  end

  # @spec LLM-ROUTING-001 LLM-ROUTING-002
  it "does not enter the harness's implicit provider fallback from application code" do
    offenders = Dir[Rails.root.join("app/{services,temporal}/**/*.rb").to_s].select do |path|
      File.read(path).match?(/AgentHarness\.send_message\(/)
    end

    expect(offenders).to be_empty
  end
end
