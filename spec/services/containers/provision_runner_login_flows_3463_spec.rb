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

  it "materializes a managed opencode credential into OpenCode's auth.json path" do
    runner = create(:runner, user: owner, runner_key: "opencode", auth_type: "subscription")
    agent_run = create(:agent_run, project: project, runner: runner)
    credential = create_managed_oauth_credential(runner_key: "opencode", fixture_name: "codex_auth_valid.json")
    svc = build_service(agent_run: agent_run)
    written = {}

    allow(svc).to receive(:write_container_file) { |path, content| written[path] = content }

    expect(svc.send(:seed_opencode_credentials!)).to be(true)
    expect(written.keys).to include("/home/agent/.local/share/opencode/auth.json")

    attempt = RunnerAuthAttempt.where(runner_key: "opencode", attempt_stage: "materialization").last
    expect(attempt.runner_credential).to eq(credential)
    expect(attempt.auth_source).to eq("managed")
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
