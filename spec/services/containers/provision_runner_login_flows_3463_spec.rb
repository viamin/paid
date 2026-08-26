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

  def opencode_run_command
    [ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode", "run", "ping" ]
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

  def collect_serialized_intervals(svc)
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
        svc.send(:with_codex_auth_lock, opencode_run_command) { critical_section.call }
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
    expect(parsed["tokens"]["access_token"]).to eq("eyJopencode-rotated-access-token")
    expect(parsed["tokens"]["refresh_token"]).to eq("v1.opencode-rotated-refresh-token")

    attempt = RunnerAuthAttempt.where(runner_key: "opencode", attempt_stage: "harvest").last
    expect(attempt.result).to eq("harvested")
    expect(attempt.auth_source).to eq("managed")
  end

  it "serializes opencode runs sharing the same managed credential and harvests under the lock" do
    agent_run, credential = build_opencode_subscription_run
    svc = build_service(agent_run: agent_run)

    allow(svc).to receive_messages(
      opencode_managed_runner_credential: credential,
      codex_auth_lock_timeout: 5
    )
    allow(svc).to receive(:harvest_opencode_managed_credential!)

    lockfile = svc.send(:opencode_managed_auth_lockfile_path)
    FileUtils.rm_f(lockfile)

    sorted = collect_serialized_intervals(svc)
    expect(sorted.size).to eq(2)
    expect(sorted[1][0]).to be >= sorted[0][1]
    expect(svc).to have_received(:harvest_opencode_managed_credential!).twice

    attempt = RunnerAuthAttempt.where(runner_key: "opencode", attempt_stage: "lease").last
    expect(attempt.lease_state).to eq("acquired")
    expect(attempt.runner_credential).to eq(credential)
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
    allow(local_backend).to receive(:exec_in_container).and_return([ [ '{"ok":true}' ], [], 0 ])

    expect(svc.send(:seed_omp_credentials!)).to be(true)
    expect(written.keys).to include("/home/agent/.local/share/omp/paid-auth-import.json")
    expect(JSON.parse(written.fetch("/home/agent/.local/share/omp/paid-auth-import.json"))["expired"]).to eq("2100-01-01T00:00:00Z")
    expect(local_backend).to have_received(:exec_in_container).with(
      container,
      [ "sh", "-lc", "omp auth-broker import /home/agent/.local/share/omp/paid-auth-import.json --provider anthropic --json" ],
      user: "agent"
    )

    attempt = RunnerAuthAttempt.where(runner_key: "omp", attempt_stage: "materialization").last
    expect(attempt.runner_credential).to eq(credential)
    expect(attempt.auth_source).to eq("managed")
  end
end
