# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Provision do # @spec SUBSCRIPTION-RUNNER-AUTH-005
  let(:local_backend) do
    instance_double(
      Containers::Backends::Base,
      identifier: "local",
      remote?: false,
      supports_host_paths?: true
    )
  end
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:container) { instance_double(Docker::Container) }
  let(:rotated_canonical_auth) do
    payload = JSON.parse(file_fixture("codex_auth_valid.json").read)
    payload["tokens"]["access_token"] = "opencode-rotated-access-token"
    payload["tokens"]["refresh_token"] = "opencode-rotated-refresh-token"
    JSON.generate(payload)
  end
  let(:rotated_auth) do
    JSON.generate(
      "openai" => {
        "type" => "oauth",
        "access" => "opencode-rotated-access-token",
        "refresh" => "opencode-rotated-refresh-token",
        "expires" => 4_102_444_800_000,
        "accountId" => "acc_managed-codex-001"
      }
    )
  end
  let(:rotated_omp_auth) do
    JSON.generate(
      "access" => "omp-rotated-access-token",
      "refresh" => "omp-rotated-refresh-token",
      "expires" => 4_102_444_800_000
    )
  end

  def build_service(agent_run:)
    described_class.new(agent_run: agent_run, project: project, backend: local_backend).tap do |svc|
      allow(svc).to receive(:log_system)
    end
  end

  def create_managed_oauth_credential(runner_key:, fixture_name:)
    create(
      :runner_credential,
      account: account,
      created_by: owner,
      runner_key: runner_key,
      auth_kind: "oauth_token",
      token: file_fixture(fixture_name).read
    )
  end

  def build_opencode_subscription_run
    runner = create(:runner, user: owner, runner_key: "opencode", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    credential = create_managed_oauth_credential(runner_key: "opencode", fixture_name: "codex_auth_valid.json")
    [ agent_run, credential ]
  end

  def build_omp_subscription_run
    runner = create(:runner, user: owner, runner_key: "omp", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    credential = create_managed_oauth_credential(runner_key: "omp", fixture_name: "claude_credentials_valid.json")
    [ agent_run, credential ]
  end

  def opencode_run_command
    [ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode", "run", "ping" ]
  end

  def wrapped_opencode_run_command
    [
      "sh",
      "-c",
      'if [ "$PAID_OPENCODE_SUBSCRIPTION_AUTH" = "1" ]; then env -u OPENAI_API_KEY opencode run "$1"; else opencode run "$1"; fi',
      "--",
      "ping"
    ]
  end

  def omp_run_command
    [ "omp", "-p", "ping" ]
  end

  def wrapped_omp_run_command
    [ "sh", "-c", 'env ANTHROPIC_API_KEY="$KEY" omp -p "$1"', "--", "ping" ]
  end

  def expected_opencode_auth_payload(access:, refresh:)
    {
      "openai" => {
        "type" => "oauth",
        "access" => access,
        "refresh" => refresh,
        "expires" => 4_102_444_800_000,
        "accountId" => "acc_managed-codex-001"
      }
    }
  end

  def managed_codex_tokens
    payload = JSON.parse(file_fixture("codex_auth_valid.json").read)
    payload.fetch("tokens")
  end

  def omp_import_command
    [ "sh", "-lc", "omp auth-broker import /home/agent/.local/share/omp/paid-auth-import.json --provider anthropic --json" ]
  end

  def omp_cleanup_command
    [ "sh", "-lc", "rm -f /home/agent/.local/share/omp/paid-auth-import.json" ]
  end

  def stub_omp_exec(success:, stderr: [], stdout: [])
    allow(local_backend).to receive(:exec_in_container)
      .with(container, omp_import_command, user: "agent")
      .and_return([ stdout, stderr, success ? 0 : 1 ])
    allow(local_backend).to receive(:exec_in_container)
      .with(container, omp_cleanup_command, user: "agent")
      .and_return([ [], [], 0 ])
  end

  def expect_omp_import_and_cleanup
    expect(local_backend).to have_received(:exec_in_container).with(
      container,
      omp_import_command,
      user: "agent"
    )
    expect(local_backend).to have_received(:exec_in_container).with(
      container,
      omp_cleanup_command,
      user: "agent"
    )
  end

  def collect_serialized_intervals(svc, command:)
    intervals = []
    mutex = Mutex.new
    critical_section = lambda do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep 0.3
      finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      mutex.synchronize { intervals << [ started_at, finished_at ] }
    end

    threads = Array.new(2) do
      Thread.new do
        svc.send(:with_codex_auth_lock, command) { critical_section.call }
      end
    end
    threads.each(&:join)
    intervals.sort_by(&:first)
  end

  it "materializes a managed opencode credential into OpenCode's auth.json path" do
    runner = create(:runner, user: owner, runner_key: "opencode", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    credential = create_managed_oauth_credential(runner_key: "opencode", fixture_name: "codex_auth_valid.json")
    svc = build_service(agent_run: agent_run)
    written = {}

    allow(svc).to receive(:write_container_file) { |path, content| written[path] = content }
    allow(svc).to receive(:refresh_opencode_managed_credential!).and_return(nil)

    expect(svc.send(:seed_opencode_credentials!)).to be(true)
    expect(written.keys).to include("/home/agent/.local/share/opencode/auth.json")
    expect(JSON.parse(written.fetch("/home/agent/.local/share/opencode/auth.json"))).to eq(
      expected_opencode_auth_payload(
        access: managed_codex_tokens.fetch("access_token"),
        refresh: managed_codex_tokens.fetch("refresh_token")
      )
    )

    attempt = RunnerAuthAttempt.where(runner_key: "opencode", attempt_stage: "materialization").last
    expect(attempt.runner_credential).to eq(credential)
    expect(attempt.auth_source).to eq("managed")
  end

  it "refreshes before materializing and re-resolves the rotated payload" do
    runner = create(:runner, user: owner, runner_key: "opencode", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    credential = create_managed_oauth_credential(runner_key: "opencode", fixture_name: "codex_auth_expired.json")
    svc = build_service(agent_run: agent_run)
    written = {}

    allow(svc).to receive(:write_container_file) { |path, content| written[path] = content }
    allow(svc).to receive(:refresh_opencode_managed_credential!) do
      credential.update!(token: rotated_canonical_auth, expires_at: Time.parse("2100-01-01T00:00:00Z"))
      true
    end

    expect(svc.send(:seed_opencode_credentials!)).to be(true)
    payload = JSON.parse(written.fetch("/home/agent/.local/share/opencode/auth.json"))
    expect(payload.dig("openai", "refresh")).to eq("opencode-rotated-refresh-token")
  end

  it "harvests rotated OpenCode auth.json back into the canonical credential" do
    runner = create(:runner, user: owner, runner_key: "opencode", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    credential = create_managed_oauth_credential(runner_key: "opencode", fixture_name: "codex_auth_valid.json")
    svc = build_service(agent_run: agent_run)
    encoded = Base64.strict_encode64(rotated_auth)

    allow(svc).to receive(:container).and_return(container)
    allow(local_backend).to receive(:exec_in_container).and_return([ [ encoded ], [], 0 ])

    result = svc.send(:harvest_opencode_managed_credential!)

    expect(result.performed?).to be(true)
    parsed = JSON.parse(credential.reload.token)
    expect(parsed["tokens"]["access_token"]).to eq("opencode-rotated-access-token")
    expect(parsed["tokens"]["refresh_token"]).to eq("opencode-rotated-refresh-token")

    attempt = RunnerAuthAttempt.where(runner_key: "opencode", attempt_stage: "harvest").last
    expect(attempt.result).to eq("harvested")
    expect(attempt.auth_source).to eq("managed")
  end

  it "serializes opencode runs sharing the same managed credential and harvests under the lock" do
    agent_run, credential = build_opencode_subscription_run
    svc = build_service(agent_run: agent_run)

    allow(svc).to receive_messages(
      opencode_managed_runner_credential: credential,
      subscription_auth_lock_timeout: 5
    )
    allow(svc).to receive(:harvest_opencode_managed_credential!)

    lockfile = svc.send(:opencode_managed_auth_lockfile_path)
    FileUtils.rm_f(lockfile)

    sorted = collect_serialized_intervals(svc, command: opencode_run_command)
    expect(sorted.size).to eq(2)
    expect(sorted[1][0]).to be >= sorted[0][1]
    expect(svc).to have_received(:harvest_opencode_managed_credential!).twice

    attempt = RunnerAuthAttempt.where(runner_key: "opencode", attempt_stage: "lease").last
    expect(attempt.lease_state).to eq("acquired")
    expect(attempt.runner_credential).to eq(credential)
  end

  it "serializes wrapped opencode shell commands under the same managed credential lock" do
    agent_run, credential = build_opencode_subscription_run
    svc = build_service(agent_run: agent_run)

    allow(svc).to receive_messages(
      opencode_managed_runner_credential: credential,
      subscription_auth_lock_timeout: 5
    )
    allow(svc).to receive(:harvest_opencode_managed_credential!)

    lockfile = svc.send(:opencode_managed_auth_lockfile_path)
    FileUtils.rm_f(lockfile)

    sorted = collect_serialized_intervals(svc, command: wrapped_opencode_run_command)
    expect(sorted.size).to eq(2)
    expect(sorted[1][0]).to be >= sorted[0][1]
    expect(svc).to have_received(:harvest_opencode_managed_credential!).twice
  end

  it "treats opencode refresh exchange as unsupported until :opencode support exists" do
    runner = create(:runner, user: owner, runner_key: "opencode", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    credential = create_managed_oauth_credential(runner_key: "opencode", fixture_name: "codex_auth_valid.json")
    svc = build_service(agent_run: agent_run)

    allow(svc).to receive(:opencode_managed_runner_credential).and_return(credential)
    allow(AgentHarness::Authentication).to receive(:respond_to?).and_call_original
    allow(AgentHarness::Authentication).to receive(:respond_to?).with(:exchange_refresh_token).and_return(true)
    allow(AgentHarness::Authentication).to receive(:respond_to?).with(:exchange_refresh_token_supported?).and_return(true)
    allow(AgentHarness::Authentication).to receive(:exchange_refresh_token_supported?).with(:opencode).and_return(false)
    allow(AgentHarness::Authentication).to receive(:exchange_refresh_token)

    expect(svc.send(:exchange_opencode_refresh_token!, credential)).to be(false)
    expect(AgentHarness::Authentication).not_to have_received(:exchange_refresh_token)
  end

  it "imports a managed omp credential through omp auth-broker" do
    runner = create(:runner, user: owner, runner_key: "omp", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    credential = create_managed_oauth_credential(runner_key: "omp", fixture_name: "claude_credentials_valid.json")
    svc = build_service(agent_run: agent_run)
    written = {}

    allow(svc).to receive(:container).and_return(container)
    allow(svc).to receive(:write_container_file) { |path, content| written[path] = content }
    stub_omp_exec(success: true, stdout: [ '{"ok":true}' ])

    expect(svc.send(:seed_omp_credentials!)).to be(true)
    expect(written.keys).to include("/home/agent/.local/share/omp/paid-auth-import.json")
    expect(JSON.parse(written.fetch("/home/agent/.local/share/omp/paid-auth-import.json"))["expired"]).to eq("2100-01-01T00:00:00Z")
    expect_omp_import_and_cleanup

    attempt = RunnerAuthAttempt.where(runner_key: "omp", attempt_stage: "materialization").last
    expect(attempt.runner_credential).to eq(credential)
    expect(attempt.auth_source).to eq("managed")
  end

  it "refreshes an omp managed credential before import and re-resolves the rotated payload" do
    runner = create(:runner, user: owner, runner_key: "omp", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    credential = create_managed_oauth_credential(runner_key: "omp", fixture_name: "claude_credentials_valid.json")
    svc = build_service(agent_run: agent_run)
    written = {}
    rotated = JSON.parse(file_fixture("claude_credentials_valid.json").read)
    rotated.fetch("claudeAiOauth")["accessToken"] = "omp-rotated-access-token"
    rotated.fetch("claudeAiOauth")["refreshToken"] = "omp-rotated-refresh-token"

    allow(svc).to receive(:container).and_return(container)
    allow(svc).to receive(:write_container_file) { |path, content| written[path] = content }
    allow(svc).to receive(:refresh_omp_managed_credential!) do
      credential.update!(token: JSON.generate(rotated), expires_at: Time.parse("2100-01-01T00:00:00Z"))
      true
    end
    stub_omp_exec(success: true, stdout: [ '{"ok":true}' ])

    expect(svc.send(:seed_omp_credentials!)).to be(true)
    payload = JSON.parse(written.fetch("/home/agent/.local/share/omp/paid-auth-import.json"))
    expect(payload["access_token"]).to eq("omp-rotated-access-token")
    expect(payload["refresh_token"]).to eq("omp-rotated-refresh-token")
  end

  it "harvests rotated OMP broker state back into the canonical credential" do
    runner = create(:runner, user: owner, runner_key: "omp", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    credential = create_managed_oauth_credential(runner_key: "omp", fixture_name: "claude_credentials_valid.json")
    svc = build_service(agent_run: agent_run)

    allow(svc).to receive(:container).and_return(container)
    allow(local_backend).to receive(:exec_in_container).and_return([ [ rotated_omp_auth ], [], 0 ])

    result = svc.send(:harvest_omp_managed_credential!)

    expect(result.performed?).to be(true)
    parsed = JSON.parse(credential.reload.token)
    expect(parsed.dig("claudeAiOauth", "accessToken")).to eq("omp-rotated-access-token")
    expect(parsed.dig("claudeAiOauth", "refreshToken")).to eq("omp-rotated-refresh-token")

    attempt = RunnerAuthAttempt.where(runner_key: "omp", attempt_stage: "harvest").last
    expect(attempt.result).to eq("harvested")
    expect(attempt.auth_source).to eq("managed")
  end

  it "reads the rotated OMP broker state from the XDG data directory" do
    svc = build_service(agent_run: create(:agent_run, project: project))

    expect(svc.send(:omp_harvest_python_script)).to include("/home/agent/.local/share/omp/agent/agent.db")
    expect(svc.send(:omp_harvest_python_script)).not_to include("/home/agent/.omp/agent/agent.db")
  end

  it "serializes omp runs sharing the same managed credential and harvests under the lock" do
    agent_run, credential = build_omp_subscription_run
    svc = build_service(agent_run: agent_run)

    allow(svc).to receive_messages(
      omp_managed_runner_credential: credential,
      subscription_auth_lock_timeout: 5
    )
    allow(svc).to receive(:harvest_omp_managed_credential!)

    lockfile = svc.send(:omp_managed_auth_lockfile_path)
    FileUtils.rm_f(lockfile)

    sorted = collect_serialized_intervals(svc, command: omp_run_command)
    expect(sorted.size).to eq(2)
    expect(sorted[1][0]).to be >= sorted[0][1]
    expect(svc).to have_received(:harvest_omp_managed_credential!).twice

    attempt = RunnerAuthAttempt.where(runner_key: "omp", attempt_stage: "lease").last
    expect(attempt.lease_state).to eq("acquired")
    expect(attempt.runner_credential).to eq(credential)
  end

  it "serializes wrapped omp shell commands under the same managed credential lock" do
    agent_run, credential = build_omp_subscription_run
    svc = build_service(agent_run: agent_run)

    allow(svc).to receive_messages(
      omp_managed_runner_credential: credential,
      subscription_auth_lock_timeout: 5
    )
    allow(svc).to receive(:harvest_omp_managed_credential!)

    lockfile = svc.send(:omp_managed_auth_lockfile_path)
    FileUtils.rm_f(lockfile)

    sorted = collect_serialized_intervals(svc, command: wrapped_omp_run_command)
    expect(sorted.size).to eq(2)
    expect(sorted[1][0]).to be >= sorted[0][1]
    expect(svc).to have_received(:harvest_omp_managed_credential!).twice
  end

  it "refreshes the canonical omp credential via the Claude exchange on a temp managed directory" do
    _agent_run, credential = build_omp_subscription_run
    svc = build_service(agent_run: create(:agent_run, project: project))
    rotated = JSON.parse(file_fixture("claude_credentials_valid.json").read)
    rotated.fetch("claudeAiOauth")["accessToken"] = "omp-refreshed-access-token"

    allow(svc).to receive(:omp_managed_runner_credential).and_return(credential)
    allow(AgentHarness::Authentication).to receive(:respond_to?).and_call_original
    allow(AgentHarness::Authentication).to receive(:respond_to?).with(:exchange_refresh_token).and_return(true)
    allow(AgentHarness::Authentication).to receive(:respond_to?).with(:exchange_refresh_token_supported?).and_return(true)
    allow(AgentHarness::Authentication).to receive(:exchange_refresh_token_supported?).with(:claude).and_return(true)
    allow(AgentHarness::Authentication).to receive(:exchange_refresh_token) do
      path = File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".credentials.json")
      File.write(path, JSON.generate(rotated))
    end

    expect(svc.send(:exchange_omp_refresh_token!, credential)).to be(true)
    expect(credential.reload.token).to include("omp-refreshed-access-token")

    attempt = RunnerAuthAttempt.where(runner_key: "omp", attempt_stage: "refresh").last
    expect(attempt).to be_nil
  end

  it "removes the temporary omp auth-broker import file after a failed import" do
    runner = create(:runner, user: owner, runner_key: "omp", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    create_managed_oauth_credential(runner_key: "omp", fixture_name: "claude_credentials_valid.json")
    svc = build_service(agent_run: agent_run)

    allow(svc).to receive(:container).and_return(container)
    allow(svc).to receive(:write_container_file)
    stub_omp_exec(success: false, stderr: [ "boom" ])

    expect(svc.send(:seed_omp_credentials!)).to be(false)
    expect_omp_import_and_cleanup
  end

  it "logs a cleanup failure when the omp import file removal exits non-zero" do
    runner = create(:runner, user: owner, runner_key: "omp", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    create_managed_oauth_credential(runner_key: "omp", fixture_name: "claude_credentials_valid.json")
    svc = build_service(agent_run: agent_run)

    allow(svc).to receive(:container).and_return(container)
    allow(svc).to receive(:write_container_file)
    stub_omp_exec(success: true, stdout: [ '{"ok":true}' ])
    allow(local_backend).to receive(:exec_in_container)
      .with(container, omp_cleanup_command, user: "agent")
      .and_return([ [], [ "rm failed" ], 1 ])

    expect(svc.send(:seed_omp_credentials!)).to be(true)
    expect(svc).to have_received(:log_system).with("container.omp_credentials_cleanup_failed", error: "rm failed")
  end

  it "does not treat incidental omp mentions in shell scripts as an OMP run command" do
    svc = build_service(agent_run: create(:agent_run, project: project))

    expect(svc.send(:omp_exec_command?, [ "omp", "auth-broker", "list" ])).to be(false)
    expect(svc.send(:omp_exec_command?, [ "sh", "-c", "ls /home/agent/.local/share/omp" ])).to be(false)
    expect(svc.send(:omp_exec_command?, [ "sh", "-c", "echo omp" ])).to be(false)
    expect(svc.send(:omp_exec_command?, [ "sh", "-c", "omp auth-broker import file.json --provider anthropic --json" ])).to be(false)
    expect(svc.send(:omp_exec_command?, [ "sh", "-c", "omp -p ping" ])).to be(true)
  end

  it "sets PAID_OPENCODE_SUBSCRIPTION_AUTH=1 when an opencode managed credential is active" do
    runner = create(:runner, user: owner, runner_key: "opencode", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    create_managed_oauth_credential(runner_key: "opencode", fixture_name: "codex_auth_valid.json")
    svc = build_service(agent_run: agent_run)

    env_entries = svc.send(:run_scoped_environment, "http://paid-proxy:3000")

    expect(env_entries).to include("PAID_OPENCODE_SUBSCRIPTION_AUTH=1")
    expect(env_entries).to include("PAID_OMP_SUBSCRIPTION_AUTH=0")
    opencode_entries = env_entries.select { |e| e.start_with?("PAID_OPENCODE_SUBSCRIPTION_AUTH=") }
    expect(opencode_entries).to eq([ "PAID_OPENCODE_SUBSCRIPTION_AUTH=1" ])
  end

  it "sets PAID_OMP_SUBSCRIPTION_AUTH=1 when an omp managed credential is active" do
    runner = create(:runner, user: owner, runner_key: "omp", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    create_managed_oauth_credential(runner_key: "omp", fixture_name: "claude_credentials_valid.json")
    svc = build_service(agent_run: agent_run)

    env_entries = svc.send(:run_scoped_environment, "http://paid-proxy:3000")

    expect(env_entries).to include("PAID_OMP_SUBSCRIPTION_AUTH=1")
    expect(env_entries).not_to include("PAID_OPENCODE_SUBSCRIPTION_AUTH=1")
    omp_entries = env_entries.select { |e| e.start_with?("PAID_OMP_SUBSCRIPTION_AUTH=") }
    expect(omp_entries).to eq([ "PAID_OMP_SUBSCRIPTION_AUTH=1" ])
  end

  it "leaves the opencode/omp subscription flags at 0 when only a codex managed credential is active" do
    runner = create(:runner, user: owner, runner_key: "codex", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    create_managed_oauth_credential(runner_key: "codex", fixture_name: "codex_auth_valid.json")
    svc = build_service(agent_run: agent_run)

    env_entries = svc.send(:run_scoped_environment, "http://paid-proxy:3000")

    opencode_entries = env_entries.select { |e| e.start_with?("PAID_OPENCODE_SUBSCRIPTION_AUTH=") }
    omp_entries = env_entries.select { |e| e.start_with?("PAID_OMP_SUBSCRIPTION_AUTH=") }
    expect(opencode_entries).to eq([ "PAID_OPENCODE_SUBSCRIPTION_AUTH=0" ])
    expect(omp_entries).to eq([ "PAID_OMP_SUBSCRIPTION_AUTH=0" ])
  end

  it "lets the harness cli_env_overrides set PAID_OPENCODE_SUBSCRIPTION_AUTH but app-managed wins" do
    opencode_runner = instance_double(
      AgentHarness::Providers::Opencode,
      cli_env_overrides: { "PAID_OPENCODE_SUBSCRIPTION_AUTH" => "1" }
    )
    allow(AgentHarness).to receive(:provider).and_call_original
    allow(AgentHarness).to receive(:provider).with(:opencode).and_return(opencode_runner)

    runner = create(:runner, user: owner, runner_key: "opencode", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    svc = build_service(agent_run: agent_run)

    env_entries = svc.send(:run_scoped_environment, "http://paid-proxy:3000")

    opencode_entries = env_entries.select { |e| e.start_with?("PAID_OPENCODE_SUBSCRIPTION_AUTH=") }
    expect(opencode_entries).to eq([ "PAID_OPENCODE_SUBSCRIPTION_AUTH=0" ])
  end
end
