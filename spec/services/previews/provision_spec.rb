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

  it "cleans up provisioned service containers and per-run databases via the service provisioner" do
    captured_env = { "DATABASE_URL" => "postgres://agent:agent@paid-svc/agent_run_preview" }
    allow(service_provisioner).to receive(:provision) do
      agent_run.update!(service_container_ids: [ 101, 202 ], service_environment: captured_env)
    end
    allow(service_provisioner).to receive(:cleanup_service_containers)

    service.call(start_tunnel: false, allow_seed: false)
    service.cleanup!

    expect(service_provisioner).to have_received(:cleanup_service_containers)
      .with(
        contain_exactly(101, 202),
        agent_run: agent_run,
        service_environment: captured_env
      )
  end

  it "leaves the preview's service container ids on the agent run while in flight" do
    captured_env = { "DATABASE_URL" => "postgres://agent:agent@paid-svc/agent_run_preview" }
    allow(service_provisioner).to receive(:provision) do
      agent_run.update!(service_container_ids: [ 101, 202 ], service_environment: captured_env)
    end
    allow(service_provisioner).to receive(:cleanup_service_containers)

    service.call(start_tunnel: false, allow_seed: false)

    expect(agent_run.reload.service_container_ids).to contain_exactly(101, 202)
  end

  it "preserves any pre-existing service container ids when persisting preview references" do
    agent_run.update!(service_container_ids: [ 7 ])
    allow(service_provisioner).to receive(:provision) do
      agent_run.update!(service_container_ids: [ 7, 101, 202 ])
    end
    allow(service_provisioner).to receive(:cleanup_service_containers)

    service.call(start_tunnel: false, allow_seed: false)

    expect(agent_run.reload.service_container_ids).to contain_exactly(7, 101, 202)
  end

  it "restores the agent run's pre-existing service container ids on cleanup" do
    agent_run.update!(service_container_ids: [ 7 ], service_environment: { "DATABASE_URL" => "postgres://existing/db" })
    allow(service_provisioner).to receive(:provision) do
      agent_run.update!(
        service_container_ids: [ 7, 101, 202 ],
        service_environment: { "DATABASE_URL" => "postgres://preview-host/db" }
      )
    end
    allow(service_provisioner).to receive(:cleanup_service_containers)

    service.call(start_tunnel: false, allow_seed: false)
    service.cleanup!

    expect(agent_run.reload.service_container_ids).to eq([ 7 ])
    expect(agent_run.service_environment).to eq({ "DATABASE_URL" => "postgres://existing/db" })
  end

  it "only cleans up preview-added service containers, not pre-existing ones the agent run already had" do
    agent_run.update!(service_container_ids: [ 7 ])
    captured_env = { "DATABASE_URL" => "postgres://preview-host/db" }
    allow(service_provisioner).to receive(:provision) do
      agent_run.update!(service_container_ids: [ 7, 101, 202 ], service_environment: captured_env)
    end
    allow(service_provisioner).to receive(:cleanup_service_containers)

    service.call(start_tunnel: false, allow_seed: false)
    service.cleanup!

    expect(service_provisioner).to have_received(:cleanup_service_containers)
      .with(
        contain_exactly(101, 202),
        agent_run: agent_run,
        service_environment: captured_env
      )
  end

  it "counts the preview against service container capacity while in flight so concurrent cleanup cannot stop the shared container" do
    service_container = create(:service_container, :running)
    create(:project_service_container, project: project, service_container: service_container)
    running_agent_run = create(:agent_run, :running, project: project)
    preview_provision = described_class.new(
      agent_run: running_agent_run,
      repo_path:,
      service_provisioner:,
      seed_runner:,
      tunnel_manager:
    )
    allow(service_provisioner).to receive(:provision) do
      running_agent_run.update!(service_container_ids: [ service_container.id ])
    end
    allow(service_provisioner).to receive(:cleanup_service_containers)

    preview_provision.call(start_tunnel: false, allow_seed: false)

    expect(service_container.capacity_inflight_agent_run_count).to eq(1)

    preview_provision.cleanup!

    expect(service_container.reload.capacity_inflight_agent_run_count).to eq(0)
  end

  it "removes this preview's transient service ids before cleanup evaluates shared container capacity" do
    service_container = create(:service_container, :running)
    create(:project_service_container, project: project, service_container: service_container)
    running_agent_run = create(:agent_run, :running, project: project)
    preview_provision = described_class.new(
      agent_run: running_agent_run,
      repo_path:,
      service_provisioner:,
      seed_runner:,
      tunnel_manager:
    )
    allow(service_provisioner).to receive(:provision) do
      running_agent_run.update!(service_container_ids: [ service_container.id ])
    end
    allow(service_provisioner).to receive(:cleanup_service_containers) do
      expect(service_container.reload.capacity_inflight_agent_run_count).to eq(0)
      expect(running_agent_run.reload.service_container_ids).to eq([])
    end

    preview_provision.call(start_tunnel: false, allow_seed: false)
    preview_provision.cleanup!
  end

  it "preserves a sibling preview's service container ids and environment when overlapping on the same agent run" do
    provision_a, provision_b = provision_overlapping_previews

    provision_a.cleanup!

    expect(agent_run.reload.service_container_ids).to contain_exactly(7, 202)
    expect(agent_run.service_environment).to eq({ "DATABASE_URL" => "postgres://preview-b/db" })

    provision_b.cleanup!

    expect(agent_run.reload.service_container_ids).to eq([ 7 ])
    expect(agent_run.service_environment).to eq({ "DATABASE_URL" => "postgres://existing/db" })
  end

  it "preserves sibling environment additions that share a key with this preview's snapshot" do
    provision_a, = provision_overlapping_previews(
      pre_existing_ids: [],
      original_environment: {},
      preview_a_ids: [ 101 ],
      preview_b_ids: [ 101, 202 ]
    )
    provision_a.cleanup!

    expect(agent_run.reload.service_environment).to eq({ "DATABASE_URL" => "postgres://preview-b/db" })
  end

  it "tracks overlap baselines in shared database state and clears them after the last cleanup" do
    provision_a, provision_b = provision_overlapping_previews

    shared_state = PreviewProvisionState.find_by!(agent_run: agent_run)
    expect(shared_state.active_count).to eq(2)
    expect(shared_state.baseline_service_container_ids).to eq([ 7 ])
    expect(shared_state.baseline_service_environment).to eq({ "DATABASE_URL" => "postgres://existing/db" })

    provision_a.cleanup!

    expect(PreviewProvisionState.find_by!(agent_run: agent_run).active_count).to eq(1)

    provision_b.cleanup!

    expect(PreviewProvisionState.find_by(agent_run: agent_run)).to be_nil
  end

  it "restores the original service container ids and environment when dependency provisioning fails" do
    allow(service_provisioner).to receive(:cleanup_service_containers)
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
    expect(service_provisioner).to have_received(:cleanup_service_containers).with(
      contain_exactly(101, 202),
      agent_run: agent_run,
      service_environment: { "DATABASE_URL" => "postgres://preview-host/db" }
    )
    expect(service.instance_variable_get(:@service_container_ids)).to be_nil
  end

  it "still cleans up the preview container when tunnel release fails" do
    service.call(start_tunnel: true, allow_seed: false)
    allow(tunnel_manager).to receive(:release_port!).and_raise("release failed")

    service.cleanup!

    expect(container_service).to have_received(:cleanup).with(force: true)
  end

  it "does not release a persisted tunnel port when cleanup runs before this lifecycle allocates one" do
    service.prepare_workspace!

    service.cleanup!

    expect(tunnel_manager).not_to have_received(:release_port!)
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

  it "loads seed data from the configured project screenshot config path" do
    project.update!(screenshot_settings: project.screenshot_settings.merge("config_path" => ".paid/custom-screenshots.yml"))
    seeded_config = seed_enabled_config
    allow(Screenshots::ConfigParser).to receive(:from_repo_path).and_return(seeded_config)
    write_repo_seed_config(path: ".paid/custom-screenshots.yml")

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

  it "raises a config error when a Phoenix project has seed configuration" do
    allow(Screenshots::DetectFramework).to receive(:detect_framework_only).and_return(:phoenix)
    seeded_config = seed_enabled_config
    allow(Screenshots::ConfigParser).to receive(:from_repo_path).and_return(seeded_config)
    write_repo_seed_config

    expect {
      service.call(start_tunnel: false, allow_seed: true)
    }.to raise_error(Screenshots::ConfigError, /seed configuration is not supported for Phoenix/)
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

  def write_repo_seed_config(path: ".paid/screenshots.yml")
    full_path = File.join(repo_path, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, <<~YAML)
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

  def provision_overlapping_previews(pre_existing_ids: [ 7 ], original_environment: { "DATABASE_URL" => "postgres://existing/db" },
    preview_a_ids: [ 7, 101 ], preview_a_environment: { "DATABASE_URL" => "postgres://preview-a/db" },
    preview_b_ids: [ 7, 101, 202 ], preview_b_environment: { "DATABASE_URL" => "postgres://preview-b/db" })
    agent_run.update!(service_container_ids: pre_existing_ids, service_environment: original_environment)
    allow(service_provisioner).to receive(:cleanup_service_containers)

    provision_a = build_provision
    allow(service_provisioner).to receive(:provision) do
      agent_run.update!(service_container_ids: preview_a_ids, service_environment: preview_a_environment)
    end
    provision_a.call(start_tunnel: false, allow_seed: false)

    provision_b = build_provision
    allow(service_provisioner).to receive(:provision) do |_agent_run, **|
      agent_run.update!(service_container_ids: preview_b_ids, service_environment: preview_b_environment)
    end
    provision_b.call(start_tunnel: false, allow_seed: false)

    [ provision_a, provision_b ]
  end

  def build_provision
    described_class.new(
      agent_run:,
      repo_path:,
      service_provisioner:,
      seed_runner:,
      tunnel_manager:
    )
  end
end
