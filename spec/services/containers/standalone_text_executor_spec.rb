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

  def input_header_of(exec_call)
    payload = exec_call[:stdin].read
    JSON.parse(payload.split("\n", 2).first)
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-005
  it "uses a proxy identity to materialize subscription credentials inside the container" do
    allow(Containers::StandaloneTextCredential).to receive(:issue).and_return("scoped-identity")
    inputs = []
    allow(backend).to receive(:exec_in_container) do |_c, _command, options = {}|
      inputs << options
      [ [], [], 0 ]
    end

    described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])

    expect(inputs.first.fetch(:Env)).to include("PAID_CREDENTIAL_IDENTITY=scoped-identity")
    expect(input_header_of(inputs.first)).to include("command" => [ "codex", "exec", "hello" ])
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
    inputs = []
    allow(backend).to receive(:exec_in_container) do |_c, _command, options = {}|
      inputs << options
      [ [], [], 0 ]
    end

    described_class.new(account: account, runner: runner, timeout: 30)
      .execute([ "codex", "exec", "hello" ], env: { "OPENAI_API_KEY" => nil }, preparation: preparation)

    header = input_header_of(inputs.first)
    expect(header.fetch("preparation")).to eq([
      { "path" => "/tmp/request.json", "content" => "{}", "mode" => 416 }
    ])
    expect(inputs.first.fetch(:Env)).not_to include(a_string_including("PAID_TEXT_"))
    expect(inputs.first.fetch(:Env)).not_to include("OPENAI_API_KEY=")
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-006
  it "forwards stdin data through the exec stdin stream, not the environment" do
    inputs = []
    allow(backend).to receive(:exec_in_container) do |_c, _command, options = {}|
      inputs << options
      [ [], [], 0 ]
    end

    described_class.new(account: account, runner: runner, timeout: 30)
      .execute([ "cursor", "-p" ], stdin_data: "private prompt")

    payload = inputs.first.fetch(:stdin).read
    header, body = payload.split("\n", 2)
    expect(JSON.parse(header).fetch("stdin_bytes")).to eq("private prompt".bytesize)
    expect(body).to eq("private prompt")
    expect(inputs.first.fetch(:Env)).not_to include(a_string_including("PAID_TEXT_STDIN"))
    expect(inputs.first.fetch(:Env)).not_to include(a_string_including("private prompt"))
  end

  # @spec LLM-ROUTING-006
  it "keeps every exec environment entry within the execve per-string limit for large prompts" do
    prompt = "x" * 300_000
    inputs = []
    allow(backend).to receive(:exec_in_container) do |_c, _command, options = {}|
      inputs << options
      [ [], [], 0 ]
    end

    described_class.new(account: account, runner: runner, timeout: 30)
      .execute([ "cursor", "-p" ], stdin_data: prompt)

    inputs.first.fetch(:Env).each do |entry|
      expect(entry.bytesize).to be <= 128 * 1024
    end
    payload = inputs.first.fetch(:stdin).read
    header, body = payload.split("\n", 2)
    expect(JSON.parse(header).fetch("stdin_bytes")).to eq(prompt.bytesize)
    expect(body.bytesize).to eq(prompt.bytesize)
  end

  # @spec LLM-ROUTING-006
  it "rejects a single environment entry above the per-entry exec limit" do
    allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

    expect do
      described_class.new(account: account, runner: runner, timeout: 30)
        .execute([ "codex", "exec", "hello" ], env: { "PAID_BIG" => "y" * (described_class::MAX_ENV_ENTRY_BYTES + 1) })
    end.to raise_error(AgentHarness::ConfigurationError, /per-entry/)

    expect(backend).not_to have_received(:create_container)
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

  # @spec LLM-ROUTING-005
  it "does not mount a checkout or Rails workspace" do
    allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

    described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])

    expect(backend).to have_received(:create_container) do |config|
      expect(config).not_to have_key("Volumes")
      expect(config.fetch("HostConfig")).not_to have_key("Binds")
      expect(config.fetch("HostConfig")).not_to have_key("Mounts")
    end
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

  # @spec LLM-ROUTING-006
  it "removes a partially provisioned container when Docker cannot start it" do
    allow(backend).to receive(:start_container).with(container)
      .and_raise(Docker::Error::DockerError, "Docker unavailable")

    expect do
      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])
    end.to raise_error(AgentHarness::ConfigurationError, /Unable to provision isolated text execution/)

    expect(backend).to have_received(:delete_container).with(container, force: true).once
  end

  # @spec LLM-ROUTING-006
  it "removes its container when the worker is interrupted" do
    allow(backend).to receive(:exec_in_container).and_raise(Interrupt, "worker interrupted")

    expect do
      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])
    end.to raise_error(Interrupt, "worker interrupted")

    expect(backend).to have_received(:delete_container).with(container, force: true).once
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
  it "labels the container with a fixed orphan-sweep lifetime from creation" do
    freeze_time do
      allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "--version" ])

      expect(backend).to have_received(:create_container).with(hash_including(
        "Labels" => hash_including(
          "paid.expires_at" => described_class::STANDALONE_TEXT_MAX_LIFETIME.from_now.iso8601
        )
      ))
    end
  end

  # @spec LLM-ROUTING-006
  it "resolves materialized paths before checking confinement" do
    expect(described_class::MATERIALIZE_COMMAND).to include("os.path.realpath(name)")
    expect(described_class::MATERIALIZE_COMMAND).not_to include('pathlib.Path("/home/agent") not in path.parents')
  end

  # @spec LLM-ROUTING-006
  it "reads the command header from the exec stdin stream" do
    expect(described_class::MATERIALIZE_COMMAND).to include("sys.stdin.buffer.readline()")
    expect(described_class::MATERIALIZE_COMMAND).not_to include("PAID_TEXT_COMMAND")
    expect(described_class::MATERIALIZE_COMMAND).not_to include("PAID_TEXT_STDIN")
    expect(described_class::MATERIALIZE_COMMAND).not_to include("PAID_TEXT_PREPARATION")
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

  describe "rotating managed credentials" do
    let(:valid_codex_auth) { file_fixture("codex_auth_valid.json").read }
    let(:credential) do
      create(:runner_credential, account: account, created_by: user, runner: runner)
    end
    let(:lockfile) do
      Runners::ManagedCredentialLifecycle.managed_auth_lockfile_path(runner_key: "codex", credential: credential)
    end

    def rotated_codex_auth
      payload = JSON.parse(valid_codex_auth)
      payload["tokens"]["access_token"] = "eyJrotated-access-token"
      payload["tokens"]["refresh_token"] = "v1.rotated-refresh-token"
      JSON.generate(payload)
    end

    def stub_execs(rotation_stdout: nil, rotation_status: 0)
      allow(backend).to receive(:exec_in_container) do |_c, command, _options = {}|
        next [ Array(rotation_stdout), [], rotation_status ] unless command.first == "python3"

        [ [], [], 0 ]
      end
    end

    around do |example|
      File.delete(lockfile) if File.exist?(lockfile)
      example.run
      File.delete(lockfile) if File.exist?(lockfile)
    end

    before do
      credential.update!(token: valid_codex_auth)
    end

    # @spec LLM-ROUTING-005 SUBSCRIPTION-RUNNER-AUTH-005
    it "harvests a rotated auth file once when the container closes" do
      stub_execs(rotation_stdout: Base64.strict_encode64(rotated_codex_auth))
      executor = described_class.new(account: account, runner: runner, timeout: 30)

      executor.execute([ "codex", "--version" ])
      executor.execute([ "codex", "exec", "hello" ])
      expect(JSON.parse(credential.reload.token)).to eq(JSON.parse(valid_codex_auth))
      executor.close

      parsed = JSON.parse(credential.reload.token)
      expect(parsed["tokens"]["access_token"]).to eq("eyJrotated-access-token")
      expect(File).to exist(lockfile)
      expect(backend).to have_received(:exec_in_container).with(container,
        [ "sh", "-lc", "base64 -w0 /home/agent/.codex/auth.json" ], hash_including(user: "agent")).once
    end

    # @spec LLM-ROUTING-005 SUBSCRIPTION-RUNNER-AUTH-005
    it "keeps the run successful when the harvest finds no rotation" do
      stub_execs(rotation_stdout: nil)

      executor = described_class.new(account: account, runner: runner, timeout: 30)
      result = executor.execute([ "codex", "exec", "hello" ])
      executor.close

      expect(result.exit_code).to eq(0)
      expect(credential.reload.token).to eq(valid_codex_auth)
    end

    # @spec LLM-ROUTING-005 SUBSCRIPTION-RUNNER-AUTH-005
    it "does not harvest when the runner authenticates with an API key" do
      runner.update!(auth_type: "api_key", provider_api_key: create(:runner_api_key, user: user,
        api_service_type: "openai", api_key: "selected-secret"))
      calls = []
      allow(backend).to receive(:exec_in_container) do |_c, command, _options = {}|
        calls << command
        [ [], [], 0 ]
      end

      executor = described_class.new(account: account, runner: runner, timeout: 30)
      executor.execute([ "codex", "exec", "hello" ])
      executor.close

      expect(calls).to all(satisfy { |command| command.first == "python3" })
    end

    # @spec LLM-ROUTING-005 SUBSCRIPTION-RUNNER-AUTH-005
    it "does not harvest non-rotating subscription runners" do
      claude_user = create(:user, account: account)
      claude_runner = claude_user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
      credential.update!(runner_key: "claude")
      calls = []
      allow(backend).to receive(:exec_in_container) do |_c, command, _options = {}|
        calls << command
        [ [], [], 0 ]
      end

      executor = described_class.new(account: account, runner: claude_runner, timeout: 30)
      executor.execute([ "claude", "--version" ])
      executor.close

      expect(calls).to all(satisfy { |command| command.first == "python3" })
    end
  end
end
