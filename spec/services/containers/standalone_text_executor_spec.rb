# frozen_string_literal: true

require "open3"
require "rails_helper"

RSpec.describe Containers::StandaloneTextExecutor do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:runner) { create(:runner, user: user, runner_key: "codex") }
  let(:backend) { instance_double(Containers::Backends::LocalDocker) }
  let(:container) { instance_double(Docker::Container) }
  let(:agent_owner) { "1001:1001\n" }
  let(:captured_inputs) { [] }

  before do
    allow(Containers).to receive(:backend).and_return(backend)
    allow(backend).to receive(:remote?).and_return(false)
    allow(NetworkPolicy).to receive(:ensure_network!)
    allow(backend).to receive_messages(create_container: container, start_container: true,
      stop_container: true, delete_container: true)
    allow(backend).to receive(:exec_in_container).with(container,
      [ "sh", "-c", "chown agent:agent /home/agent && stat -c '%u:%g' /home/agent" ], user: "root")
      .and_return([ [ agent_owner ], [], 0 ])
    allow(backend).to receive(:exec_in_container_with_stdin) do |_selected, _command, **options|
      captured_inputs << options.fetch(:stdin).string
      [ [], [], 0 ]
    end
  end

  def stub_text_exec
    allow(backend).to receive(:exec_in_container) do |selected, command, options = {}, &stream|
      next [ [ agent_owner ], [], 0 ] if options[:user] == "root"

      yield(selected, command, options, stream)
    end
    allow(backend).to receive(:exec_in_container_with_stdin) do |selected, command, **options, &stream|
      captured_inputs << options.fetch(:stdin).string
      yield(selected, command, options, stream)
    end
  end

  def input_header_of(payload)
    JSON.parse(payload.split("\n", 2).first)
  end

  def text_options(inputs)
    inputs.find { |options| options.key?(:Env) }
  end

  def captured_payload
    -> { captured_inputs.last }
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-005
  it "uses a proxy identity to materialize subscription credentials inside the container" do
    payload = captured_payload
    allow(Containers::StandaloneTextCredential).to receive(:issue).and_return("scoped-identity")
    inputs = []
    stub_text_exec do |_c, _command, options = {}|
      inputs << options
      [ [], [], 0 ]
    end

    described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])

    expect(text_options(inputs).fetch(:Env)).to include("PAID_CREDENTIAL_IDENTITY=scoped-identity")
    expect(input_header_of(payload.call)).to include("command" => [ "codex", "exec", "hello" ])
    expect(text_options(inputs).fetch(:stdin)).to be_a(StringIO)
    expect(backend).to have_received(:exec_in_container).with(container,
      [ "sh", "-c", "chown agent:agent /home/agent && stat -c '%u:%g' /home/agent" ], user: "root")
  end

  # @spec LLM-ROUTING-006
  it "streams request input while retaining a read-only root filesystem" do
    captured_payload
    stub_text_exec { [ [], [], 0 ] }

    described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])

    expect(backend).to have_received(:create_container).with(hash_including("ReadonlyRootfs" => true))
    expect(input_header_of(captured_inputs.last)).to include("command" => [ "codex", "exec", "hello" ])
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-005
  it "keeps API credentials out of the Docker exec environment" do
    captured_payload
    runner.update!(auth_type: "api_key", provider_api_key: create(:runner_api_key, user: user,
      api_service_type: "openai", api_key: "selected-secret"))
    allow(Containers::StandaloneTextCredential).to receive(:issue).and_return("scoped-identity")
    stub_text_exec { [ [], [], 0 ] }

    described_class.new(account: account, runner: runner, timeout: 30)
      .execute([ "codex", "exec", "hello" ], env: { "OPENAI_API_KEY" => "selected-secret" })

    expect(Containers::StandaloneTextCredential).to have_received(:issue).with(hash_including(
      account: account, runner: runner, env_keys: [ "OPENAI_API_KEY" ]
    ))
    expect(backend).to have_received(:exec_in_container_with_stdin).with(container, anything, hash_including(:Env)) do |_, _, options|
      expect(options.fetch(:Env)).not_to include(a_string_including("selected-secret"))
    end
  end

  # @spec LLM-ROUTING-005 LLM-ROUTING-006
  it "materializes request preparation and omits nil environment values" do
    payload = captured_payload
    preparation = AgentHarness::ExecutionPreparation.new(file_writes: [
      { path: "/tmp/request.json", content: "{}", mode: 0o640 }
    ])
    inputs = []
    stub_text_exec do |_c, _command, options = {}|
      inputs << options
      [ [], [], 0 ]
    end

    described_class.new(account: account, runner: runner, timeout: 30)
      .execute([ "codex", "exec", "hello" ], env: { "OPENAI_API_KEY" => nil }, preparation: preparation)

    header = input_header_of(payload.call)
    expect(header.fetch("preparation")).to eq([
      { "path" => "/tmp/request.json", "content" => "{}", "mode" => 416 }
    ])
    expect(text_options(inputs).fetch(:Env)).not_to include(a_string_including("PAID_TEXT_"))
    expect(text_options(inputs).fetch(:Env)).not_to include("OPENAI_API_KEY=")
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-006
  it "forwards stdin data through the upgraded exec stream, not the environment" do
    payload = captured_payload
    inputs = []
    stub_text_exec do |_c, _command, options = {}|
      inputs << options
      [ [], [], 0 ]
    end

    described_class.new(account: account, runner: runner, timeout: 30)
      .execute([ "cursor", "-p" ], stdin_data: "private prompt")

    header, body = payload.call.split("\n", 2)
    expect(JSON.parse(header).fetch("stdin_bytes")).to eq("private prompt".bytesize)
    expect(body).to eq("private prompt")
    expect(text_options(inputs).fetch(:stdin)).to be_a(StringIO)
    expect(text_options(inputs).fetch(:Env)).not_to include(a_string_including("PAID_TEXT_STDIN"))
    expect(text_options(inputs).fetch(:Env)).not_to include(a_string_including("private prompt"))
  end

  # @spec LLM-ROUTING-006
  it "keeps every exec environment entry within the execve per-string limit for large prompts" do
    payload = captured_payload
    prompt = "x" * 300_000
    inputs = []
    stub_text_exec do |_c, _command, options = {}|
      inputs << options
      [ [], [], 0 ]
    end

    described_class.new(account: account, runner: runner, timeout: 30)
      .execute([ "cursor", "-p" ], stdin_data: prompt)

    text_options(inputs).fetch(:Env).each do |entry|
      expect(entry.bytesize).to be <= 128 * 1024
    end
    header, body = payload.call.split("\n", 2)
    expect(JSON.parse(header).fetch("stdin_bytes")).to eq(prompt.bytesize)
    expect(body.bytesize).to eq(prompt.bytesize)
  end

  # @spec LLM-ROUTING-006
  it "rejects a single environment entry above the per-entry exec limit" do
    stub_text_exec { [ [], [], 0 ] }

    expect do
      described_class.new(account: account, runner: runner, timeout: 30)
        .execute([ "codex", "exec", "hello" ], env: { "PAID_BIG" => "y" * (described_class::MAX_ENV_ENTRY_BYTES + 1) })
    end.to raise_error(AgentHarness::ConfigurationError, /per-entry/)

    expect(backend).not_to have_received(:create_container)
  end

  # @spec LLM-ROUTING-005 LLM-ROUTING-006
  it "uses the outbound-capable runner network and resolves the proxy on it" do
    captured_payload
    allow(Containers::ProxyUrl).to receive(:resolve).and_return("http://web:3000")
    stub_text_exec { [ [], [], 0 ] }

    described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])

    expect(backend).to have_received(:create_container).with(hash_including(
      "HostConfig" => hash_including("NetworkMode" => NetworkPolicy::INFRA_NETWORK_NAME)
    ))
    expect(Containers::ProxyUrl).to have_received(:resolve).with(backend: backend, restricted: false)
  end

  # @spec LLM-ROUTING-005
  it "does not mount a repository or Rails workspace" do
    captured_payload
    stub_text_exec { [ [], [], 0 ] }

    described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])

    expect(backend).to have_received(:create_container).with(hash_including(
      "HostConfig" => hash_excluding("Binds")
    ))
  end

  # @spec LLM-ROUTING-006
  it "honors the caller timeout above two minutes" do
    captured_payload
    stub_text_exec { [ [], [], 0 ] }

    described_class.new(account: account, runner: runner, timeout: 300).execute([ "codex", "exec", "hello" ])

    expect(backend).to have_received(:exec_in_container_with_stdin).with(container, anything, hash_including(wait: 300))
  end

  # @spec LLM-ROUTING-006
  it "classifies Docker read timeouts as request timeouts" do
    captured_payload
    allow(backend).to receive(:exec_in_container_with_stdin).with(container, anything, hash_including(:Env))
      .and_raise(Docker::Error::TimeoutError, "read timeout")

    expect do
      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])
    end.to raise_error(AgentHarness::TimeoutError, /timed out/)
  end

  # @spec LLM-ROUTING-006
  it "rejects an incomplete Docker exec instead of reporting success" do
    captured_payload
    allow(backend).to receive(:exec_in_container_with_stdin).with(container, anything, hash_including(:Env))
      .and_return([ [], [], nil ])

    expect do
      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])
    end.to raise_error(AgentHarness::Error, /exit status unavailable/)
  end

  # @spec LLM-ROUTING-006
  it "classifies incomplete home preparation as a transport failure and removes the container" do
    allow(backend).to receive(:exec_in_container).with(container,
      [ "sh", "-c", "chown agent:agent /home/agent && stat -c '%u:%g' /home/agent" ], user: "root")
      .and_return([ [], [], nil ])

    expect do
      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])
    end.to raise_error(AgentHarness::Error, /home preparation exit status unavailable/)

    expect(backend).to have_received(:delete_container).with(container, force: true)
  end

  # @spec LLM-ROUTING-006
  it "classifies a Docker home preparation timeout as a request timeout" do
    allow(backend).to receive(:exec_in_container).with(container,
      [ "sh", "-c", "chown agent:agent /home/agent && stat -c '%u:%g' /home/agent" ], user: "root")
      .and_raise(Docker::Error::TimeoutError, "read timeout")

    expect do
      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])
    end.to raise_error(AgentHarness::TimeoutError, /timed out/)

    expect(backend).to have_received(:delete_container).with(container, force: true)
  end

  # @spec LLM-ROUTING-006
  it "fails closed when Docker cannot provision isolated execution" do
    allow(backend).to receive(:create_container).and_raise(Docker::Error::DockerError, "Docker unavailable")

    expect do
      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])
    end.to raise_error(AgentHarness::ConfigurationError, /Unable to provision isolated text execution/)

    expect(backend).not_to have_received(:start_container)
  end

  # @spec LLM-ROUTING-006
  it "removes the container when the upgraded exec transport fails" do
    allow(backend).to receive(:exec_in_container_with_stdin).and_raise(Docker::Error::DockerError, "exec failed")

    expect do
      described_class.new(account: account, runner: runner, timeout: 30).execute([ "codex", "exec", "hello" ])
    end.to raise_error(AgentHarness::Error, /Isolated text execution failed/)

    expect(backend).to have_received(:delete_container).with(container, force: true)
  end

  # @spec LLM-ROUTING-005 LLM-ROUTING-006
  it "reuses one container across executor commands until closed" do
    captured_payload
    stub_text_exec { [ [], [], 0 ] }
    executor = described_class.new(account: account, runner: runner, timeout: 30)

    executor.execute([ "codex", "--version" ])
    executor.execute([ "codex", "exec", "hello" ])
    executor.close

    expect(backend).to have_received(:create_container).once
    expect(backend).to have_received(:delete_container).once
  end

  # @spec LLM-ROUTING-006
  it "labels the container with a fixed orphan-sweep lifetime from creation" do
    captured_payload
    freeze_time do
      stub_text_exec { [ [], [], 0 ] }

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
  it "rejects input that ends before its declared byte count" do
    header = { command: [ "true" ], stdin_bytes: 5 }.to_json
    _stdout, stderr, status = Open3.capture3(
      { "PAID_MAX_OUTPUT_BYTES" => "100" }, "python3", "-c", described_class::MATERIALIZE_COMMAND,
      stdin_data: "#{header}\nabc"
    )

    expect(status).not_to be_success
    expect(stderr).to include("EOFError: isolated text input ended before the declared length")
  end

  # @spec LLM-ROUTING-006
  it "stops collection and raises a classified failure when output exceeds the cap" do
    captured_payload
    allow(Containers::StandaloneTextCredential).to receive(:issue).and_return("scoped-identity")
    stub_text_exec do |*, stream|
      next [ [], [], 0 ] unless stream

      stream.call(:stdout, "x" * (described_class::MAX_OUTPUT_BYTES + 1)) if stream
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
      stub_text_exec do |_c, command, _options = {}|
        next [ Array(rotation_stdout), [], rotation_status ] if command.include?("base64 -w0 /home/agent/.codex/auth.json")

        [ [], [], 0 ]
      end
    end

    around do |example|
      File.delete(lockfile) if File.exist?(lockfile)
      example.run
      File.delete(lockfile) if File.exist?(lockfile)
    end

    before do
      captured_payload
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
      stub_text_exec do |_c, command, _options = {}|
        calls << command
        [ [], [], 0 ]
      end

      executor = described_class.new(account: account, runner: runner, timeout: 30)
      executor.execute([ "codex", "exec", "hello" ])
      executor.close

      expect(calls.count { |command| command.include?(described_class::MATERIALIZE_COMMAND) }).to eq(1)
    end

    # @spec LLM-ROUTING-005 SUBSCRIPTION-RUNNER-AUTH-005
    it "does not harvest non-rotating subscription runners" do
      claude_user = create(:user, account: account)
      claude_runner = claude_user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
      credential.update!(runner_key: "claude")
      calls = []
      stub_text_exec do |_c, command, _options = {}|
        calls << command
        [ [], [], 0 ]
      end

      executor = described_class.new(account: account, runner: claude_runner, timeout: 30)
      executor.execute([ "claude", "--version" ])
      executor.close

      expect(calls.count { |command| command.include?(described_class::MATERIALIZE_COMMAND) }).to eq(1)
    end
  end
end
