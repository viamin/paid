# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::StandaloneTextExecutor do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:runner) { create(:runner, user: user, runner_key: "codex") }
  let(:backend) { instance_double(Containers::Backends::LocalDocker) }
  let(:container) { instance_double(Docker::Container) }

  before do
    allow(Containers).to receive(:backend).and_return(backend)
    allow(backend).to receive(:remote?).and_return(false)
    allow(NetworkPolicy).to receive(:ensure_network!)
    allow(backend).to receive_messages(create_container: container, start_container: true,
      stop_container: true, delete_container: true)
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-005
  it "uses a proxy identity to materialize subscription credentials inside the container" do
    allow(Containers::StandaloneTextCredential).to receive(:issue).and_return("scoped-identity")
    allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

    described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])

    expect(backend).to have_received(:exec_in_container).with(container,
      [ "python3", "-c", described_class::MATERIALIZE_COMMAND ], hash_including(
        Env: include("PAID_CREDENTIAL_IDENTITY=scoped-identity", 'PAID_TEXT_COMMAND=["codex","exec","hello"]')
      ))
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-005
  it "keeps API credentials out of the Docker exec environment" do
    runner.update!(auth_type: "api_key", provider_api_key: create(:runner_api_key, user: user,
      api_service_type: "openai", api_key: "selected-secret"))
    allow(Containers::StandaloneTextCredential).to receive(:issue).and_return("scoped-identity")
    allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

    described_class.new(account: account, runner: runner, timeout: 30)
      .execute([ "codex", "exec", "hello" ], env: { "OPENAI_API_KEY" => "selected-secret" })

    expect(Containers::StandaloneTextCredential).to have_received(:issue).with(hash_including(
      account: account, runner: runner, env_keys: [ "OPENAI_API_KEY" ]
    ))
    expect(backend).to have_received(:exec_in_container) do |_, _, options|
      expect(options.fetch(:Env)).not_to include(a_string_including("selected-secret"))
    end
  end

  # @spec LLM-ROUTING-005 LLM-ROUTING-006
  it "materializes request preparation and omits nil environment values" do
    preparation = AgentHarness::ExecutionPreparation.new(file_writes: [
      { path: "/tmp/request.json", content: "{}", mode: 0o640 }
    ])
    allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

    described_class.new(account: account, runner: runner, timeout: 30)
      .execute([ "codex", "exec", "hello" ], env: { "OPENAI_API_KEY" => nil }, preparation: preparation)

    expect(backend).to have_received(:exec_in_container) do |_, _, options|
      expect(options.fetch(:Env)).to include('PAID_TEXT_PREPARATION=[{"path":"/tmp/request.json","content":"{}","mode":416}]')
      expect(options.fetch(:Env)).not_to include("OPENAI_API_KEY=")
    end
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-006
  it "forwards stdin data to the isolated child without placing it in the command" do
    allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

    described_class.new(account: account, runner: runner, timeout: 30)
      .execute([ "cursor", "-p" ], stdin_data: "private prompt")

    expect(backend).to have_received(:exec_in_container) do |_, _, options|
      expect(options.fetch(:Env)).to include("PAID_TEXT_STDIN=cHJpdmF0ZSBwcm9tcHQ=")
    end
  end

  # @spec LLM-ROUTING-005 LLM-ROUTING-006
  it "uses the outbound-capable runner network and resolves the proxy on it" do
    allow(Containers::ProxyUrl).to receive(:resolve).and_return("http://web:3000")
    allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

    described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])

    expect(backend).to have_received(:create_container).with(hash_including(
      "HostConfig" => hash_including("NetworkMode" => NetworkPolicy::INFRA_NETWORK_NAME)
    ))
    expect(Containers::ProxyUrl).to have_received(:resolve).with(backend: backend, restricted: false)
  end

  # @spec LLM-ROUTING-006
  it "honors the caller timeout above two minutes" do
    allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

    described_class.new(account: account, runner: runner, timeout: 300).execute([ "codex", "exec", "hello" ])

    expect(backend).to have_received(:exec_in_container).with(container, anything, hash_including(wait: 300))
  end

  # @spec LLM-ROUTING-006
  it "classifies Docker read timeouts as request timeouts" do
    allow(backend).to receive(:exec_in_container).and_raise(Docker::Error::TimeoutError, "read timeout")

    expect do
      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])
    end.to raise_error(AgentHarness::TimeoutError, /timed out/)
  end

  # @spec LLM-ROUTING-005 LLM-ROUTING-006
  it "reuses one container across executor commands until closed" do
    allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])
    executor = described_class.new(account: account, runner: runner, timeout: 30)

    executor.execute([ "codex", "--version" ])
    executor.execute([ "codex", "exec", "hello" ])
    executor.close

    expect(backend).to have_received(:create_container).once
    expect(backend).to have_received(:delete_container).once
  end

  # @spec LLM-ROUTING-006
  it "resolves materialized paths before checking confinement" do
    expect(described_class::MATERIALIZE_COMMAND).to include("os.path.realpath(name)")
    expect(described_class::MATERIALIZE_COMMAND).not_to include('pathlib.Path("/home/agent") not in path.parents')
  end

  # @spec LLM-ROUTING-006
  it "stops collection and raises a classified failure when output exceeds the cap" do
    allow(Containers::StandaloneTextCredential).to receive(:issue).and_return("scoped-identity")
    allow(backend).to receive(:exec_in_container) do |*, &stream|
      stream.call(:stdout, "x" * (described_class::MAX_OUTPUT_BYTES + 1))
      [ [], [], 137 ]
    end

    expect do
      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])
    end.to raise_error(AgentHarness::Error, /output limit/)

    expect(backend).to have_received(:stop_container).with(container, timeout: 0).at_least(:once)
  end
end
