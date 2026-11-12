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
  let(:standalone_executor) { instance_double(Containers::StandaloneTextExecutor) }

  before do
    allow(AgentHarness).to receive(:provider_class).with(:codex).and_return(provider_class)
    allow(provider_class).to receive(:new).and_return(provider)
    allow(provider).to receive_messages(supports_tool_control?: true, send_message: response)
    allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)
    allow(Containers::StandaloneTextExecutor).to receive(:new).and_return(standalone_executor)
    allow(standalone_executor).to receive(:close)
  end

  # @spec LLM-ROUTING-001 LLM-ROUTING-003 LLM-ROUTING-005
  it "uses a disposable text container for a configured subscription" do
    owner.settings.update!(kb_chat_runner: runner.routing_key)
    allow(provider).to receive(:subscription_unset_vars).and_return([ "OPENAI_API_KEY" ])
    stub_const("ENV", ENV.to_hash.merge("ANTHROPIC_API_KEY" => "unrelated"))

    described_class.call(project: project, prompt: "Assess", timeout: 30)

    expect(Containers::StandaloneTextExecutor).to have_received(:new).with(
      account: project.account, runner: runner, timeout: 30
    )
    expect(provider).to have_received(:send_message).with(hash_including(prompt: "Assess",
      tools: :none, dangerous_mode: false,
      provider_runtime: an_object_having_attributes(unset_env: [ "OPENAI_API_KEY" ])
    ))
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
    expect(standalone_executor).to have_received(:close)
  end

  # @spec LLM-ROUTING-005 LLM-ROUTING-006
  it "does not reuse a stale live-run container handle for a text request" do
    run.update_columns(container_id: "stale-run-container", runner_handle: { "identifier" => "stale-run-container" })
    allow(provider).to receive(:subscription_unset_vars).and_return([])

    expect(described_class.call(agent_run: run, prompt: "Assess", timeout: 30)).to eq(response)

    expect(Containers::StandaloneTextExecutor).to have_received(:new).with(
      account: project.account, runner: runner, timeout: 30
    )
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec LLM-ROUTING-001 LLM-ROUTING-002
  it "tries an authorized configured fallback after authentication fails" do
    fallback = create(:runner, user: owner, runner_key: "gemini",
      tier_models: { "mid" => { "model_id" => "gemini-mid", "provider_id" => 17 } })
    owner.settings.update!(kb_chat_runner: runner.routing_key, kb_chat_fallback_runners: [ fallback.routing_key ], fallback_enabled: true)
    allow(AgentHarness).to receive(:provider_class).with(:gemini).and_return(provider_class)
    allow(provider).to receive(:subscription_unset_vars).and_return([])
    attempts = 0
    allow(provider).to receive(:send_message) do
      attempts += 1
      raise AgentHarness::AuthenticationError, "Not logged in" if attempts == 1

      response
    end

    expect(described_class.call(project: project, prompt: "Assess", timeout: 30)).to eq(response)

    expect(provider).to have_received(:send_message).with(hash_including(prompt: "Assess")).twice
  end

  # @spec PARTIAL-CLOSEOUT-049
  it "tries an explicit audit fallback after the run's pinned runner fails" do
    fallback = create(:runner, user: owner, runner_key: "gemini",
      tier_models: { "mid" => { "model_id" => "gemini-mid", "provider_id" => 17 } })
    allow(AgentHarness).to receive(:provider_class).with(:gemini).and_return(provider_class)
    allow(provider).to receive(:subscription_unset_vars).and_return([])
    attempts = [ AgentHarness::TimeoutError.new("runner timed out"), response ]
    allow(provider).to receive(:send_message) do
      result = attempts.shift
      raise result if result.is_a?(Exception)

      result
    end

    expect(described_class.call(agent_run: run, prompt: "Assess", timeout: 120,
      per_runner_timeout: 60, fallback_runner_identifiers: [ fallback.routing_key ])).to eq(response)

    expect(provider).to have_received(:send_message).with(hash_including(prompt: "Assess")).twice
    expect(Containers::StandaloneTextExecutor).to have_received(:new).with(
      account: project.account, runner: fallback, timeout: 60
    )
  end

  # @spec PARTIAL-CLOSEOUT-048 PARTIAL-CLOSEOUT-049
  it "surfaces a later fallback's permanent failure over an earlier transient failure" do
    fallback = create(:runner, user: owner, runner_key: "gemini",
      tier_models: { "mid" => { "model_id" => "gemini-mid", "provider_id" => 17 } })
    allow(AgentHarness).to receive(:provider_class).with(:gemini).and_return(provider_class)
    allow(provider).to receive(:subscription_unset_vars).and_return([])
    attempts = [
      AgentHarness::TimeoutError.new("runner timed out"),
      AgentHarness::AuthenticationError.new("Not logged in")
    ]
    allow(provider).to receive(:send_message) { raise attempts.shift }

    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 120,
      fallback_runner_identifiers: [ fallback.routing_key ]) }
      .to raise_error(AgentHarness::AuthenticationError, "Not logged in")
  end

  # @spec PARTIAL-CLOSEOUT-048 PARTIAL-CLOSEOUT-049
  it "surfaces the pinned runner's permanent failure over a later fallback's transport failure" do
    fallback = create(:runner, user: owner, runner_key: "gemini",
      tier_models: { "mid" => { "model_id" => "gemini-mid", "provider_id" => 17 } })
    allow(AgentHarness).to receive(:provider_class).with(:gemini).and_return(provider_class)
    allow(provider).to receive(:subscription_unset_vars).and_return([])
    attempts = [
      AgentHarness::AuthenticationError.new("Not logged in"),
      AgentHarness::TimeoutError.new("runner timed out")
    ]
    allow(provider).to receive(:send_message) { raise attempts.shift }

    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 120,
      fallback_runner_identifiers: [ fallback.routing_key ]) }
      .to raise_error(AgentHarness::AuthenticationError, "Not logged in")
  end

  # @spec PARTIAL-CLOSEOUT-049
  it "fails with a timeout when the overall budget leaves no time for a candidate" do
    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 0) }
      .to raise_error(AgentHarness::TimeoutError, /timeout exhausted/)
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec PARTIAL-CLOSEOUT-049
  it "preserves a transient failure when a later fallback is unavailable" do
    fallback = create(:runner, user: owner, runner_key: "gemini", enabled_for_agent_runs: false)
    allow(provider).to receive(:subscription_unset_vars).and_return([])
    allow(provider).to receive(:send_message)
      .and_raise(AgentHarness::TimeoutError, "runner timed out")

    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 120,
      fallback_runner_identifiers: [ fallback.routing_key ]) }
      .to raise_error(AgentHarness::TimeoutError, "runner timed out")
  end

  # @spec PARTIAL-CLOSEOUT-049
  it "keeps an unsuccessful response retryable when a later fallback is unavailable" do
    fallback = create(:runner, user: owner, runner_key: "gemini", enabled_for_agent_runs: false)
    failed_response = instance_double(AgentHarness::Response, success?: false)
    allow(provider).to receive_messages(subscription_unset_vars: [], send_message: failed_response)

    expect(described_class.call(agent_run: run, prompt: "Assess", timeout: 120,
      fallback_runner_identifiers: [ fallback.routing_key ])).to eq(failed_response)
  end

  # @spec PARTIAL-CLOSEOUT-049
  it "does not use a fallback runner owned by another account" do
    foreign_runner = create(:runner, user: create(:user), runner_key: "gemini")
    allow(provider).to receive(:subscription_unset_vars).and_return([])
    allow(provider).to receive(:send_message)
      .and_raise(AgentHarness::TimeoutError, "runner timed out")

    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 120,
      per_runner_timeout: 60, fallback_runner_identifiers: [ foreign_runner.routing_key ]) }
      .to raise_error(AgentHarness::TimeoutError)
    expect(provider).to have_received(:send_message).once
    expect(Containers::StandaloneTextExecutor).to have_received(:new).once
  end

  # @spec LLM-ROUTING-001 MODEL-POLICY-024
  it "does not let a ZDR fallback disqualify the non-ZDR primary" do
    fallback = create(:runner, user: owner, runner_key: "gemini", zero_data_retention: true,
      tier_models: { "mid" => { "model_id" => "gemini-mid", "provider_id" => 17 } })
    owner.settings.update!(kb_chat_runner: runner.routing_key,
      kb_chat_fallback_runners: [ fallback.routing_key ], fallback_enabled: true)
    allow(provider).to receive(:subscription_unset_vars).and_return([])

    expect(described_class.call(project: project, prompt: "Assess", timeout: 30)).to eq(response)

    expect(provider).to have_received(:send_message).with(hash_including(prompt: "Assess")).once
  end

  # @spec MODEL-POLICY-024
  it "preserves a snapshotted ZDR requirement after the runner declaration is disabled" do
    run.update!(external_metadata: run.external_metadata.merge("zdr_required" => true))

    expect { described_class.call(agent_run: run, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::ConfigurationError, /zero data retention policy/)
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec LLM-ROUTING-002
  it "honors disabled automatic fallback" do
    owner.settings.update!(kb_chat_runner: runner.routing_key, fallback_enabled: false)
    allow(provider).to receive(:subscription_unset_vars).and_return([])
    allow(provider).to receive(:send_message).and_raise(AgentHarness::AuthenticationError, "Not logged in")

    expect { described_class.call(project: project, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::AuthenticationError, "Not logged in")
    expect(provider).to have_received(:send_message).once
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
    allow(provider).to receive(:subscription_unset_vars).and_return([])

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
  it "uses the isolated route when the driver cannot disable tools" do
    allow(provider).to receive_messages(supports_tool_control?: false, subscription_unset_vars: [])

    expect(described_class.call(agent_run: run, prompt: "Assess", timeout: 30)).to eq(response)
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
    expect(provider).to have_received(:send_message).with(hash_including(prompt: "Assess"))
    expect(Containers::StandaloneTextExecutor).to have_received(:new).with(
      account: project.account, runner: runner, timeout: 30
    )
  end

  # @spec LLM-ROUTING-005
  it "uses a disposable text container when an API runner cannot disable CLI tools" do
    credential = create(:runner_api_key, user: owner, api_service_type: "openai")
    runner.update!(auth_type: "api_key", provider_api_key: credential)
    allow(provider).to receive_messages(supports_tool_control?: false,
      api_key_env_var_names: [ "OPENAI_API_KEY" ], api_key_unset_vars: [])
    expect(described_class.call(agent_run: run, prompt: "Assess", timeout: 30)).to eq(response)

    expect(Containers::StandaloneTextExecutor).to have_received(:new).with(
      account: project.account, runner: runner, timeout: 30
    )
    expect(provider).to have_received(:send_message).with(hash_including(prompt: "Assess"))
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec MODEL-POLICY-016
  it "isolates OpenRouter requests that require ZDR" do
    credential = create(:runner_api_key, user: owner, api_service_type: "openrouter")
    selected = create(:runner, :api_key, user: owner, runner_key: "opencode", provider_api_key: credential,
      zero_data_retention: true,
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "meta-llama/llama-4-maverick" } })
    owner.settings.update!(kb_chat_runner: selected.routing_key, fallback_enabled: false)
    allow(AgentHarness).to receive(:provider_class).with(:opencode).and_return(provider_class)
    allow(provider).to receive_messages(api_key_env_var_names: [ "OPENROUTER_API_KEY" ], api_key_unset_vars: [])

    expect(described_class.call(project: project, prompt: "Assess", timeout: 30)).to eq(response)
    expect(provider).to have_received(:send_message)
  end

  # @spec MODEL-POLICY-015
  it "preserves restricted-project ZDR when the selected runner declaration is off" do
    project.update!(data_classification: "restricted")
    credential = create(:runner_api_key, user: owner, api_service_type: "openrouter")
    selected = create(:runner, :api_key, user: owner, runner_key: "opencode", provider_api_key: credential,
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "meta-llama/llama-4-maverick" } })
    owner.settings.update!(kb_chat_runner: selected.routing_key, fallback_enabled: false)
    allow(AgentHarness).to receive(:provider_class).with(:opencode).and_return(provider_class)
    allow(provider).to receive_messages(api_key_env_var_names: [ "OPENROUTER_API_KEY" ], api_key_unset_vars: [])

    expect(described_class.call(project: project, prompt: "Assess", timeout: 30)).to eq(response)
    expect(provider).to have_received(:send_message)
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "uses the selected API credential in isolated requests" do
    credential = create(:runner_api_key, user: owner, api_service_type: "openai")
    runner.update!(auth_type: "api_key", provider_api_key: credential)
    allow(provider).to receive_messages(api_key_env_var_names: [ "OPENAI_API_KEY" ], api_key_unset_vars: [])

    expect(described_class.call(agent_run: run, prompt: "Assess", timeout: 30)).to eq(response)

    expect(provider).to have_received(:send_message)
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec LLM-ROUTING-001 LLM-ROUTING-003
  it "preserves a direct-outbound runner's upstream model and endpoint" do
    credential = create(:runner_api_key, user: owner, api_service_type: "deepseek")
    selected = create(:runner, :api_key, user: owner, runner_key: "opencode", provider_api_key: credential,
      config: { "opencode" => { "api_provider" => "deepseek", "model" => "deepseek-chat" } })
    owner.settings.update!(kb_chat_runner: selected.routing_key, fallback_enabled: false)
    allow(AgentHarness).to receive(:provider_class).with(:opencode).and_return(provider_class)
    allow(provider).to receive_messages(api_key_env_var_names: [ "DEEPSEEK_API_KEY" ], api_key_unset_vars: [])

    expect(described_class.call(project: project, prompt: "Assess", timeout: 30)).to eq(response)
    expect(provider).to have_received(:send_message).with(hash_including(
      provider_runtime: an_object_having_attributes(model: "deepseek/deepseek-chat",
        env: hash_including("OPENAI_BASE_URL" => "https://api.deepseek.com/v1"))
    ))
    expect(AgentHarness.conductor).not_to have_received(:execute_direct)
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "provisions managed subscription credentials through the disposable executor" do
    create(:runner_credential, runner: runner, account: project.account)

    allow(provider).to receive(:subscription_unset_vars).and_return([])

    expect(described_class.call(agent_run: run, prompt: "Assess", timeout: 30)).to eq(response)
    expect(provider).to have_received(:send_message)
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
