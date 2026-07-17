# frozen_string_literal: true

require "rails_helper"

RSpec.describe Previews::Provision do
  let(:project) do
    create(:project, screenshot_settings: {
      "enabled" => true,
      "service_dependencies" => [ "postgres" ]
    })
  end
  let(:agent_run) do
    create(:agent_run,
      project:,
      branch_name: "paid/test-branch",
      pull_request_number: 99)
  end
  let(:repo_path) { Dir.mktmpdir("preview-provision-spec") }
  let(:config) do
    Screenshots::Configuration.from_hash(
      "base_url" => "http://localhost:3000",
      "routes" => [ { "path" => "/", "name" => "home" } ],
      "services" => [ "redis" ]
    )
  end
  let(:service_provisioner) { instance_double(Containers::ServiceProvisioner) }
  let(:seed_runner) { instance_double(Screenshots::SeedRunner, call: { user: OpenStruct.new(id: 1) }) }
  let(:tunnel_manager) do
    instance_double(
      Previews::TunnelManager,
      allocate_port!: 8201,
      start_client!: true,
      wait_until_healthy!: true,
      stop_client!: true,
      release_port!: true,
      token: "preview-token"
    )
  end
  let(:service) do
    described_class.new(
      agent_run:,
      repo_path:,
      service_provisioner:,
      seed_runner:,
      tunnel_manager:
    )
  end

  before do
    allow(container_result).to receive(:[]).and_return("")
    allow(Containers::Provision).to receive(:new).and_return(container_service)
    allow(Containers::GitOperations).to receive(:new).and_return(git_ops)
    allow(container_service).to receive(:execute).and_return(container_result)
    allow(service_provisioner).to receive(:provision)
    allow(Screenshots::ConfigParser).to receive_messages(from_repo_path: config, ui_detection_overrides: {})
    allow(Screenshots::DetectFramework).to receive(:detect_framework_only).and_return(:rails)

    FileUtils.mkdir_p(File.join(repo_path, "bin"))
    File.write(File.join(repo_path, "bin/rails"), "#!/bin/sh\n")
  end

  after do
    FileUtils.rm_rf(repo_path)
  end

  it "merges project and repo service dependencies for provisioning" do
    service.call(start_tunnel: false, allow_seed: false)

    expect(service_provisioner).to have_received(:provision)
      .with(agent_run, network: "paid-test", service_names: contain_exactly("postgres", "redis"))
  end

  it "restores the original service container ids and environment when dependency provisioning fails" do
    allow(service_provisioner).to receive(:provision) do
      agent_run.update!(
        service_container_ids: [ 101, 202 ],
        service_environment: { "DATABASE_URL" => "postgres://preview-host/db" }
      )
      raise Containers::Provision::TimeoutError, "timed out"
    end

    expect {
      service.call(start_tunnel: false, allow_seed: false)
    }.to raise_error(Containers::Provision::TimeoutError, "timed out")

    agent_run.reload
    expect(agent_run.service_container_ids).to eq([])
    expect(agent_run.service_environment).to eq({})
    expect(service.instance_variable_get(:@service_container_ids)).to contain_exactly(101, 202)
  end

  it "loads seed data only when the repo screenshots config defines seed records" do
    seeded_config = Screenshots::Configuration.from_hash(
      "base_url" => "http://localhost:3000",
      "routes" => [ { "path" => "/", "name" => "home" } ],
      "seed" => [
        { "key" => "user", "runner" => "Screenshots::SeedData::Paid.call" }
      ]
    )
    allow(Screenshots::ConfigParser).to receive(:from_repo_path).and_return(seeded_config)
    write_repo_seed_config

    service.call(start_tunnel: false, allow_seed: true)

    expect(seed_runner).to have_received(:call).with(
      config: seeded_config,
      repo_path:,
      driver_name: seeded_config.driver,
      force: true,
      executor: an_object_responding_to(:call)
    )
  end

  it "executes screenshot seeds inside the preview container with the preview environment" do
    seeded_config = seed_enabled_config
    allow(Screenshots::ConfigParser).to receive(:from_repo_path).and_return(seeded_config)
    provision_preview_database
    write_repo_seed_config
    stub_seed_runner_executor_probe

    service.call(start_tunnel: false, allow_seed: true)

    expect(container_service).to have_received(:execute).with(
      a_string_including("bin/rails runner"),
      hash_including(
        timeout: described_class::PROVISION_TIMEOUT_SECONDS,
        stream: false,
        env: hash_including(
          "CI" => "1",
          "DATABASE_URL" => "postgres://preview-host/db",
          "SCREENSHOT_SEED_CONFIG" => "[]"
        )
      )
    )
  end

  it "shell-escapes readiness probe url parts before building the probe command" do
    allow(service).to receive(:config).and_return(
      Screenshots::Configuration.from_hash(
        "base_url" => "http://localhost:3000/it's-a-path",
        "routes" => [ { "path" => "/", "name" => "home" } ]
      )
    )

    command = service.send(:readiness_probe_command)

    expect(command).to include("PREVIEW_APP_HOST=localhost")
    expect(command).to include("PREVIEW_APP_PORT=3000")
    expect(command).to include("PREVIEW_APP_PATH=/it\\'s-a-path")
    expect(command).to include('ENV.fetch("PREVIEW_APP_PATH")')
    expect(command).not_to include(%q(uri = URI("http://localhost:3000/it's-a-path")))
  end

  it "starts the rathole client and waits for tunnel health when tunnel startup is enabled" do
    service.call(start_tunnel: true, allow_seed: false)

    expect(tunnel_manager).to have_received(:start_client!)
      .with(container_service:, local_port: 3000, remote_port: 8201)
    expect(tunnel_manager).to have_received(:wait_until_healthy!)
      .with(port: 8201, path: "/", timeout_seconds: described_class::STARTUP_TIMEOUT_SECONDS)
  end

  it "starts Phoenix apps through mix phx.server with a preview bind override" do
    allow(Screenshots::DetectFramework).to receive(:detect_framework_only).and_return(:phoenix)

    File.write(File.join(repo_path, "mix.exs"), "defmodule Demo.MixProject do\nend\n")
    FileUtils.mkdir_p(File.join(repo_path, "config"))
    File.write(File.join(repo_path, "config/dev.exs"), "import Config\n")

    service.call(start_tunnel: false, allow_seed: false)

    expect(container_service).to have_received(:execute).with(
      a_string_including("PORT=3000 MIX_ENV=dev mix phx.server"),
      hash_including(timeout: 30, env: hash_including("CI" => "1"), stream: false)
    )
    expect(File.read(File.join(repo_path, "config/dev.exs"))).to include(%(import_config "paid_preview.exs"))
    expect(File.read(File.join(repo_path, "config/paid_preview.exs"))).to include("Keyword.put(:ip, {0, 0, 0, 0})")
  end

  def container_result
    @container_result ||= double(success?: true)
  end

  def container_service
    @container_service ||= instance_double(
      Containers::Provision,
      provision: true,
      network_name: "paid-test",
      container: instance_double(Docker::Container, id: "container-123"),
      cleanup: true
    )
  end

  def git_ops
    @git_ops ||= instance_double(
      Containers::GitOperations,
      clone_and_checkout_branch: true,
      install_artifact_excludes: true
    )
  end

  def write_repo_seed_config
    FileUtils.mkdir_p(File.join(repo_path, ".paid"))
    File.write(File.join(repo_path, ".paid/screenshots.yml"), <<~YAML)
      seed:
        - key: user
          runner: Screenshots::SeedData::Paid.call
    YAML
  end

  def seed_enabled_config
    Screenshots::Configuration.from_hash(
      "base_url" => "http://localhost:3000",
      "routes" => [ { "path" => "/", "name" => "home" } ],
      "seed" => [
        { "key" => "user", "runner" => "Screenshots::SeedData::Paid.call" }
      ]
    )
  end

  def provision_preview_database
    allow(service_provisioner).to receive(:provision) do
      agent_run.update!(service_environment: { "DATABASE_URL" => "postgres://preview-host/db" })
    end
  end

  def stub_seed_runner_executor_probe
    allow(seed_runner).to receive(:call) do |**args|
      args.fetch(:executor).call("SCREENSHOT_SEED_CONFIG" => "[]")
      {}
    end
  end
end
